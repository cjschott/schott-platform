"""Operator commands for the Health runtime -- ENG-0006-H18.

**The installed helpers are entry points; this is what they do.** Each helper
in `provisioning/health/` checks who it is running as, loads this module from
the root-owned installed library and calls one function here, so the logic is
reviewed, tested and installed as library code, and a helper adds no rule of
its own.

- `draft_statement` (unprivileged, `provisioning/health/draft-health-approval.py`):
  the canonical approval statement for one envelope. Its output is
  agent-editable until published, so the operator re-reads it in canonical
  form before approving (preflight §6.3 step 1).
- `publish_statement` (root, `kyri-health-approve`): publish one reviewed
  statement into the approval directory. It refuses unless the bytes have the
  digest the operator computed with `sha256sum`, pass every check ingestion
  makes before the store (`ingest.examine_statement`), and the operator has
  typed the digest's first twelve hex digits. It publishes by link-into-place,
  never replaces a statement, and verifies the result by re-opening it the way
  ingestion does. It never opens the Health store.
- `ingest_command` and `verify_command` (`kyri-health`): ingestion and
  `verify` against a store this process owns, as a result code and a mapping
  of identifiers and codes.

**What publication establishes.** Only the trusted UID can create a statement,
so approval is filesystem-enforced; the confirmation shows that something at a
terminal typed the digest. Neither authenticates a person and neither is a
signature (finalization §5.2).

**No production path is named here.** Every root and UID is a parameter; the
installed helpers compile in the production values, and the installer pins
the helpers.
"""

from __future__ import annotations

import dataclasses
import hashlib
import hmac
import json
import os
import secrets
import stat
from pathlib import Path
from typing import Any, Callable, Mapping

from ..common.canonical_json import CanonicalJSONError
from ..common.canonical_json import serialise as canonical_serialise
from .ingest import (MAXIMUM_STATEMENT_BYTES, REFUSALS, Examination,
                     _read_statement, examine_statement, ingest_envelope, verify)
from .records import (APPROVAL_CANONICALISATION, APPROVAL_DIGEST_ALGORITHM,
                      APPROVAL_DOMAIN, APPROVAL_STATEMENT_VERSION,
                      REQUEST_ID_PATTERN)
from .store import HealthStore, HealthStoreError

__all__ = ["CONFIRMATION_DIGITS", "DraftRefused", "PUBLISH_REFUSALS",
           "PublishResult", "STAGING", "draft_statement", "identity_refusal",
           "ingest_command", "publish_statement", "render_statement",
           "verify_command"]

CONFIRMATION_DIGITS = 12
# The approval directory's root-only staging directory. A statement is
# written here and linked into place, so the published name is never briefly
# a partial file.
STAGING = ".staging"
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC

# Publication's own refusals, plus every pre-store refusal ingestion can make.
PUBLISH_REFUSALS = frozenset({
    "parameters-invalid", "publisher-not-trusted-uid", "digest-malformed",
    "candidate-oversize", "digest-mismatch", "approval-root-untrusted",
    "staging-untrusted", "approval-exists", "confirmation-refused",
    "publication-failed", "publication-unverified",
}) | REFUSALS


class DraftRefused(ValueError):
    """A statement could not be drafted. `reason` is a closed code."""

    def __init__(self, reason: str, stage: str | None = None,
                 record_code: str | None = None) -> None:
        super().__init__(reason if record_code is None else f"{reason} ({record_code})")
        self.reason, self.stage, self.record_code = reason, stage, record_code


@dataclasses.dataclass(frozen=True)
class PublishResult:
    """`status` is `published`, `already-published` or `refused`."""

    status: str
    stage: str | None = None
    reason: str | None = None
    digest: str | None = None
    record_code: str | None = None


def _publish_refused(stage: str, reason: str, *, digest: str | None = None,
                     record_code: str | None = None) -> PublishResult:
    assert reason in PUBLISH_REFUSALS
    return PublishResult(status="refused", stage=stage, reason=reason,
                         digest=digest, record_code=record_code)


# --- drafting --------------------------------------------------------------

def draft_statement(envelope: Mapping[str, Any], *, request_id: str,
                    operation: str, actor: str, approving_authority: str,
                    approved_at: str) -> bytes:
    """The canonical statement bytes for `envelope`, or `DraftRefused`.

    Every member is supplied; nothing is defaulted, not even `approved_at`,
    because the bytes cannot change after review and the time is the
    operator's declaration. The draft is refused where ingestion would refuse
    it before the store, so a statement that drafts cleanly fails later only
    on its chain.
    """
    body = {
        "approval_statement_version": APPROVAL_STATEMENT_VERSION,
        "approval_domain": APPROVAL_DOMAIN,
        "operation": operation,
        "request_id": request_id,
        "actor": actor,
        "approving_authority": approving_authority,
        "approved_at": approved_at,
        "canonicalisation": APPROVAL_CANONICALISATION,
        "digest_algorithm": APPROVAL_DIGEST_ALGORITHM,
        "envelope": dict(envelope),
    }
    try:
        raw = canonical_serialise(body)
    except CanonicalJSONError:
        raise DraftRefused("approval-unreadable", "V3") from None
    examined = examine_statement(raw, request_id)
    if examined.refusal is not None:
        refusal = examined.refusal
        raise DraftRefused(refusal.reason, refusal.stage, refusal.record_code)
    return raw


def _shown(value: Any) -> str:
    """One value for display only; never hashed, never published.

    ASCII-escaped, so the operator's terminal receives printable ASCII alone:
    a candidate cannot carry an escape sequence that redraws or hides what
    the operator is about to approve.
    """
    return json.dumps(value, sort_keys=True, ensure_ascii=True)


def render_statement(examined: Examination) -> str:
    """What the operator reads before confirming: the decoded statement.

    Rendered from the parsed statement, every member and every dimension, in
    a fixed order, every value through `_shown`. The digest is printed last
    because it is what is typed.
    """
    statement = examined.statement
    envelope = statement["envelope"]
    lines = [f"{label:<20}{_shown(value)}" for label, value in (
        ("request", statement["request_id"]),
        ("operation", statement["operation"]),
        ("subject type", envelope.get("subject_type")),
        ("subject", envelope.get("subject_id")),
        ("envelope version", envelope.get("envelope_version")),
        ("supersedes", envelope.get("supersedes")),
        ("actor", statement["actor"]),
        ("approving authority", statement["approving_authority"]),
        ("approved at", statement["approved_at"]),
        ("evaluation", envelope.get("evaluation")),
    )]
    for name, entry in sorted(envelope.get("dimensions", {}).items()):
        lines.append(f"dimension {_shown(name)}")
        for key in sorted(entry):
            if key != "dimension":
                lines.append(f"  {_shown(key):<27} {_shown(entry[key])}")
    for key in sorted(set(envelope) - {"subject_type", "subject_id",
                                       "envelope_version", "supersedes",
                                       "evaluation", "dimensions"}):
        lines.append(f"{_shown(key):<20}{_shown(envelope[key])}")
    lines.append(f"{'digest':<20}{examined.digest}")
    return "\n".join(lines) + "\n"


# --- publication -----------------------------------------------------------

def _trusted_directory(descriptor: int, uid: int, *, private: bool) -> bool:
    entry = os.fstat(descriptor)
    forbidden = 0o077 if private else (stat.S_IWGRP | stat.S_IWOTH)
    return (stat.S_ISDIR(entry.st_mode) and entry.st_uid == uid
            and not entry.st_mode & forbidden)


def publish_statement(raw: Any, *, request_id: Any, expected_sha256: Any,
                      approval_root: Path | str, trusted_uid: Any,
                      confirm: Callable[[str], str]) -> PublishResult:
    """Publish one reviewed statement as `<request_id>.json`, or refuse.

    The publisher must BE `trusted_uid`: a statement owned by anyone else is
    one ingestion refuses. `confirm` is shown the rendered statement and
    returns what the operator typed. Nothing is replaced: a statement already
    published under the name is accepted only if it is these exact bytes.
    """
    if not isinstance(trusted_uid, int) or isinstance(trusted_uid, bool) or \
            trusted_uid < 0 or not callable(confirm) or \
            not isinstance(approval_root, (str, Path)) or not str(approval_root):
        return _publish_refused("parameters", "parameters-invalid")
    if os.geteuid() != trusted_uid:
        return _publish_refused("parameters", "publisher-not-trusted-uid")
    if not isinstance(request_id, str) or not REQUEST_ID_PATTERN.fullmatch(request_id):
        return _publish_refused("V1", "request-id-malformed")
    if not isinstance(expected_sha256, str) or len(expected_sha256) != 64 or \
            any(c not in "0123456789abcdef" for c in expected_sha256):
        return _publish_refused("digest", "digest-malformed")
    if not isinstance(raw, bytes) or len(raw) > MAXIMUM_STATEMENT_BYTES:
        return _publish_refused("digest", "candidate-oversize")
    # The binding between what was reviewed and what is published: the
    # operator's own `sha256sum`, computed with no Kyri code.
    if not hmac.compare_digest(hashlib.sha256(raw).hexdigest(), expected_sha256):
        return _publish_refused("digest", "digest-mismatch")

    examined = examine_statement(raw, request_id)
    if examined.refusal is not None:
        refusal = examined.refusal
        return _publish_refused(refusal.stage, refusal.reason,
                                record_code=refusal.record_code)
    digest = examined.digest
    name = f"{request_id}.json"

    try:
        root = os.open(approval_root, _DIRECTORY_FLAGS)
    except OSError:
        return _publish_refused("directory", "approval-root-untrusted")
    try:
        if not _trusted_directory(root, trusted_uid, private=False):
            return _publish_refused("directory", "approval-root-untrusted")
        try:
            staging = os.open(STAGING, _DIRECTORY_FLAGS, dir_fd=root)
        except OSError:
            return _publish_refused("directory", "staging-untrusted")
        try:
            if not _trusted_directory(staging, trusted_uid, private=True):
                return _publish_refused("directory", "staging-untrusted")
            return _publish(raw, name, digest, root, staging, approval_root,
                            trusted_uid, examined, confirm)
        finally:
            os.close(staging)
    finally:
        os.close(root)


def _existing(approval_root: Path | str, name: str, root: int, raw: bytes,
              trusted_uid: int, digest: str) -> PublishResult | None:
    """None if the name is free; otherwise what an occupied name means."""
    try:
        os.stat(name, dir_fd=root, follow_symlinks=False)
    except FileNotFoundError:
        return None
    published = _read_statement(approval_root, name, trusted_uid)
    if published is not None and hmac.compare_digest(published, raw):
        return PublishResult(status="already-published", digest=digest)
    return _publish_refused("publish", "approval-exists", digest=digest)


def _publish(raw: bytes, name: str, digest: str, root: int, staging: int,
             approval_root: Path | str, trusted_uid: int,
             examined: Examination, confirm: Callable[[str], str]) -> PublishResult:
    occupied = _existing(approval_root, name, root, raw, trusted_uid, digest)
    if occupied is not None:
        return occupied

    typed = confirm(render_statement(examined))
    expected = digest.removeprefix("sha256:")[:CONFIRMATION_DIGITS]
    if not isinstance(typed, str) or \
            not hmac.compare_digest(typed.strip().encode("utf-8"), expected.encode("ascii")):
        return _publish_refused("confirm", "confirmation-refused", digest=digest)

    # The temporary's name owes nothing to the request, so no request
    # identifier can name a path inside staging.
    temporary = f"{os.getpid()}-{secrets.token_hex(8)}.tmp"
    try:
        handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=staging)
    except OSError:
        return _publish_refused("publish", "publication-failed", digest=digest)
    try:
        try:
            view = memoryview(raw)
            while view:
                view = view[os.write(handle, view):]
            os.fsync(handle)
            os.fchmod(handle, 0o444)
        finally:
            os.close(handle)
        try:
            # link() refuses an existing name, so a statement that appeared
            # since the check above is never overwritten.
            os.link(temporary, name, src_dir_fd=staging, dst_dir_fd=root,
                    follow_symlinks=False)
        except FileExistsError:
            return _existing(approval_root, name, root, raw, trusted_uid, digest) \
                or _publish_refused("publish", "approval-exists", digest=digest)
        except OSError:
            return _publish_refused("publish", "publication-failed", digest=digest)
    except OSError:
        return _publish_refused("publish", "publication-failed", digest=digest)
    finally:
        try:
            os.unlink(temporary, dir_fd=staging)
        except OSError:
            pass
    try:
        os.fsync(root)
    except OSError:
        return _publish_refused("verify", "publication-unverified", digest=digest)

    # The reader is the authority: re-opened exactly as ingestion opens it.
    published = _read_statement(approval_root, name, trusted_uid)
    if published is None or not hmac.compare_digest(published, raw):
        return _publish_refused("verify", "publication-unverified", digest=digest)
    return PublishResult(status="published", digest=digest)


# --- the service identity's commands ----------------------------------------

def identity_refusal(*, expected_uid: int, expected_gid: int, euid: int,
                     egid: int, groups: list[int]) -> str | None:
    """None if the process is exactly the service identity, else a code.

    Exactly: effective UID and GID, and no supplementary group other than its
    own, so a process that kept an operator's groups is refused.
    """
    if euid != expected_uid or egid != expected_gid:
        return "identity-mismatch"
    if any(group != expected_gid for group in groups):
        return "identity-has-supplementary-groups"
    return None


def _store_refusal(store_root: Path | str) -> str | None:
    """The store root must be this process's own private directory."""
    try:
        entry = os.lstat(store_root)
    except OSError:
        return "store-unavailable"
    if not stat.S_ISDIR(entry.st_mode) or entry.st_uid != os.geteuid() or \
            entry.st_mode & 0o077:
        return "store-untrusted"
    return None


def _open_store(store_root: Path | str) -> tuple[HealthStore | None, str | None]:
    refusal = _store_refusal(store_root)
    if refusal is not None:
        return None, refusal
    try:
        # Never initialised here: the production root is laid out by the
        # installer, and opening a store must not create any part of it.
        return HealthStore(store_root, initialize=False), None
    except HealthStoreError:
        return None, "store-untrusted"


INGEST_EXIT = {"accepted": 0, "replayed": 0, "refused": 1,
               "committed-unverified": 3}
VERIFY_EXIT = {"clean": 0, "findings": 1, "refused": 2}


def ingest_command(request_id: Any, *, store_root: Path | str,
                   approval_root: Path | str, trusted_uid: int,
                   allow_own_uid_fixture: bool = False) -> tuple[int, dict]:
    """Ingest one request. (exit status, the result as identifiers and codes)."""
    store, refusal = _open_store(store_root)
    if store is None:
        return 2, {"status": "refused", "stage": "store", "reason": refusal}
    try:
        result = ingest_envelope(store, request_id=request_id,
                                 approval_root=approval_root,
                                 trusted_uid=trusted_uid,
                                 allow_own_uid_fixture=allow_own_uid_fixture)
    except HealthStoreError:
        return 2, {"status": "refused", "stage": "store", "reason": "store-untrusted"}
    return INGEST_EXIT[result.status], dataclasses.asdict(result)


def verify_command(*, store_root: Path | str, approval_root: Path | str,
                   trusted_uid: int,
                   allow_own_uid_fixture: bool = False) -> tuple[int, dict]:
    """Run `verify`. (exit status, the report as identifiers and codes)."""
    store, refusal = _open_store(store_root)
    if store is None:
        return 2, {"status": "refused", "reason": refusal}
    try:
        report = verify(store, approval_root=approval_root, trusted_uid=trusted_uid,
                        allow_own_uid_fixture=allow_own_uid_fixture)
    except HealthStoreError:
        return 2, {"status": "refused", "reason": "store-untrusted"}
    return VERIFY_EXIT[report.status], {
        "status": report.status,
        "reason": report.reason,
        "blocked": report.blocked,
        "findings": [{"code": f.code, "envelope_id": f.envelope_id,
                      "subject": list(f.subject) if f.subject else None,
                      "detail": f.detail} for f in report.findings],
        "heads": [{"subject": list(subject), "head": head}
                  for subject, head in report.heads],
        "frozen": [list(subject) for subject in report.frozen],
    }
