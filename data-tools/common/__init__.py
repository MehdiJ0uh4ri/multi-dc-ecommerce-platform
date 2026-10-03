"""Shared code for data-tools (seed/, loadgen/). See docs/data-layer.md."""
import logging
import os
import sys


def env(name, default=None, cast=str):
    value = os.environ.get(name)
    if value is None or value == "":
        if default is None:
            sys.exit(f"missing required environment variable {name}")
        return default
    return cast(value)


def env_bool(name, default):
    return env(name, "true" if default else "false").lower() in ("1", "true", "yes")


def setup_logging():
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )


def phone_number(prefix, n):
    """RegisterRequest phone ^0[0-9]{9,10}$, unique per user: prefix '0x' + 8 digits."""
    return f"{prefix}{n % 10**8:08d}"
