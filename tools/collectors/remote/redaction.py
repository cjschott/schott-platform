"""Redaction applied at the remote boundary.

Remote output is the least trustworthy text in the platform: it comes from a
machine this code does not control, and it lands in evidence records. It is
redacted here — at the transport edge, before any parsing and before any
fingerprint is computed — so there is no window in which an unredacted remote
string exists inside a collector.

Order matters. A fingerprint over unredacted content is a hash of a secret,
which is a weaker disclosure than plaintext but still a disclosure, and it
silently defeats the point of not storing the value.

Decoding is deterministic: the same bytes always produce the same string, so
repeated collection of identical input is byte-identical.
"""

from __future__ import annotations

from ..redaction import redact_text

# Remote output is host-controlled and may not be valid UTF-8. Undecodable
# bytes become the replacement character rather than raising, so a host that
# emits garbage produces a recorded observation failure instead of an
# exception that loses the attempt entirely.
DECODE_ERRORS = "replace"


def decode_remote_bytes(payload: bytes) -> str:
    """Decode host-controlled bytes deterministically."""
    if isinstance(payload, str):
        return payload
    return bytes(payload).decode("utf-8", errors=DECODE_ERRORS)


def redact_remote_output(text: str) -> tuple[str, bool]:
    """Return (redacted_text, changed) for one remote stream.

    Delegates to the framework's text redaction so remote and local output are
    held to one definition of what a secret looks like. A second, divergent
    definition here would mean a pattern fixed in one place stayed broken in
    the other.
    """
    if isinstance(text, bytes):
        text = decode_remote_bytes(text)
    if not isinstance(text, str):
        return "", False
    return redact_text(text)
