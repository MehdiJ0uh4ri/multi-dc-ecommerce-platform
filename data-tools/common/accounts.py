"""Synthetic shoppers, registered through auth-service like real sign-ups.

auth-service's POST /api/v1/auth/signup creates the Keycloak user (realm role USER) and
its own users row. The numeric user id that carts and payments carry comes from
GET /api/v1/users/me.
"""
import threading
from dataclasses import dataclass, field

from .api import ApiError, TokenSource

# RegisterRequest (auth-service): password ^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)[a-zA-Z\d]{8,}$,
# at most 50 characters. The shared base comes from `make secrets` (letters and digits
# only); the suffix guarantees each character class is present.
PASSWORD_SUFFIX = "Aa1"


def user_password(base):
    if not base.isalnum():
        raise ValueError("DATA_TOOLS_USER_PASSWORD must contain only letters and digits")
    return (base + PASSWORD_SUFFIX)[-50:]


@dataclass
class Account:
    username: str
    user_id: int
    tokens: TokenSource
    cart_id: int = None
    country: str = None
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False)


class Accounts:
    """Creates each account once per process; concurrent callers for one username wait."""

    def __init__(self, platform, client_id, password):
        self.platform = platform
        self.client_id = client_id
        self.password = password
        self.accounts = {}
        self.locks = {}
        self.lock = threading.Lock()

    def ensure(self, make_profile, attempts=5):
        """Sign up (or reuse) one shopper. Returns (Account, created).

        make_profile(attempt) returns a RegisterRequest body without password; the
        username must not depend on `attempt`. auth-service also rejects a duplicate
        email or phone, and a rejected sign-up looks the same as "user exists". If the
        login then fails, the conflict was on another field, so the next attempt's
        profile (e.g. another phone number) is tried.
        """
        username = make_profile(0)["username"]
        with self.lock:
            if username in self.accounts:
                return self.accounts[username], False
            user_lock = self.locks.setdefault(username, threading.Lock())
        with user_lock:
            if username in self.accounts:
                return self.accounts[username], False
            for attempt in range(attempts):
                created = self.platform.signup({**make_profile(attempt), "password": self.password})
                tokens = self.platform.password_grant(self.client_id, username, self.password)
                try:
                    user_id = self.platform.current_user_id(tokens)
                except ApiError as e:
                    # Keycloak answers 401 invalid_grant for an unknown user.
                    if created or e.status != 401:
                        raise
                    continue
                account = Account(username=username, user_id=user_id, tokens=tokens)
                with self.lock:
                    self.accounts[username] = account
                return account, created
            raise ApiError("POST", "/api/v1/auth/signup", 409, f"{username}: email or phone kept conflicting")

    def cart(self, account):
        with account.lock:
            if account.cart_id is None:
                account.cart_id = self.platform.create_cart(account.tokens, account.user_id)
            return account.cart_id
