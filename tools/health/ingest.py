"""Initial-envelope ingestion -- ENG-0006-H7a, component C1.

**One operation: admit an operator-approved FIRST envelope, or refuse.** The
input is an approval statement the operator published as a file named
`<request_id>.json` in an approval directory this process cannot write. On
schai that directory is root-owned and the statement is published by a root
ceremony; that ceremony, the directory and the `kyri-health` identity are H18
and are not built here. This module trusts nothing it can write itself: the
statement's owner must be the UID the caller supplies, and that UID may not be
this process's own except under an explicit fixture opt-in.

**The statement is the approval.** It is canonical JSON
(`kyri-strict-canonical-json/v1`) and its `approval_digest` is the SHA-256 of
its exact bytes, so an operator can compute the same digest with `sha256sum`
and no Kyri code. The stored record restates every statement member, so the
statement's bytes -- and therefore the digest -- are recomputable from the
record alone.

**What it establishes, and what it does not.** A root-owned statement makes
approval *filesystem-enforced against non-root writers*, attributed to the
names the statement declares. It is not human authentication and not a
signature; `actor` and `approving_authority` are claims.

**Stages, in order.** Every refusal before V14 writes nothing and consumes no
identifier. V10 (a Trust corroboration) does not exist under ruling O-4 (T0).

  V1  request_id well-formed
  V2  statement opened through `trusted_source`: regular, single link, owned
      by the trusted UID, not group- or world-writable, bounded size
  V3  strict canonical-JSON parse
  V4  closed statement schema; supported versions; request_id = file stem
  V5  full record validation of the would-be record, on a probe identity
  V6  operation agrees with the envelope; `replacement` refused until H7b
  V7  the bytes are the one canonical spelling of what they parse to
  V8  the statement reconstructed from the record is exactly those bytes
  V9  no self-approval
  --  store-wide critical section entered
  V11 replay: same request and digest returns the original record; same
      request, different digest is a conflict
  V12 the subject has no envelope; a subject with an unverifiable or
      ambiguous record is FROZEN (ruling O-5); an unreadable record anywhere
      freezes ingestion, because it cannot be attributed to a subject
  V13 the record survives the store's serialisation, checked before allocation
  V14 identifier allocated -- from here a refusal leaves a permanent gap
  V15 written once
  V16 read back and re-verified; a failure is `committed-unverified`, and the
      record, which exists and cannot be removed, freezes its subject

**Not here:** replacement chains (H7b), `verify` (H7b), any CLI, daemon or
helper, any provisioning, any Trust or Fabric import.
"""

from __future__ import annotations

import hashlib
import hmac
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

# Imported from the module path, never from `..common`: the Health import guard
# authorises these two modules to this file alone, and `tools.common` as a
# whole to no Health module.
from ..common.canonical_json import CanonicalJSONError
from ..common.canonical_json import parse as canonical_parse
from ..common.canonical_json import serialise as canonical_serialise
from ..common.trusted_source import TrustedSourceError, open_trusted_regular_file
from . import errors as E
from .records import (APPROVAL_CANONICALISATION, APPROVAL_DIGEST_ALGORITHM,
                      APPROVAL_DOMAIN, APPROVAL_SOURCE_AUTHORITY,
                      APPROVAL_STATEMENT_VERSION, IDENTITY_FIELD,
                      REQUEST_ID_PATTERN, parse)
from .store import HealthStore, HealthStoreError

__all__ = ["IngestResult", "REFUSALS", "STATEMENT_FIELDS", "ingest_envelope"]

ENVELOPE = "capability-health-envelope"
MAXIMUM_STATEMENT_BYTES = 65536
# Never allocated: the would-be record is validated under this identity before
# any identifier exists. The Fabric's probe-identity pattern.
PROBE_ID = "CHENV-0000"

# The statement object: every approval member except the two that depend on
# the statement's own bytes and location, plus the envelope content.
STATEMENT_FIELDS = (
    "approval_statement_version", "approval_domain", "operation", "request_id",
    "actor", "approving_authority", "approved_at", "canonicalisation",
    "digest_algorithm", "envelope")
_STATEMENT_APPROVAL_FIELDS = STATEMENT_FIELDS[:-1]
# The envelope inside a statement never names its own identifier (allocated
# after approval) or its approval (derived from the statement).
_ENVELOPE_EXCLUDED = ("envelope_id", "approval")

# --- the closed result vocabulary -----------------------------------------
# A refusal names a stage and a reason, never a supplied value.
REFUSALS = frozenset({
    "parameters-invalid", "trusted-uid-is-own-uid",
    "request-id-malformed",                                     # V1
    "approval-unavailable",                                     # V2
    "approval-unreadable",                                      # V3
    "approval-schema-invalid", "approval-version-unsupported",  # V4
    "envelope-invalid",                                         # V5
    "approval-operation-mismatch", "envelope-replacement-unsupported",  # V6
    "approval-not-canonical-bytes",                             # V7
    "approval-not-reconstructable",                             # V8
    "self-approval",                                            # V9
    "request-identity-conflict", "request-identity-ambiguous",  # V11
    "envelope-store-unreadable", "envelope-subject-frozen",
    "envelope-subject-exists",                                  # V12
    "approval-roundtrip-unstable",                              # V13
    "allocation-refused",                                       # V14
    "write-refused",                                            # V15
    "committed-unverified",                                     # V16
})


@dataclass(frozen=True)
class IngestResult:
    """The outcome of one ingestion. Carries identifiers and codes only.

    `status` is `accepted`, `replayed`, `refused` or `committed-unverified`.
    `envelope_id` names the record for every status but `refused`.
    `record_code` is the record model's refusal code when V5 refused.
    """

    status: str
    stage: str | None = None
    reason: str | None = None
    envelope_id: str | None = None
    approval_digest: str | None = None
    record_code: str | None = None

    @property
    def accepted(self) -> bool:
        return self.status in ("accepted", "replayed")


def _refused(stage: str, reason: str, *, record_code: str | None = None,
             envelope_id: str | None = None,
             approval_digest: str | None = None) -> IngestResult:
    assert reason in REFUSALS
    status = "committed-unverified" if reason == "committed-unverified" else "refused"
    return IngestResult(status=status, stage=stage, reason=reason,
                        envelope_id=envelope_id, approval_digest=approval_digest,
                        record_code=record_code)


# --- the statement and the record are one object ---------------------------

def _statement_of(payload: Mapping[str, Any]) -> dict[str, Any]:
    """The approval statement a record restates, rebuilt from the record.

    The inverse of `_record_payload`. Run on the would-be record before any
    write (V8, V13) and on the stored record after it (V16, V12): the same
    function on both sides, so "what was approved" and "what was stored" are
    compared by one definition.
    """
    approval = payload["approval"]
    statement = {field: approval[field] for field in _STATEMENT_APPROVAL_FIELDS}
    statement["envelope"] = {key: value for key, value in payload.items()
                             if key not in _ENVELOPE_EXCLUDED}
    return statement


def _record_payload(statement: Mapping[str, Any], digest: str,
                    envelope_id: str) -> dict[str, Any]:
    approval = {field: statement[field] for field in _STATEMENT_APPROVAL_FIELDS}
    approval["approval_digest"] = digest
    approval["approval_source"] = {"authority": APPROVAL_SOURCE_AUTHORITY,
                                   "name": f"{statement['request_id']}.json"}
    return {**statement["envelope"], "envelope_id": envelope_id,
            "approval": approval}


def _digest_of(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _same(left: str, right: str) -> bool:
    return hmac.compare_digest(left.encode("ascii"), right.encode("ascii"))


def _verified(stem: str, payload: Any):
    """The parsed record if it is a well-formed, self-consistent envelope.

    Self-consistent means its `approval_digest` is the digest of the statement
    the record restates. It does not re-open the retained statement file --
    that is H7b's `verify`. Returns None for anything else, never raises.
    """
    if not isinstance(payload, dict):
        return None
    try:
        record = parse(ENVELOPE, payload)
        if getattr(record, IDENTITY_FIELD[ENVELOPE]) != stem:
            return None
        rebuilt = canonical_serialise(_statement_of(record.to_dict()))
    except (E.HealthRecordError, CanonicalJSONError,
            KeyError, TypeError):
        return None
    if not _same(_digest_of(rebuilt), record.approval["approval_digest"]):
        return None
    return record


def _subject_of(payload: Any) -> tuple[str, str] | None:
    if isinstance(payload, dict):
        subject = (payload.get("subject_type"), payload.get("subject_id"))
        if all(isinstance(part, str) for part in subject):
            return subject
    return None


# --- V1-V4: reading the statement ------------------------------------------

def _read_bounded(descriptor: int) -> bytes | None:
    """Every byte, or None if the file grew past the bound after `fstat`."""
    chunks: list[bytes] = []
    remaining = MAXIMUM_STATEMENT_BYTES + 1
    while remaining > 0:
        chunk = os.read(descriptor, remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    data = b"".join(chunks)
    return None if len(data) > MAXIMUM_STATEMENT_BYTES else data


def _statement_schema(statement: dict[str, Any], request_id: str) -> str | None:
    """V4. The refusal reason, or None if the statement's shape is acceptable."""
    if set(statement) != set(STATEMENT_FIELDS):
        return "approval-schema-invalid"
    for value, expected in ((statement["approval_statement_version"],
                             APPROVAL_STATEMENT_VERSION),
                            (statement["canonicalisation"],
                             APPROVAL_CANONICALISATION),
                            (statement["digest_algorithm"],
                             APPROVAL_DIGEST_ALGORITHM)):
        # `type(...) is`, so `true` is not the version 1.
        if type(value) is not type(expected) or value != expected:
            return "approval-version-unsupported"
    if statement["approval_domain"] != APPROVAL_DOMAIN:
        return "approval-schema-invalid"
    # The statement is found by its name; a statement naming another request
    # is a statement that was copied or renamed.
    if statement["request_id"] != request_id:
        return "approval-schema-invalid"
    envelope = statement["envelope"]
    if not isinstance(envelope, dict) or \
            any(key in envelope for key in _ENVELOPE_EXCLUDED):
        return "approval-schema-invalid"
    return None


# --- the operation ---------------------------------------------------------

def ingest_envelope(store: HealthStore, *, request_id: Any,
                    approval_root: Path | str, trusted_uid: Any,
                    allow_own_uid_fixture: bool = False) -> IngestResult:
    """Admit one initial envelope from its published approval statement.

    `trusted_uid` is the owner every approval statement must have, supplied and
    never inferred. Refused when it is this process's own UID -- the
    configuration in which the ownership check separates nothing -- unless
    `allow_own_uid_fixture` is set, which exists for test fixtures exactly as
    `allow_repository_root` does.

    Returns an `IngestResult`. Never raises for a refused input.
    """
    if not isinstance(store, HealthStore) or \
            not isinstance(trusted_uid, int) or isinstance(trusted_uid, bool) or \
            trusted_uid < 0 or not isinstance(allow_own_uid_fixture, bool) or \
            not isinstance(approval_root, (str, Path)) or not str(approval_root):
        return _refused("parameters", "parameters-invalid")
    if trusted_uid == os.geteuid() and not allow_own_uid_fixture:
        return _refused("parameters", "trusted-uid-is-own-uid")

    # V1
    if not isinstance(request_id, str) or not REQUEST_ID_PATTERN.fullmatch(request_id):
        return _refused("V1", "request-id-malformed")

    # V2: one open, checked through the descriptor, read through it.
    try:
        descriptor = open_trusted_regular_file(
            approval_root, f"{request_id}.json", expected_uid=trusted_uid,
            require_single_link=True, maximum_bytes=MAXIMUM_STATEMENT_BYTES,
            refuse_oversize=True)
    except TrustedSourceError:
        return _refused("V2", "approval-unavailable")
    try:
        raw = _read_bounded(descriptor)
    except OSError:
        raw = None
    finally:
        os.close(descriptor)
    if raw is None:
        return _refused("V2", "approval-unavailable")

    # V3
    try:
        statement = canonical_parse(raw, maximum_bytes=MAXIMUM_STATEMENT_BYTES)
    except CanonicalJSONError:
        return _refused("V3", "approval-unreadable")

    # V4
    schema_refusal = _statement_schema(statement, request_id)
    if schema_refusal is not None:
        return _refused("V4", schema_refusal)

    digest = _digest_of(raw)

    # V5, which also decides V6's mismatch and V9: the record model enforces
    # both, and its refusal is reported under the stage that names it.
    try:
        probe = parse(ENVELOPE, _record_payload(statement, digest, PROBE_ID))
    except E.HealthRecordError as error:
        if error.code == E.APPROVAL_OPERATION_MISMATCH:
            return _refused("V6", "approval-operation-mismatch")
        if error.code == E.SELF_APPROVAL:
            return _refused("V9", "self-approval")
        return _refused("V5", "envelope-invalid", record_code=error.code)

    # V6: replacement chains are H7b.
    if statement["operation"] != "initial":
        return _refused("V6", "envelope-replacement-unsupported")

    # V7: JSON permits several spellings of one object; the approval has one.
    if canonical_serialise(statement) != raw:
        return _refused("V7", "approval-not-canonical-bytes")

    # V8: the record must restate the statement exactly. A member the record
    # model would drop or reshape -- an explicit null, say -- is refused here,
    # before it can become a record whose approval cannot be recomputed.
    try:
        rebuilt = canonical_serialise(_statement_of(probe.to_dict()))
    except CanonicalJSONError:
        rebuilt = None
    if rebuilt != raw:
        return _refused("V8", "approval-not-reconstructable")

    with store.request_critical_section(request_id):
        # Read fresh inside the section; nothing is cached across sections.
        existing = store.scan_records(ENVELOPE)
        subject = (probe.subject_type, probe.subject_id)
        records = {stem: _verified(stem, payload) for stem, payload in existing}

        # V11: replay answers for the request.
        same_request = [stem for stem, payload in existing
                        if isinstance(payload, dict)
                        and isinstance(payload.get("approval"), dict)
                        and payload["approval"].get("request_id") == request_id]
        if len(same_request) > 1:
            return _refused("V11", "request-identity-ambiguous")
        if same_request:
            prior = records[same_request[0]]
            if prior is None:
                return _refused("V11", "envelope-subject-frozen")
            if not _same(prior.approval["approval_digest"], digest):
                return _refused("V11", "request-identity-conflict")
            return IngestResult(status="replayed", envelope_id=same_request[0],
                                approval_digest=digest)

        # V12: an initial envelope needs a subject with no envelope at all.
        mine = []
        for stem, payload in existing:
            owner = _subject_of(payload)
            if owner is None:
                return _refused("V12", "envelope-store-unreadable")
            if owner == subject:
                mine.append(stem)
        if mine:
            if len(mine) > 1 or any(records[stem] is None for stem in mine):
                return _refused("V12", "envelope-subject-frozen")
            return _refused("V12", "envelope-subject-exists")
        store._test_sync_point("subject_checked", request_id)

        # V13: survives the store's serialisation, proven before allocation.
        previewed = _verified(PROBE_ID, store.preview_readback(probe))
        if previewed is None or previewed.to_dict() != probe.to_dict():
            return _refused("V13", "approval-roundtrip-unstable")

        # V14
        try:
            envelope_id = store.allocate_id(ENVELOPE)
        except HealthStoreError:
            return _refused("V14", "allocation-refused")
        record = parse(ENVELOPE, _record_payload(statement, digest, envelope_id))

        # V15
        try:
            store.write_record(ENVELOPE, record)
        except HealthStoreError:
            return _refused("V15", "write-refused", approval_digest=digest)

        # V16: the reader is the authority on success.
        # Any failure to read back is a failure to verify: the record exists
        # either way, so this must report, never raise past the caller.
        try:
            stored = store.read_record(ENVELOPE, envelope_id)
        except Exception:  # noqa: BLE001
            stored = None
        verified = _verified(envelope_id, stored)
        if verified is None or verified.to_dict() != record.to_dict():
            return _refused("V16", "committed-unverified",
                            envelope_id=envelope_id, approval_digest=digest)
        return IngestResult(status="accepted", envelope_id=envelope_id,
                            approval_digest=digest)
