"""Secret redaction applied before output and before fingerprinting.

Order matters: redaction runs before the content fingerprint is computed. A
fingerprint over unredacted content is a hash of a secret, which is a weaker
disclosure than the plaintext but still a disclosure — and it silently defeats
the whole point of not storing the value.

Redaction is deterministic so that fingerprints stay stable across runs.
"""

from __future__ import annotations

import re
from typing import Any

REDACTED = "<REDACTED>"

# Key names whose values are secrets regardless of what they contain.
SECRET_KEY_PARTS = (
    "password", "passwd", "secret", "token", "api_key", "apikey",
    "authorization", "auth_header", "cookie", "private_key", "privatekey",
    "client_secret", "access_key", "credential", "passphrase",
)

# Key names that describe a secret without containing one. Preserved, because
# knowing that a credential exists and where it comes from is exactly the kind
# of fact verification needs.
SECRET_METADATA_KEYS = frozenset({
    "secret_present", "secret_source", "secret_length_class",
    "secret_last_rotated", "secret_requirements", "secret_handling",
})

# Value shapes that carry a credential even under an innocuous key.
SECRET_VALUE_PATTERNS = (
    re.compile(r"://[^/\s:@]+:[^/\s@]+@"),                     # user:pass@host
    re.compile(r"\b(?:password|passwd|secret|token|api_key|apikey)\s*[=:]\s*\S+", re.I),
    re.compile(r"\bBearer\s+[A-Za-z0-9._\-]{8,}", re.I),
    re.compile(r"\bsk-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----"),
    re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"),  # JWT
)

SUPPORTED_SCALARS = (str, int, float, bool, type(None))


class RedactionError(Exception):
    """A value could not be processed. Never contains the offending value."""


def is_secret_key(key: str) -> bool:
    lowered = str(key).lower()
    if lowered in SECRET_METADATA_KEYS:
        return False
    return any(part in lowered for part in SECRET_KEY_PARTS)


def is_secret_value(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    return any(pattern.search(value) for pattern in SECRET_VALUE_PATTERNS)


def redact(node: Any) -> tuple[Any, bool]:
    """Return (redacted_copy, changed).

    Recurses through mappings and sequences. Rejects unsupported objects rather
    than coercing them, because str() on an arbitrary object can serialise
    internal state nobody reviewed.
    """
    changed = False

    if isinstance(node, dict):
        result: dict[str, Any] = {}
        for key, value in node.items():
            name = str(key)
            if is_secret_key(name):
                result[name] = REDACTED
                changed = True
                continue
            child, child_changed = redact(value)
            result[name] = child
            changed = changed or child_changed
        return result, changed

    if isinstance(node, (list, tuple)):
        items = []
        for value in node:
            child, child_changed = redact(value)
            items.append(child)
            changed = changed or child_changed
        return items, changed

    if isinstance(node, SUPPORTED_SCALARS):
        if is_secret_value(node):
            return REDACTED, True
        return node, False

    raise RedactionError(
        f"unsupported value type '{type(node).__name__}' cannot be safely redacted"
    )


def redact_text(text: str) -> tuple[str, bool]:
    """Redact secret-shaped fragments inside a free-text blob.

    Used for command stderr, which is operator-facing prose that occasionally
    contains a URL with embedded credentials.
    """
    if not isinstance(text, str):
        raise RedactionError("redact_text expects a string")
    changed = False
    result = text
    for pattern in SECRET_VALUE_PATTERNS:
        result, count = pattern.subn(REDACTED, result)
        changed = changed or bool(count)
    return result, changed
