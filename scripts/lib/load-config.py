#!/usr/bin/env python3
"""
Safe loader for config/customer.env and config/foundations.env.

Accepts only RATHSTED_REGISTRY and RATHSTED_IMAGE keys.
Validates values against strict character allowlists.
Never evaluates shell syntax.

Usage (from bash — prints VAR=value pairs for safe assignment):
  eval "$(python3 scripts/lib/load-config.py config/customer.env)"
  # sets RATHSTED_REGISTRY and RATHSTED_IMAGE in the calling shell

Or import as a module:
  from load_config import load_config
  cfg = load_config("config/customer.env")
  registry = cfg["RATHSTED_REGISTRY"]

Exit codes:
  0  success
  1  parse or validation error (message on stderr)
  2  file not found
"""

import re
import sys
from pathlib import Path

ALLOWED_KEYS = {"RATHSTED_REGISTRY", "RATHSTED_IMAGE"}

# Registry: hostname[:port][/path-prefix]
# hostname  : alphanumeric, dot, hyphen (must start with alphanumeric)
# port      : optional colon followed by 1-5 digits
# path      : zero or more slash-separated path components (alphanumeric, dot, hyphen, underscore)
REGISTRY_RE = re.compile(
    r'^[a-zA-Z0-9][a-zA-Z0-9.\-]*(:[0-9]{1,5})?(/[a-zA-Z0-9._\-]+)*$'
)

# Image: hostname[:port]/path[:tag] or hostname[:port]/path[@sha256:hex]
# The hostname portion may contain a port (host:port/...), so we cannot
# simply split on the first colon — instead we require at least one slash
# after the optional port, and allow a tag or digest at the end.
IMAGE_RE = re.compile(
    r'^[a-zA-Z0-9][a-zA-Z0-9.\-]*(:[0-9]{1,5})?'   # hostname[:port]
    r'(/[a-zA-Z0-9._\-]+)+'                           # /path (one or more components)
    r'(:[a-zA-Z0-9._\-]+|@sha256:[a-f0-9]{64})?$'    # optional :tag or @digest
)


def load_config(path: str) -> dict:
    p = Path(path)
    if not p.exists():
        print(f"config file not found: {path}", file=sys.stderr)
        sys.exit(2)

    result = {}
    for lineno, raw in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            print(
                f"{path}:{lineno}: invalid line (expected KEY=value, got: {line!r})",
                file=sys.stderr,
            )
            sys.exit(1)
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()

        if key not in ALLOWED_KEYS:
            print(
                f"{path}:{lineno}: unknown key {key!r} (allowed: {sorted(ALLOWED_KEYS)})",
                file=sys.stderr,
            )
            sys.exit(1)

        if not value:
            print(f"{path}:{lineno}: empty value for {key}", file=sys.stderr)
            sys.exit(1)

        if key == "RATHSTED_REGISTRY" and not REGISTRY_RE.match(value):
            print(
                f"{path}:{lineno}: RATHSTED_REGISTRY value {value!r} contains "
                f"invalid characters (allowed: alphanumeric . - _ / :port)",
                file=sys.stderr,
            )
            sys.exit(1)

        if key == "RATHSTED_IMAGE" and not IMAGE_RE.match(value):
            print(
                f"{path}:{lineno}: RATHSTED_IMAGE value {value!r} contains "
                f"invalid characters (allowed: alphanumeric . - _ / :tag @sha256:digest)",
                file=sys.stderr,
            )
            sys.exit(1)

        result[key] = value

    return result


def _shell_quote(s: str) -> str:
    """Single-quote a string for safe shell assignment."""
    return "'" + s.replace("'", "'\\''") + "'"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <config-file>", file=sys.stderr)
        sys.exit(1)

    cfg = load_config(sys.argv[1])
    for k, v in cfg.items():
        print(f"{k}={_shell_quote(v)}")
