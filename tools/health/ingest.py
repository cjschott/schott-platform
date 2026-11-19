"""Envelope ingestion and verification -- ENG-0006-H7a (C1) and H7b (C2).

**One operation: admit an operator-approved envelope, or refuse.** A first
envelope (`operation: initial`) starts a subject's chain; a replacement
(`operation: replacement`) names the chain's current head in `supersedes` and
carries the next version. The input is an approval statement the operator published as a file named
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
  V6  operation agrees with the envelope: initial <=> version 1 <=> no
      predecessor
  V7  the bytes are the one canonical spelling of what they parse to
  V8  the statement reconstructed from the record is exactly those bytes
  V9  no self-approval
  --  store-wide critical section entered
  V11 replay: same request and digest returns the original record; same
      request, different digest is a conflict
  V12 the subject's chain (below): an initial envelope needs a subject with
      no envelope, a replacement needs a well-formed chain whose head it
      supersedes with the head's version plus one. A subject with an
      unverifiable record or a malformed chain is FROZEN (ruling O-5); an
      unreadable record anywhere freezes ingestion, because it cannot be
      attributed to a subject
  V13 the record survives the store's serialisation, checked before allocation
  V14 identifier allocated -- from here a refusal leaves a permanent gap
  V15 written once
  V16 read back and re-verified; a failure is `committed-unverified`, and the
      record, which exists and cannot be removed, freezes its subject

**The chain.** A subject's envelopes E(S) are well-formed iff
  W1  exactly one member is version 1 with no predecessor
  W2  every other member's `supersedes` names a member of E(S)
  W3  each member's version is its predecessor's plus one
  W4  no two members name the same predecessor (no fork)
  W5  every member verifies
W1-W4 make E(S) one path; its head is the member nothing supersedes. A
malformed chain has no head, and nothing chooses one -- not the highest
identifier, not the highest version. At ingestion W5 is the record's own
consistency (the V16 check); `verify` also re-opens each retained statement.

**`verify` is read-only.** It reports every record that cannot be attributed
or verified, every retained statement that is missing or differs, every
request two records claim, every broken chain rule and every partial write,
and names each subject's head. It takes no lock, writes nothing and repairs
nothing.

**The lock is advisory.** It orders cooperating writers; a process that writes
the store directly is detected by V12 and `verify`, not prevented.

**Not here:** CHSTATE, any CLI, daemon or helper, any provisioning, any Trust
or Fabric import.
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

__all__ = ["FINDINGS", "Finding", "IngestResult", "REFUSALS", "STATEMENT_FIELDS",
           "VerifyReport", "ingest_envelope", "verify"]

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
    "approval-operation-mismatch",                              # V6
    "approval-not-canonical-bytes",                             # V7
    "approval-not-reconstructable",                             # V8
    "self-approval",                                            # V9
    "request-identity-conflict", "request-identity-ambiguous",  # V11
    "envelope-store-unreadable", "envelope-subject-frozen",
    "envelope-subject-exists", "envelope-subject-absent",
    "envelope-not-head", "envelope-version-not-successor",     # V12
    "approval-roundtrip-unstable",                              # V13
    "allocation-refused",                                       # V14
    "write-refused",                                            # V15
    "committed-unverified",                                     # V16
})


# What `verify` reports. A finding names a rule and a record or subject, never
# a record's content.
FINDINGS = frozenset({
    "record-unattributable",           # no subject can be read: blocks all
    "record-unverified",               # W5: parse, name or own digest fails
    "approval-statement-unavailable",  # W5: retained statement cannot be opened
    "approval-statement-mismatch",     # W5: retained statement differs
    "request-identity-ambiguous",      # two records claim one request
    "chain-root-not-unique",           # W1
    "chain-predecessor-missing",       # W2
    "chain-version-not-successor",     # W3
    "chain-fork",                      # W4
    "store-structural",                # the store's own `validate()`, e.g. debris
})
_RULE_FINDINGS = {"W1": "chain-root-not-unique", "W2": "chain-predecessor-missing",
                  "W3": "chain-version-not-successor", "W4": "chain-fork"}


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


def _chain(members: Mapping[str, Any]) -> tuple[str | None, tuple[str, ...]]:
    """The head of one subject's verified envelopes, and the rules they break.

    Returns `(head, ())` for a well-formed chain and `(None, rules)` otherwise,
    `rules` naming each of W1-W4 broken. W5 is the caller's: every member
    passed here has already verified.
    """
    broken = set()
    successors: dict[str, list[str]] = {}
    roots = 0
    for stem, record in members.items():
        predecessor = getattr(record, "supersedes", None)
        if predecessor is None:
            roots += 1
            continue
        if predecessor not in members:
            broken.add("W2")
            continue
        if record.envelope_version != members[predecessor].envelope_version + 1:
            broken.add("W3")
        successors.setdefault(predecessor, []).append(stem)
    if roots != 1:
        broken.add("W1")
    if any(len(named) > 1 for named in successors.values()):
        broken.add("W4")
    if broken:
        return None, tuple(sorted(broken))
    # W1-W4 make the members one path, so exactly one is superseded by none.
    (head,) = [stem for stem in members if stem not in successors]
    return head, ()


def _parameters(store: Any, approval_root: Any, trusted_uid: Any,
                allow_own_uid_fixture: Any) -> str | None:
    """The parameter refusal reason, or None. Shared by ingestion and verify."""
    if not isinstance(store, HealthStore) or \
            not isinstance(trusted_uid, int) or isinstance(trusted_uid, bool) or \
            trusted_uid < 0 or not isinstance(allow_own_uid_fixture, bool) or \
            not isinstance(approval_root, (str, Path)) or not str(approval_root):
        return "parameters-invalid"
    if trusted_uid == os.geteuid() and not allow_own_uid_fixture:
        return "trusted-uid-is-own-uid"
    return None


def _read_statement(approval_root: Path | str, name: str,
                    trusted_uid: int) -> bytes | None:
    """A statement's exact bytes through `trusted_source`, or None."""
    try:
        descriptor = open_trusted_regular_file(
            approval_root, name, expected_uid=trusted_uid,
            require_single_link=True, maximum_bytes=MAXIMUM_STATEMENT_BYTES,
            refuse_oversize=True)
    except TrustedSourceError:
        return None
    try:
        return _read_bounded(descriptor)
    except OSError:
        return None
    finally:
        os.close(descriptor)


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
    """Admit one envelope, initial or replacement, from its approval statement.

    `trusted_uid` is the owner every approval statement must have, supplied and
    never inferred. Refused when it is this process's own UID -- the
    configuration in which the ownership check separates nothing -- unless
    `allow_own_uid_fixture` is set, which exists for test fixtures exactly as
    `allow_repository_root` does.

    Returns an `IngestResult`. Never raises for a refused input.
    """
    parameter_refusal = _parameters(store, approval_root, trusted_uid,
                                    allow_own_uid_fixture)
    if parameter_refusal is not None:
        return _refused("parameters", parameter_refusal)

    # V1
    if not isinstance(request_id, str) or not REQUEST_ID_PATTERN.fullmatch(request_id):
        return _refused("V1", "request-id-malformed")

    # V2: one open, checked through the descriptor, read through it.
    raw = _read_statement(approval_root, f"{request_id}.json", trusted_uid)
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

        # V12: the subject's whole chain, from this listing alone.
        mine = {}
        for stem, payload in existing:
            owner = _subject_of(payload)
            if owner is None:
                return _refused("V12", "envelope-store-unreadable")
            if owner == subject:
                mine[stem] = records[stem]
        if any(record is None for record in mine.values()):
            return _refused("V12", "envelope-subject-frozen")
        head, broken = _chain(mine) if mine else (None, ())
        if broken:
            return _refused("V12", "envelope-subject-frozen")
        if statement["operation"] == "initial":
            if mine:
                return _refused("V12", "envelope-subject-exists")
        else:
            if not mine:
                return _refused("V12", "envelope-subject-absent")
            if probe.supersedes != head:
                return _refused("V12", "envelope-not-head")
            if probe.envelope_version != mine[head].envelope_version + 1:
                return _refused("V12", "envelope-version-not-successor")
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


# --- verify ----------------------------------------------------------------

@dataclass(frozen=True)
class Finding:
    """One problem `verify` found. `subject` is (subject_type, subject_id)."""

    code: str
    envelope_id: str | None = None
    subject: tuple[str, str] | None = None
    detail: str | None = None


@dataclass(frozen=True)
class VerifyReport:
    """What `verify` found. `status` is `clean`, `findings` or `refused`.

    `heads` maps each subject with a well-formed, fully verified chain to its
    head. `frozen` lists every subject ingestion must not write. Ingestion is
    `blocked` outright while any record cannot be attributed to a subject.
    """

    status: str
    reason: str | None = None
    findings: tuple[Finding, ...] = ()
    heads: tuple[tuple[tuple[str, str], str], ...] = ()
    frozen: tuple[tuple[str, str], ...] = ()
    blocked: bool = False

    @property
    def clean(self) -> bool:
        return self.status == "clean"


def verify(store: HealthStore, *, approval_root: Path | str, trusted_uid: Any,
           allow_own_uid_fixture: bool = False) -> VerifyReport:
    """Check every stored envelope against its retained approval and its chain.

    Read-only: no lock is taken and nothing is written or repaired. Each
    record must verify on its own (as at V16) AND its retained statement,
    opened through `trusted_source` with the same checks as V2, must be
    exactly the bytes the record restates. One record per request; W1-W4 per
    subject. The parameters are ingestion's, with the same refusals.
    """
    parameter_refusal = _parameters(store, approval_root, trusted_uid,
                                    allow_own_uid_fixture)
    if parameter_refusal is not None:
        return VerifyReport(status="refused", reason=parameter_refusal)

    findings: list[Finding] = []
    subjects: dict[tuple[str, str], dict[str, Any]] = {}
    unapproved: set[tuple[str, str]] = set()
    claims: dict[str, list[str]] = {}
    blocked = False
    for stem, payload in store.scan_records(ENVELOPE):
        subject = _subject_of(payload)
        if subject is None:
            blocked = True
            findings.append(Finding("record-unattributable", envelope_id=stem))
            continue
        record = _verified(stem, payload)
        if record is None:
            findings.append(Finding("record-unverified", envelope_id=stem,
                                    subject=subject))
        else:
            claims.setdefault(record.approval["request_id"], []).append(stem)
            expected = canonical_serialise(_statement_of(record.to_dict()))
            retained = _read_statement(approval_root,
                                       record.approval["approval_source"]["name"],
                                       trusted_uid)
            # A record that is self-consistent but unapproved still takes
            # part in its chain, so a bypassing fork is reported as a fork too.
            if retained is None:
                findings.append(Finding("approval-statement-unavailable",
                                        envelope_id=stem, subject=subject))
                unapproved.add(subject)
            elif not hmac.compare_digest(retained, expected):
                findings.append(Finding("approval-statement-mismatch",
                                        envelope_id=stem, subject=subject))
                unapproved.add(subject)
        subjects.setdefault(subject, {})[stem] = record

    for stems in claims.values():
        if len(stems) > 1:
            findings.extend(Finding("request-identity-ambiguous", envelope_id=stem)
                            for stem in stems)

    heads, frozen = [], []
    for subject, members in sorted(subjects.items()):
        if any(record is None for record in members.values()):
            frozen.append(subject)
            continue
        head, broken = _chain(members)
        findings.extend(Finding(_RULE_FINDINGS[rule], subject=subject)
                        for rule in broken)
        if head is None or subject in unapproved:
            frozen.append(subject)
        else:
            heads.append((subject, head))

    findings.extend(Finding("store-structural", detail=problem)
                    for problem in store.validate())
    return VerifyReport(status="findings" if findings else "clean",
                        findings=tuple(findings), heads=tuple(heads),
                        frozen=tuple(frozen), blocked=blocked)
