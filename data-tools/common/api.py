"""HTTP access to the platform, shared by the seeders and the load generator.

Every business call goes through APISIX (GATEWAY_URL), like a real client. Tokens come
straight from Keycloak: APISIX has no /realms route.

APISIX's global rule allows 1200 requests per 60 s per client address
(app/deploy/apisix/apisix.yaml, limit-count). All pods of one tool share an address
per pod, so each process keeps its own rate below MAX_RPS (default 15/s) and backs off
on 429.
"""
import logging
import random
import threading
import time

import requests

log = logging.getLogger(__name__)

RETRY_STATUS = {429, 502, 503, 504}


class ApiError(Exception):
    def __init__(self, method, path, status, body):
        super().__init__(f"{method} {path} -> {status}: {body[:300]}")
        self.status = status
        self.body = body


class RateLimiter:
    """Thread-safe token bucket: at most `rate` acquisitions per second, burst 1 s."""

    def __init__(self, rate):
        self.rate = float(rate)
        self.tokens = self.rate
        self.updated = time.monotonic()
        self.lock = threading.Lock()

    def acquire(self):
        while True:
            with self.lock:
                now = time.monotonic()
                self.tokens = min(self.rate, self.tokens + (now - self.updated) * self.rate)
                self.updated = now
                if self.tokens >= 1:
                    self.tokens -= 1
                    return
                wait = (1 - self.tokens) / self.rate
            time.sleep(wait)


class TokenSource:
    """Access token for one principal, fetched again 30 s before it expires."""

    def __init__(self, session, token_url, form):
        self.session = session
        self.token_url = token_url
        self.form = form
        self.token = None
        self.expires = 0.0
        self.lock = threading.Lock()

    def get(self):
        with self.lock:
            if self.token is None or time.time() > self.expires - 30:
                self._fetch()
            return self.token

    def invalidate(self):
        with self.lock:
            self.token = None

    def _fetch(self):
        for attempt in range(6):
            try:
                r = self.session.post(self.token_url, data=self.form, timeout=30)
            except requests.RequestException as e:
                # kube-router applies NetworkPolicies to a new pod asynchronously, so the
                # first connections of a fresh pod can fail (docs/devops-sre-thinking.md).
                log.warning("token request failed (%s), retrying", e)
                time.sleep(2 ** attempt)
                continue
            if r.status_code == 200:
                body = r.json()
                self.token = body["access_token"]
                self.expires = time.time() + int(body.get("expires_in", 60))
                return
            if r.status_code >= 500:
                time.sleep(2 ** attempt)
                continue
            raise ApiError("POST", self.token_url, r.status_code, r.text)
        raise ApiError("POST", self.token_url, 0, "token endpoint unreachable")


class Platform:
    """APISIX + Keycloak endpoints used by the data tools."""

    def __init__(self, gateway_url, keycloak_url, realm, max_rps=15.0, timeout=30, retries=6,
                 on_response=None):
        self.gateway = gateway_url.rstrip("/")
        self.token_url = f"{keycloak_url.rstrip('/')}/realms/{realm}/protocol/openid-connect/token"
        self.session = requests.Session()
        self.session.mount("http://", requests.adapters.HTTPAdapter(pool_maxsize=32))
        self.limiter = RateLimiter(max_rps)
        self.timeout = timeout
        self.retries = retries
        # Callback (endpoint, status, seconds) for metrics; status 0 = connection error.
        self.on_response = on_response or (lambda endpoint, status, seconds: None)

    # --- tokens ---------------------------------------------------------------
    def client_credentials(self, client_id, client_secret):
        return TokenSource(self.session, self.token_url, {
            "grant_type": "client_credentials", "client_id": client_id, "client_secret": client_secret,
        })

    def password_grant(self, client_id, username, password):
        return TokenSource(self.session, self.token_url, {
            "grant_type": "password", "client_id": client_id, "username": username, "password": password,
        })

    # --- raw request ----------------------------------------------------------
    def call(self, method, path, endpoint, tokens=None, json=None, ok=(200,)):
        """One gateway request with retries on 429/5xx/connection errors.

        `endpoint` is a low-cardinality label for metrics (e.g. "POST /api/orders").
        Returns the parsed JSON body (or None for an empty body).
        """
        url = self.gateway + path
        for attempt in range(self.retries):
            headers = {}
            if tokens is not None:
                headers["Authorization"] = "Bearer " + tokens.get()
            self.limiter.acquire()
            started = time.monotonic()
            try:
                r = self.session.request(method, url, json=json, headers=headers, timeout=self.timeout)
            except requests.RequestException as e:
                self.on_response(endpoint, 0, time.monotonic() - started)
                log.warning("%s %s failed (%s), attempt %d", method, path, e, attempt + 1)
                time.sleep(min(30, 2 ** attempt) + random.random())
                continue
            self.on_response(endpoint, r.status_code, time.monotonic() - started)
            if r.status_code in ok:
                return r.json() if r.content else None
            if r.status_code == 401 and tokens is not None and attempt == 0:
                tokens.invalidate()
                continue
            if r.status_code in RETRY_STATUS:
                delay = float(r.headers.get("Retry-After") or min(30, 2 ** attempt))
                time.sleep(delay + random.random())
                continue
            raise ApiError(method, path, r.status_code, r.text)
        raise ApiError(method, path, 0, f"gave up after {self.retries} attempts")

    # --- product-service ------------------------------------------------------
    def list_products(self):
        return self.call("GET", "/api/products", "GET /api/products") or []

    def list_categories(self):
        return self.call("GET", "/api/categories", "GET /api/categories") or []

    def create_category(self, tokens, title, parent_id=None, image_url=None):
        body = {"categoryTitle": title, "imageUrl": image_url}
        if parent_id is not None:
            body["parentCategory"] = {"categoryId": parent_id}
        return self.call("POST", "/api/categories", "POST /api/categories", tokens, body)

    def create_product(self, tokens, product):
        return self.call("POST", "/api/products", "POST /api/products", tokens, product)

    # --- auth-service ---------------------------------------------------------
    def signup(self, profile):
        """POST /api/v1/auth/signup (public route). Returns False if the user already exists."""
        try:
            self.call("POST", "/api/v1/auth/signup", "POST /api/v1/auth/signup", json=profile)
            return True
        except ApiError as e:
            # UserServiceImpl.register raises BusinessException.conflict for an existing
            # username, email or phone.
            if e.status == 409 or (e.status == 400 and "exist" in e.body.lower()):
                return False
            raise

    def current_user_id(self, tokens):
        body = self.call("GET", "/api/v1/users/me", "GET /api/v1/users/me", tokens)
        return int(body["data"]["id"])

    # --- order-service / payment-service -------------------------------------
    def create_cart(self, tokens, user_id):
        return int(self.call("POST", "/api/carts", "POST /api/carts", tokens, {"userId": user_id})["cartId"])

    def create_order(self, tokens, cart_id, product_id, fee, desc):
        body = {"orderDesc": desc, "orderFee": round(fee, 2), "productId": product_id,
                "cart": {"cartId": cart_id}}
        return self.call("POST", "/api/orders", "POST /api/orders", tokens, body)

    def create_payment(self, tokens, order_id, user_id):
        # PaymentServiceImpl.save publishes the saved payment to the "SUCCESSFUL" topic.
        body = {"orderId": order_id, "userId": user_id, "isPayed": True, "paymentStatus": "COMPLETED"}
        return self.call("POST", "/api/payments", "POST /api/payments", tokens, body)
