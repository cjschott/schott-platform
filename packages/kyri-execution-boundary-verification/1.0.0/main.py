"""The governed entrypoint for `kyri-execution-boundary-verification`.

CAPDEF-0001 declares a deterministic capability that exercises Kyri's governed
execution path and carries no production workload. CCON-0001 binds the governed
execution payload to a bounded verification result. This file is the whole
implementation of both, and it is deliberately the smallest thing that can be.

**It runs where there is no platform.** The container mounts this tree read-only
and runs one interpreter on this one file. Nothing under `tools/` is reachable
from inside, so every governed constant below is a value this file states and
the suite proves equal to the released authority's -- never a value this file
imports. That is the one place duplication is unavoidable, and it is closed by
a test rather than by a comment.

**The payload identity is read, never recomputed.** The bytes at the payload
mount are the canonical bytes the coordinator already validated and bound, so
`SHA-256` over exactly those bytes *is* the governed `payload_digest`. This file
runs no second schema validator and forms no second opinion about what the
payload means; the one field it reads is `operation`, because naming an
operation it was not asked to perform would make the result a false record.

**The checksum commits to the result.** It is `SHA-256` over the canonical
serialisation of the result with the checksum field removed, so any reader
holding only `result.json` can re-derive it. It is not a second copy of
`payload_digest`: one names the input, the other names the output.

**There is no way to report a failure inside a result.** The governed content
schema is closed at five fields and none of them can carry a status, so a
refusal writes nothing and returns nonzero. The lifecycle reports it, the
document never does -- which is also why a capability cannot self-declare
success.

**Deterministic by construction.** No clock, no entropy, no ambient
configuration, no identity of the machine. Two runs over the same payload
produce the same bytes.

Governed by:
  docs/superpowers/specs/2026-08-11-first-adapter-design.md  (§8, §9, §10, §11)
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys

# The governed capability, spelled as CAPDEF-0001 spells it, and the single
# operation this release verifies. `result_content.py` refuses anything else.
CAPABILITY = "kyri-execution-boundary-verification"
OPERATION = "verify-execution-boundary"
RESULT_SCHEMA_VERSION = 1

# The fixed runtime mounts. Both are the adapter's, not this file's: the payload
# arrives read-only at the first and the collector reads the second.
PAYLOAD_PATH = "/run/kyri/input/payload"
RESULT_PATH = "/kyri/output/result.json"

# The governed payload bound. Stated so an oversized payload is refused here
# rather than pulled whole into memory to discover it was oversized.
PAYLOAD_MAXIMUM_BYTES = 2 * 1024 * 1024

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_WRITE_FLAGS = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                | os.O_CLOEXEC)
_RESULT_MODE = 0o444
_READ_CHUNK = 65536


class VerificationRefused(Exception):
    """The governed result cannot honestly be produced."""


def canonical(document):
    """Canonical JSON bytes for one flat governed document.

    Keys are ASCII here and sorted, separators are minimal, and text is emitted
    as itself rather than escaped -- which is the released canonical form for
    this shape. The suite proves the two agree byte for byte, because agreeing
    is the property that matters and asserting it here would only be a claim.
    """
    return json.dumps(document, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def read_payload(path):
    """The exact bytes at ``path``, or refuse.

    Opened once without following a link on the final component, then
    interrogated through the descriptor: the file read is the file that was
    checked. One byte past the bound is read on purpose, so "at the bound" and
    "over it" are distinguishable without reading the rest.
    """
    try:
        handle = os.open(path, _READ_FLAGS)
    except OSError as error:
        raise VerificationRefused(f"the payload is unusable: {error}") from None
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode):
            raise VerificationRefused("the payload is not a regular file")
        if info.st_size > PAYLOAD_MAXIMUM_BYTES:
            raise VerificationRefused("the payload exceeds the governed bound")
        chunks = []
        remaining = PAYLOAD_MAXIMUM_BYTES + 1
        while remaining > 0:
            chunk = os.read(handle, min(_READ_CHUNK, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    except OSError as error:
        raise VerificationRefused(
            f"the payload could not be read: {error}") from None
    finally:
        os.close(handle)

    body = b"".join(chunks)
    if len(body) > PAYLOAD_MAXIMUM_BYTES:
        raise VerificationRefused("the payload exceeds the governed bound")
    return body


def requested_operation(body):
    """The operation the payload asks for, or refuse.

    The payload was already validated against its closed governed schema before
    it was mounted, so this is not that check repeated. It reads one field,
    because a result naming an operation nobody requested would be a false
    record of what was proven.
    """
    try:
        document = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise VerificationRefused(
            "the payload is not one canonical JSON document") from None
    if not isinstance(document, dict):
        raise VerificationRefused("the payload's top level is not an object")
    return document.get("operation")


def build_result(payload_bytes):
    """The governed verification result for exactly these payload bytes."""
    body = {
        "capability": CAPABILITY,
        "operation": OPERATION,
        "payload_digest": hashlib.sha256(payload_bytes).hexdigest(),
        "result_schema_version": RESULT_SCHEMA_VERSION,
    }
    checksum = hashlib.sha256(canonical(body)).hexdigest()
    document = dict(body)
    document["checksum"] = checksum
    return document


def write_result(path, body):
    """Create the result exclusively and write it whole, or refuse.

    ``O_EXCL`` with ``O_NOFOLLOW`` means an existing result is never replaced
    and a planted link is never written through. A write that stops short
    leaves a truncated document, which the collector refuses -- there is no
    repair here and nothing is ever removed.
    """
    try:
        handle = os.open(path, _WRITE_FLAGS, _RESULT_MODE)
    except OSError as error:
        raise VerificationRefused(
            f"the result could not be created: {error}") from None
    try:
        written = 0
        while written < len(body):
            step = os.write(handle, body[written:])
            if step <= 0:
                raise VerificationRefused("the result stopped before the end")
            written += step
        os.fsync(handle)
    except OSError as error:
        raise VerificationRefused(
            f"the result could not be written: {error}") from None
    finally:
        os.close(handle)


def verify(payload_path, result_path):
    """Perform the boundary verification, returning the result it wrote."""
    payload_bytes = read_payload(payload_path)
    requested = requested_operation(payload_bytes)
    if requested != OPERATION:
        raise VerificationRefused(
            "the payload requests an operation this capability does not perform")
    document = build_result(payload_bytes)
    write_result(result_path, canonical(document))
    return document


def main():
    """The governed mounts, or a refusal the process reports."""
    try:
        verify(PAYLOAD_PATH, RESULT_PATH)
    except VerificationRefused as error:
        sys.stderr.write(f"refused: {error}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
