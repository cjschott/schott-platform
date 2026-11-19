#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for ENG-0006-H7a and H7b: envelope ingestion (C1, C2)
# and `verify`.
#
# `tools.health.ingest.ingest_envelope` admits ONE envelope -- a subject's
# first, or the successor of its chain's head -- from an operator-published
# approval statement, or refuses. `verify` re-checks the stored chains against
# the retained statements and must change nothing. Every refusal before
# allocation (V1-V13) must leave the store byte-for-byte unchanged and consume
# no identifier; that is asserted for every refusal below, not sampled.
#
# FIXTURES ONLY. Approval statements live in a temporary directory owned by the
# user running this suite, so every call opts in with `allow_own_uid_fixture`
# -- the production configuration (root-owned statements, a `kyri-health`
# store) is H18 and is not built here. That the opt-in is REQUIRED, and that a
# foreign trusted UID refuses these files, is itself asserted.
#
# Concurrency is synchronised by events and by the store's named seams, never by
# sleeping. Timeouts bound a failure; they never order anything.
#
# Nothing here contacts a host or writes outside a temporary directory, and the
# production Health root is only ever checked for absence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PRODUCTION_HEALTH_ROOT="/var/lib/kyri/health"   # prod-path-reference
if [[ -e "${PRODUCTION_HEALTH_ROOT}" ]]; then
  production_before="present"
else
  production_before="absent"
fi

python3 - "${ROOT}" <<'PY'
import ast
import atexit
import copy
import hashlib
import multiprocessing
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        failures += 1


from tools.common import canonical_json  # noqa: E402
from tools.health import ingest as I  # noqa: E402
from tools.health import records as H  # noqa: E402
from tools.health.store import HealthStore, HealthStoreError  # noqa: E402

ENV = "capability-health-envelope"
UID = os.geteuid()
SCRATCH = Path(tempfile.mkdtemp(prefix="h7a-ingest-"))
atexit.register(shutil.rmtree, SCRATCH, True)
_n = [0]


def fresh(name):
    _n[0] += 1
    path = SCRATCH / f"{name}-{_n[0]:03d}"
    path.mkdir(mode=0o755)
    path.chmod(0o755)
    return path


def fresh_store(cls=HealthStore, **kwargs):
    return cls(fresh("store"), **kwargs)


# --- hand-written statements, independent of the implementation -------------
ENVELOPE = {
    "envelope_version": 1,
    "subject_type": "capability-instance",
    "subject_id": "CINST-000007",
    "dimensions": {"latency": {
        "dimension": "latency", "unit": "milliseconds",
        "aggregation": {"kind": "instant"},
        "entry_condition": {"operator": "gt", "value": "2000"},
        "exit_condition": {"operator": "le", "value": "1500"},
        "hysteresis": {"kind": "duration", "seconds": 120,
                       "max_gap_seconds": 30, "min_samples": 3},
        "freshness_policy_seconds": 60}},
    "evaluation": "worst-dimension-wins",
    "provenance": {"class": "declared", "reviewed_in": "fixture review",
                   "notes": "café"},
}


def statement(request_id="REQ-0001", subject="CINST-000007", envelope=None,
              **members):
    body = {
        "approval_statement_version": 1,
        "approval_domain": "capability-health-envelope",
        "operation": "initial",
        "request_id": request_id,
        "actor": "operator",
        "approving_authority": "operator-review",
        "approved_at": "2026-11-16T09:00:00-06:00",
        "canonicalisation": "kyri-strict-canonical-json/v1",
        "digest_algorithm": "sha256",
        "envelope": copy.deepcopy(ENVELOPE) if envelope is None else envelope,
    }
    body["envelope"]["subject_id"] = subject
    body.update(members)
    return body


def publish(approvals, request_id="REQ-0001", body=None, *, raw=None,
            name=None, mode=0o444):
    path = approvals / (name or f"{request_id}.json")
    data = raw if raw is not None else canonical_json.serialise(
        body if body is not None else statement(request_id))
    if path.exists() or path.is_symlink():
        path.unlink()
    path.write_bytes(data)
    path.chmod(mode)
    return data


def ingest(store, approvals, request_id="REQ-0001", **kwargs):
    kwargs.setdefault("trusted_uid", UID)
    kwargs.setdefault("allow_own_uid_fixture", True)
    return I.ingest_envelope(store, request_id=request_id,
                             approval_root=approvals, **kwargs)


def snapshot(store):
    return {str(p.relative_to(store.root)): (p.read_bytes() if p.is_file() else None)
            for p in sorted(store.root.rglob("*"))}


OBSERVED_REASONS = set()


def refuses(store, approvals, stage, reason, label, request_id="REQ-0001",
            **kwargs):
    """Assert a refusal at `stage` for `reason`, and that nothing changed."""
    before = snapshot(store)
    result = ingest(store, approvals, request_id, **kwargs)
    OBSERVED_REASONS.add(result.reason)
    check(result.status == "refused" and result.stage == stage
          and result.reason == reason,
          f"{label}: refused at {stage} as {reason} "
          f"(got {result.status}/{result.stage}/{result.reason})")
    check(result.envelope_id is None, f"{label}: names no envelope")
    check(snapshot(store) == before,
          f"{label}: the store is byte-for-byte unchanged, no identifier used")
    return result


print("--- the accepted path ---")
store = fresh_store()
approvals = fresh("approvals")
published = publish(approvals)
result = ingest(store, approvals)
check(result.status == "accepted" and result.accepted
      and result.envelope_id == "CHENV-0001",
      "a valid initial envelope is accepted as CHENV-0001")
expected_digest = "sha256:" + hashlib.sha256(published).hexdigest()
check(result.approval_digest == expected_digest,
      "approval_digest is the sha256 of the statement file's exact bytes")
coreutils = subprocess.run(["sha256sum", str(approvals / "REQ-0001.json")],
                           capture_output=True, text=True, check=True)
check(result.approval_digest == "sha256:" + coreutils.stdout.split()[0],
      "the digest is the one an operator gets from coreutils sha256sum")
stored = store.read_record(ENV, "CHENV-0001")
check(stored["approval"] == {
    "approval_statement_version": 1,
    "approval_domain": "capability-health-envelope",
    "operation": "initial", "request_id": "REQ-0001", "actor": "operator",
    "approving_authority": "operator-review",
    "approved_at": "2026-11-16T09:00:00-06:00",
    "canonicalisation": "kyri-strict-canonical-json/v1",
    "digest_algorithm": "sha256", "approval_digest": expected_digest,
    "approval_source": {"authority": "health-approvals",
                        "name": "REQ-0001.json"}},
    "the stored approval block is exactly the D-1 block")
check({k: v for k, v in stored.items() if k not in ("envelope_id", "approval")}
      == ENVELOPE, "the stored envelope content is the approved content")
rebuilt = {**{k: stored["approval"][k] for k in I.STATEMENT_FIELDS[:-1]},
           "envelope": {k: v for k, v in stored.items()
                        if k not in ("envelope_id", "approval")}}
check(canonical_json.serialise(rebuilt) == published,
      "the statement's exact bytes are recomputable from the stored record")
check(H.parse(ENV, stored).envelope_id == "CHENV-0001",
      "the stored record parses under the record model")
check("approval_source" not in I.STATEMENT_FIELDS
      and "approval_digest" not in I.STATEMENT_FIELDS,
      "the statement carries neither its own digest nor its own location")

print("--- parameters, and the trusted UID ---")
store = fresh_store()
approvals = fresh("approvals")
publish(approvals)
for label, kwargs in (
        ("a boolean trusted_uid", {"trusted_uid": True}),
        ("a text trusted_uid", {"trusted_uid": "0"}),
        ("a negative trusted_uid", {"trusted_uid": -1}),
        ("a non-boolean fixture opt-in", {"allow_own_uid_fixture": 1})):
    refuses(store, approvals, "parameters", "parameters-invalid", label, **kwargs)
before = snapshot(store)
check(I.ingest_envelope(object(), request_id="REQ-0001", approval_root=approvals,
                        trusted_uid=0).reason == "parameters-invalid",
      "something that is not a HealthStore is refused")
check(I.ingest_envelope(store, request_id="REQ-0001", approval_root="",
                        trusted_uid=0).reason == "parameters-invalid",
      "an empty approval root is refused")
refuses(store, approvals, "parameters", "trusted-uid-is-own-uid",
        "trusting this process's own UID without the fixture opt-in",
        allow_own_uid_fixture=False)
# Root cannot be impersonated here, so the production configuration is shown
# from the other side: statements this user owns are refused when root is the
# trusted owner, which is what makes a root-owned approval directory mean
# something.
refuses(store, approvals, "V2", "approval-unavailable",
        "a statement not owned by the trusted UID (root)", trusted_uid=0)
refuses(store, approvals, "V2", "approval-unavailable",
        "a statement not owned by another trusted UID", trusted_uid=UID + 1,
        allow_own_uid_fixture=False)

print("--- V1: request_id ---")
for bad in ("", "REQ 1", "REQ/1", "x" * 201, "REQ-1\n", "café", None, 7):
    refuses(store, approvals, "V1", "request-id-malformed",
            f"request_id {bad!r:.24}", request_id=bad)

print("--- V2: the statement file is opened from a trusted source ---")
refuses(store, approvals, "V2", "approval-unavailable", "an absent statement",
        request_id="REQ-ABSENT")
publish(approvals, "REQ-REAL", statement("REQ-REAL"))
(approvals / "REQ-LINK.json").symlink_to(approvals / "REQ-REAL.json")
refuses(store, approvals, "V2", "approval-unavailable",
        "a statement that is a symbolic link", request_id="REQ-LINK")
publish(approvals, "REQ-HARD", statement("REQ-HARD"))
os.link(approvals / "REQ-HARD.json", SCRATCH / "second-name.json")
refuses(store, approvals, "V2", "approval-unavailable",
        "a statement with a second hard link", request_id="REQ-HARD")
for mode, label in ((0o664, "group-writable"), (0o646, "world-writable")):
    publish(approvals, "REQ-MODE", statement("REQ-MODE"), mode=mode)
    refuses(store, approvals, "V2", "approval-unavailable",
            f"a {label} statement", request_id="REQ-MODE")
(approvals / "REQ-DIR.json").mkdir()
refuses(store, approvals, "V2", "approval-unavailable",
        "a directory in the statement's place", request_id="REQ-DIR")
os.mkfifo(approvals / "REQ-FIFO.json")
refuses(store, approvals, "V2", "approval-unavailable",
        "a FIFO in the statement's place", request_id="REQ-FIFO")
oversize = statement("REQ-BIG")
oversize["envelope"]["notes"] = "x" * I.MAXIMUM_STATEMENT_BYTES
publish(approvals, "REQ-BIG", oversize)
refuses(store, approvals, "V2", "approval-unavailable",
        "a statement over 64 KiB", request_id="REQ-BIG")
writable_root = fresh("approvals")
publish(writable_root)
writable_root.chmod(0o775)
refuses(store, writable_root, "V2", "approval-unavailable",
        "an approval directory writable by its group")
linked_root = SCRATCH / "approvals-link"
linked_root.symlink_to(approvals)
refuses(store, linked_root, "V2", "approval-unavailable",
        "an approval directory that is a symbolic link")

print("--- V3: strict canonical JSON ---")
for label, raw in (("YAML", b"approval_statement_version: 1\n"),
                   ("a float", b'{"a":1.5}'),
                   ("a duplicate key", b'{"a":1,"a":1}'),
                   ("a top-level array", b'[1]'),
                   ("invalid UTF-8", b'{"a":"\xff"}'),
                   ("an empty file", b""),
                   ("NaN", b'{"a":NaN}')):
    publish(approvals, "REQ-V3", raw=raw)
    refuses(store, approvals, "V3", "approval-unreadable", label,
            request_id="REQ-V3")

print("--- V4: the closed statement schema ---")
V4_CASES = [
    ("a missing member", lambda s: s.pop("actor"), "approval-schema-invalid"),
    ("an extra member", lambda s: s.update(approval_digest="sha256:" + "0" * 64),
     "approval-schema-invalid"),
    ("a trust_record_id", lambda s: s.update(trust_record_id="TREC-0001"),
     "approval-schema-invalid"),
    ("a statement version 2", lambda s: s.update(approval_statement_version=2),
     "approval-version-unsupported"),
    ("a statement version true", lambda s: s.update(approval_statement_version=True),
     "approval-version-unsupported"),
    ("another canonicalisation", lambda s: s.update(canonicalisation="json"),
     "approval-version-unsupported"),
    ("another digest algorithm", lambda s: s.update(digest_algorithm="sha512"),
     "approval-version-unsupported"),
    ("another approval domain",
     lambda s: s.update(approval_domain="capability-health-state"),
     "approval-schema-invalid"),
    ("a request_id that is not the file stem",
     lambda s: s.update(request_id="REQ-OTHER"), "approval-schema-invalid"),
    ("an envelope that is not an object", lambda s: s.update(envelope=[]),
     "approval-schema-invalid"),
    ("an envelope naming its own identifier",
     lambda s: s["envelope"].update(envelope_id="CHENV-0042"),
     "approval-schema-invalid"),
    ("an envelope carrying an approval",
     lambda s: s["envelope"].update(approval={}), "approval-schema-invalid"),
]
for label, mutate, reason in V4_CASES:
    body = statement("REQ-V4")
    mutate(body)
    publish(approvals, "REQ-V4", body)
    refuses(store, approvals, "V4", reason, label, request_id="REQ-V4")

print("--- V5: the would-be record is validated in full ---")


def envelope_with(mutate):
    body = copy.deepcopy(ENVELOPE)
    mutate(body)
    return body


V5_CASES = [
    ("a learned threshold", lambda e: e.update(learned_threshold="1"),
     "forbidden-field"),
    ("a superseded_by link", lambda e: e.update(superseded_by="CHENV-0002"),
     "forbidden-field"),
    ("a publication block", lambda e: e.update(publication={"x": 1}),
     "forbidden-field"),
    ("a non-canonical threshold",
     lambda e: e["dimensions"]["latency"]["entry_condition"].update(value="2000.0"),
     "decimal-not-canonical"),
    ("a missing continuity member",
     lambda e: e["dimensions"]["latency"]["hysteresis"].pop("max_gap_seconds"),
     "dimension-entry-malformed"),
    ("a unit mismatch",
     lambda e: e["dimensions"]["latency"].update(unit="seconds"), "unit-mismatch"),
    ("a package subject",
     lambda e: e.update(subject_type="capability-package"),
     "subject-type-not-permitted"),
    ("a missing provenance", lambda e: e.pop("provenance"),
     "missing-required-field"),
    ("a version-1 envelope naming a predecessor",
     lambda e: e.update(supersedes="CHENV-0001"), "supersession-inconsistent"),
]
for label, mutate, code in V5_CASES:
    publish(approvals, "REQ-V5", statement("REQ-V5", envelope=envelope_with(mutate)))
    result = refuses(store, approvals, "V5", "envelope-invalid", label,
                     request_id="REQ-V5")
    check(result.record_code == code,
          f"{label}: the record model's code is {code} (got {result.record_code})")
for label, member, value in (("an empty actor", "actor", ""),
                             ("a naive approval instant", "approved_at",
                              "2026-11-16T09:00:00")):
    publish(approvals, "REQ-V5", statement("REQ-V5", **{member: value}))
    refuses(store, approvals, "V5", "envelope-invalid", label, request_id="REQ-V5")

print("--- V6: the operation agrees with the envelope ---")
publish(approvals, "REQ-V6", statement("REQ-V6", operation="replacement"))
refuses(store, approvals, "V6", "approval-operation-mismatch",
        "a version-1 envelope approved as a replacement", request_id="REQ-V6")
# With its predecessor named, so the only disagreement is the operation.
second = envelope_with(lambda e: e.update(envelope_version=2,
                                           supersedes="CHENV-0001"))
publish(approvals, "REQ-V6", statement("REQ-V6", envelope=second))
refuses(store, approvals, "V6", "approval-operation-mismatch",
        "a version-2 envelope approved as initial", request_id="REQ-V6")
replacement = envelope_with(lambda e: e.update(envelope_version=2,
                                                supersedes="CHENV-0001"))
publish(approvals, "REQ-V6", statement("REQ-V6", operation="replacement",
                                       envelope=replacement))
# The H7a guard is gone; the head rule is what refuses this now.
refuses(store, approvals, "V12", "envelope-subject-absent",
        "a well-formed replacement for a subject with no envelope",
        request_id="REQ-V6")

print("--- V7: one canonical spelling of the statement ---")
canonical = canonical_json.serialise(statement("REQ-V7"))
spellings = {
    "a trailing newline": canonical + b"\n",
    "insignificant whitespace": canonical.replace(b'":', b'": ', 1),
    "an escaped non-ASCII character": canonical.replace(
        "café".encode(), b"caf\\u00e9"),
    "unsorted keys": canonical.replace(
        b'{"actor":"operator","approval_domain":"capability-health-envelope",',
        b'{"approval_domain":"capability-health-envelope","actor":"operator",'),
}
for label, raw in spellings.items():
    check(raw != canonical, f"{label}: the fixture really differs from canonical")
    publish(approvals, "REQ-V7", raw=raw)
    refuses(store, approvals, "V7", "approval-not-canonical-bytes", label,
            request_id="REQ-V7")

print("--- V8: the record restates the statement exactly ---")
nulled = envelope_with(lambda e: e.update(description=None))
publish(approvals, "REQ-V8", statement("REQ-V8", envelope=nulled))
refuses(store, approvals, "V8", "approval-not-reconstructable",
        "an explicit null the record would drop", request_id="REQ-V8")

print("--- V9: no self-approval ---")
for member in ("actor", "approving_authority"):
    publish(approvals, "REQ-V9", statement("REQ-V9", **{member: "CINST-000007"}))
    result = refuses(store, approvals, "V9", "self-approval",
                     f"the subject as its own {member}", request_id="REQ-V9")
    check("CINST-000007" not in repr(result),
          f"the self-approval refusal via {member} echoes no value")

print("--- V11: replay and conflict ---")
store = fresh_store()
approvals = fresh("approvals")
publish(approvals)
first = ingest(store, approvals)
before = snapshot(store)
again = ingest(store, approvals)
check(again.status == "replayed" and again.accepted
      and again.envelope_id == first.envelope_id
      and again.approval_digest == first.approval_digest,
      "the same request and digest replay to the original record")
check(snapshot(store) == before, "a replay writes nothing and allocates nothing")
changed = envelope_with(lambda e: e["dimensions"]["latency"]["entry_condition"]
                        .update(value="2500"))
publish(approvals, "REQ-0001", statement("REQ-0001", envelope=changed))
refuses(store, approvals, "V11", "request-identity-conflict",
        "the same request with a different digest")

print("--- V12: one envelope per subject, and frozen subjects ---")
publish(approvals, "REQ-0002", statement("REQ-0002"))
refuses(store, approvals, "V12", "envelope-subject-exists",
        "a second initial envelope for the subject", request_id="REQ-0002")
publish(approvals, "REQ-0003", statement("REQ-0003", subject="CINST-000008"))
other = ingest(store, approvals, "REQ-0003")
check(other.status == "accepted" and other.envelope_id == "CHENV-0002",
      "another subject is accepted as the next identifier")
check(store.list_records(ENV) and len(store.list_records(ENV)) == 2,
      "two subjects hold one envelope each")

directory = store.root / "capability-health-envelopes"
frozen_store = fresh_store()
frozen_approvals = fresh("approvals")
publish(frozen_approvals, "REQ-F1", statement("REQ-F1", subject="CINST-000009"))
check(ingest(frozen_store, frozen_approvals, "REQ-F1").accepted,
      "a subject's first envelope is accepted")
tampered = (frozen_store.root / "capability-health-envelopes" / "CHENV-0001.yaml")
os.chmod(tampered, 0o600)
tampered.write_text(tampered.read_text().replace("'2000'", "'2001'"))
publish(frozen_approvals, "REQ-F2", statement("REQ-F2", subject="CINST-000009"))
refuses(frozen_store, frozen_approvals, "V12", "envelope-subject-frozen",
        "a subject whose envelope no longer verifies", request_id="REQ-F2")
refuses(frozen_store, frozen_approvals, "V11", "envelope-subject-frozen",
        "replaying the request of an envelope that no longer verifies",
        request_id="REQ-F1")
publish(frozen_approvals, "REQ-F3", statement("REQ-F3", subject="CINST-000010"))
check(ingest(frozen_store, frozen_approvals, "REQ-F3").accepted,
      "freezing is per subject: another subject is still accepted")
(frozen_store.root / "capability-health-envelopes" / "CHENV-0099.yaml").write_text(
    "not: [a record\n")
publish(frozen_approvals, "REQ-F4", statement("REQ-F4", subject="CINST-000011"))
refuses(frozen_store, frozen_approvals, "V12", "envelope-store-unreadable",
        "any subject, while an unattributable record is in the store",
        request_id="REQ-F4")

renamed = fresh_store()
approvals = fresh("approvals")
publish(approvals)
check(ingest(renamed, approvals).accepted, "a subject's first envelope is accepted")
envelopes = renamed.root / "capability-health-envelopes"
(envelopes / "CHENV-0001.yaml").rename(envelopes / "CHENV-0007.yaml")
publish(approvals, "REQ-0002", statement("REQ-0002"))
refuses(renamed, approvals, "V12", "envelope-subject-frozen",
        "a record filed under a name that is not its identifier",
        request_id="REQ-0002")

ambiguous = fresh_store()
approvals = fresh("approvals")
publish(approvals)
check(ingest(ambiguous, approvals).accepted, "a request is accepted once")
envelopes = ambiguous.root / "capability-health-envelopes"
(envelopes / "CHENV-0002.yaml").write_text(
    (envelopes / "CHENV-0001.yaml").read_text().replace(
        "envelope_id: CHENV-0001", "envelope_id: CHENV-0002"))
refuses(ambiguous, approvals, "V11", "request-identity-ambiguous",
        "a request two records claim, which no replay may choose between")

print("--- V13: the record must survive serialisation before allocation ---")


class Unstable(HealthStore):
    @classmethod
    def preview_readback(cls, record):
        payload = super().preview_readback(record)
        payload["notes"] = "changed by serialisation"
        return payload


unstable = fresh_store(Unstable)
approvals = fresh("approvals")
publish(approvals)
refuses(unstable, approvals, "V13", "approval-roundtrip-unstable",
        "a record that would not read back as written")

print("--- V14: allocation, and the permanent gap ---")
exhausted = fresh_store()
(exhausted.root / "sequences" / f"{ENV}.seq").write_text("9999\n")
refuses(exhausted, approvals, "V14", "allocation-refused",
        "an exhausted envelope sequence")

print("--- V15: a refused write leaves a permanent gap ---")
gap = fresh_store()
(gap.root / "capability-health-envelopes" / ".CHENV-0001.tmp").write_text("debris")
result = ingest(gap, approvals)
check(result.status == "refused" and result.stage == "V15"
      and result.reason == "write-refused",
      "an interrupted earlier write's debris refuses the write at V15")
OBSERVED_REASONS.add(result.reason)
check((gap.root / "sequences" / f"{ENV}.seq").read_text().strip() == "1",
      "the refused write consumed CHENV-0001: the sequence stays advanced")
check((gap.root / "capability-health-envelopes" / ".CHENV-0001.tmp").read_text()
      == "debris", "the debris is reported, never truncated or removed")
check(any("partial write" in problem for problem in gap.validate()),
      "validate() reports the debris")
publish(approvals, "REQ-0002", statement("REQ-0002", subject="CINST-000012"))
after_gap = ingest(gap, approvals, "REQ-0002")
check(after_gap.accepted and after_gap.envelope_id == "CHENV-0002",
      "the next envelope is CHENV-0002: the gap at CHENV-0001 is permanent")

print("--- V16: committed but unverified, and the frozen subject ---")


class Corrupting(HealthStore):
    """Changes the committed bytes between fsync and link."""

    def _pre_link_sync_point(self, destination, temporary):
        temporary.write_text(temporary.read_text().replace("'1500'", "'1499'"))


corrupt = fresh_store(Corrupting)
approvals = fresh("approvals")
publish(approvals)
result = ingest(corrupt, approvals)
OBSERVED_REASONS.add(result.reason)
check(result.status == "committed-unverified" and result.stage == "V16"
      and result.envelope_id == "CHENV-0001" and not result.accepted,
      "a record that does not read back as approved is committed-unverified")
check((corrupt.root / "capability-health-envelopes" / "CHENV-0001.yaml").is_file(),
      "the unverified record exists: the immutable store has no undo")
plain = HealthStore(corrupt.root)
refuses(plain, approvals, "V11", "envelope-subject-frozen",
        "retrying the committed-unverified request")
publish(approvals, "REQ-0002", statement("REQ-0002"))
refuses(plain, approvals, "V12", "envelope-subject-frozen",
        "a new request for the committed-unverified subject", request_id="REQ-0002")
publish(approvals, "REQ-0003", statement("REQ-0003", subject="CINST-000013"))
check(ingest(plain, approvals, "REQ-0003").accepted,
      "other subjects are unaffected by a frozen one")

print("--- a crash after the write: retrying replays ---")
CTX = multiprocessing.get_context("fork")
BOUND = 60


class CrashAfterLink(HealthStore):
    def write_record(self, kind, record):
        path = super().write_record(kind, record)
        os._exit(17)


crash_root = fresh("store")
HealthStore(crash_root)
approvals = fresh("approvals")
publish(approvals)


def crash_child():
    ingest(CrashAfterLink(crash_root), approvals)


child = CTX.Process(target=crash_child)
child.start()
child.join(BOUND)
check(child.exitcode == 17, "the ingesting process died after its record was linked")
retry = ingest(HealthStore(crash_root), approvals)
check(retry.status == "replayed" and retry.envelope_id == "CHENV-0001",
      "the retried request resolves its own outcome as a replay")

print("--- concurrency: cross-process, synchronised by seams ---")


class Gate(HealthStore):
    def __init__(self, root, events):
        super().__init__(root)
        self._events = events

    def _test_sync_point(self, phase, request_id):
        reached = self._events.get(f"{phase}:reached")
        if reached is not None:
            reached.set()
            self._events[f"{phase}:release"].wait(BOUND)


def run_child(root, approvals_dir, request_id, events, results):
    outcome = ingest(Gate(root, events), approvals_dir, request_id)
    results.put((request_id, outcome.status, outcome.reason, outcome.envelope_id))


def race(first_request, second_request, between=None, prepare=None):
    """A holds the section after its subject check; B is observed blocked."""
    race_root = fresh("store")
    HealthStore(race_root)
    if prepare is not None:
        prepare(race_root)
    holder = {"subject_checked:reached": CTX.Event(),
              "subject_checked:release": CTX.Event()}
    waiter = {"lock_contended:reached": CTX.Event(),
              "lock_contended:release": CTX.Event()}
    waiter["lock_contended:release"].set()
    results = CTX.Queue()
    a = CTX.Process(target=run_child,
                    args=(race_root, race_approvals, first_request, holder, results))
    a.start()
    held = holder["subject_checked:reached"].wait(BOUND)
    if between is not None:
        between()
    b = CTX.Process(target=run_child,
                    args=(race_root, race_approvals, second_request, waiter, results))
    b.start()
    blocked = waiter["lock_contended:reached"].wait(BOUND)
    holder["subject_checked:release"].set()
    a.join(BOUND)
    b.join(BOUND)
    outcomes = [results.get(timeout=BOUND) for _ in range(2)]
    return held, blocked, outcomes, race_root


race_approvals = fresh("approvals")
publish(race_approvals, "REQ-A", statement("REQ-A"))
publish(race_approvals, "REQ-B", statement("REQ-B"))
held, blocked, outcomes, race_root = race("REQ-A", "REQ-B")
check(held and blocked, "L-3 the holder held the section and the second "
                        "process was observed blocked")
check(sorted(outcomes) == [("REQ-A", "accepted", None, "CHENV-0001"),
                           ("REQ-B", "refused", "envelope-subject-exists", None)],
      f"L-3 two initial envelopes for one subject: one accepted, one refused "
      f"({outcomes})")
check(len(list((race_root / "capability-health-envelopes").glob("*.yaml"))) == 1,
      "L-3 exactly one record was written")

held, blocked, outcomes, race_root = race("REQ-A", "REQ-A")
check(held and blocked, "L-4 the same request raced: the second was blocked")
check(sorted(outcomes) == [("REQ-A", "accepted", None, "CHENV-0001"),
                           ("REQ-A", "replayed", None, "CHENV-0001")],
      f"L-4 the same request and digest: accepted once, replayed once ({outcomes})")

conflicting = envelope_with(lambda e: e["dimensions"]["latency"]["exit_condition"]
                            .update(value="1400"))
publish(race_approvals, "REQ-C", statement("REQ-C"))
held, blocked, outcomes, race_root = race(
    "REQ-C", "REQ-C",
    between=lambda: publish(race_approvals, "REQ-C",
                            statement("REQ-C", envelope=conflicting)))
check(held and blocked, "L-5 the same request with new bytes: the second was blocked")
check(sorted(outcomes) == [("REQ-C", "accepted", None, "CHENV-0001"),
                           ("REQ-C", "refused", "request-identity-conflict", None)],
      f"L-5 the same request, a different digest: one accepted, one conflict "
      f"({outcomes})")

kill_root = fresh("store")
HealthStore(kill_root)
publish(race_approvals, "REQ-K", statement("REQ-K"))
events = {"subject_checked:reached": CTX.Event(),
          "subject_checked:release": CTX.Event()}
victim = CTX.Process(target=run_child,
                     args=(kill_root, race_approvals, "REQ-K", events, CTX.Queue()))
victim.start()
check(events["subject_checked:reached"].wait(BOUND),
      "L-7 an ingesting process holds the section")
os.kill(victim.pid, signal.SIGKILL)
victim.join(BOUND)
survivor = ingest(HealthStore(kill_root), race_approvals, "REQ-K")
check(survivor.status == "accepted" and survivor.envelope_id == "CHENV-0001",
      "L-7 after SIGKILL the next ingestion proceeds; the killed one had not "
      "allocated, so there is no gap")

print("--- L-11: the lock is advisory; a direct write is detected, not prevented ---")
bypass = fresh_store()
approvals = fresh("approvals")
publish(approvals, "REQ-0001", statement("REQ-0001"))
forged = H.parse(ENV, {**ENVELOPE, "envelope_id": "CHENV-0001",
                       "approval": {
                           "approval_statement_version": 1,
                           "approval_domain": "capability-health-envelope",
                           "operation": "initial", "request_id": "REQ-FORGED",
                           "actor": "operator",
                           "approving_authority": "operator-review",
                           "approved_at": "2026-11-16T09:00:00-06:00",
                           "canonicalisation": "kyri-strict-canonical-json/v1",
                           "digest_algorithm": "sha256",
                           "approval_digest": "sha256:" + "0" * 64,
                           "approval_source": {"authority": "health-approvals",
                                               "name": "REQ-FORGED.json"}}})
with bypass.request_critical_section("REQ-HOLDER"):
    HealthStore(bypass.root).write_record(ENV, forged)
check((bypass.root / "capability-health-envelopes" / "CHENV-0001.yaml").is_file(),
      "L-11 a direct write succeeded while the lock was held: no prevention")
refuses(bypass, approvals, "V12", "envelope-subject-frozen",
        "L-11 the unapproved record is detected and freezes its subject")

print("=== ENG-0006-H7b: replacement chains and verify ===")
SUBJECT = ("capability-instance", "CINST-000007")
OBSERVED_FINDINGS = set()


def replacement(request_id, supersedes, version, subject="CINST-000007",
                exit_value=None, **members):
    """A replacement statement; the exit threshold varies with the version."""
    value = exit_value or str(1500 - version)

    def change(e):
        e.update(envelope_version=version, supersedes=supersedes)
        e["dimensions"]["latency"]["exit_condition"]["value"] = value

    members = {"operation": "replacement", **members}
    return statement(request_id, subject=subject, envelope=envelope_with(change),
                     **members)


def verifies(store, approvals, **kwargs):
    kwargs.setdefault("trusted_uid", UID)
    kwargs.setdefault("allow_own_uid_fixture", True)
    report = I.verify(store, approval_root=approvals, **kwargs)
    OBSERVED_FINDINGS.update(f.code for f in report.findings)
    return report


def codes(report):
    return sorted(f.code for f in report.findings)


def record_for(body, envelope_id):
    """The record ingestion writes for `body`, built by hand."""
    data = canonical_json.serialise(body)
    approval = {k: v for k, v in body.items() if k != "envelope"}
    approval["approval_digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
    approval["approval_source"] = {"authority": "health-approvals",
                                   "name": f"{body['request_id']}.json"}
    return H.parse(ENV, {**body["envelope"], "envelope_id": envelope_id,
                         "approval": approval})


def plant(store, body, envelope_id, approvals=None):
    """A direct write, bypassing ingestion and the lock: what a same-UID
    writer can do. The record is self-consistent. With `approvals`, its
    statement is retained as an honest one would be."""
    HealthStore(store.root).write_record(ENV, record_for(body, envelope_id))
    sequence = store.root / "sequences" / f"{ENV}.seq"
    number = int(envelope_id.split("-")[1])
    current = int(sequence.read_text()) if sequence.exists() else 0
    sequence.write_text(f"{max(current, number)}\n")
    if approvals is not None:
        publish(approvals, body["request_id"], body)


def chain_of(length, subject="CINST-000007"):
    """A fresh store holding an ingested chain CHENV-0001 .. CHENV-<length>."""
    store, approvals = fresh_store(), fresh("approvals")
    publish(approvals, "REQ-0001", statement("REQ-0001", subject=subject))
    outcomes = [ingest(store, approvals, "REQ-0001")]
    for version in range(2, length + 1):
        request = f"REQ-{version:04d}"
        publish(approvals, request,
                replacement(request, f"CHENV-{version - 1:04d}", version,
                            subject=subject))
        outcomes.append(ingest(store, approvals, request))
    return store, approvals, outcomes


print("--- C2: a valid replacement chain ---")
store, approvals, outcomes = chain_of(3)
check([(o.status, o.envelope_id) for o in outcomes]
      == [("accepted", "CHENV-0001"), ("accepted", "CHENV-0002"),
          ("accepted", "CHENV-0003")],
      "an initial envelope and two successive replacements are accepted in order")
stored = store.read_record(ENV, "CHENV-0002")
check(stored["supersedes"] == "CHENV-0001" and stored["envelope_version"] == 2
      and stored["approval"]["operation"] == "replacement",
      "the replacement names its predecessor, carries version 2 and the "
      "replacement operation")
retained = (approvals / "REQ-0002.json").read_bytes()
check(stored["approval"]["approval_digest"]
      == "sha256:" + hashlib.sha256(retained).hexdigest()
      and record_for(canonical_json.parse(retained, maximum_bytes=65536),
                     "CHENV-0002").to_dict() == stored,
      "the replacement's record is exactly the one its statement determines")
check("superseded_by" not in store.read_record(ENV, "CHENV-0001"),
      "the predecessor names no successor: succession is derived")
report = verifies(store, approvals)
check(report.clean and report.heads == ((SUBJECT, "CHENV-0003"),)
      and report.frozen == () and not report.blocked,
      f"verify: clean, and the head is CHENV-0003 ({report})")

before = snapshot(store)
again = ingest(store, approvals, "REQ-0002")
check(again.status == "replayed" and again.envelope_id == "CHENV-0002",
      "replaying an accepted replacement after the head moved returns its own "
      "record: replay answers for the request, not the head")
first_again = ingest(store, approvals, "REQ-0001")
check(first_again.status == "replayed" and first_again.envelope_id == "CHENV-0001",
      "replaying the initial request still returns CHENV-0001")
check(snapshot(store) == before, "replays change nothing")

publish(approvals, "REQ-0100", statement("REQ-0100", subject="CINST-000012"))
publish(approvals, "REQ-0101", replacement("REQ-0101", "CHENV-0004", 2,
                                           subject="CINST-000012"))
other = [ingest(store, approvals, r) for r in ("REQ-0100", "REQ-0101")]
check([(o.status, o.envelope_id) for o in other]
      == [("accepted", "CHENV-0004"), ("accepted", "CHENV-0005")],
      "a second subject's chain shares the series and not the head")
report = verifies(store, approvals)
check(report.clean and dict(report.heads)
      == {SUBJECT: "CHENV-0003",
          ("capability-instance", "CINST-000012"): "CHENV-0005"},
      "verify names each subject's head")

print("--- C2: invalid supersession is refused, and writes nothing ---")
store, approvals, _ = chain_of(3)
for label, request, body, stage, reason in (
        ("a replacement of a superseded envelope", "REQ-N1",
         replacement("REQ-N1", "CHENV-0001", 2), "V12", "envelope-not-head"),
        ("a replacement of a superseded envelope with the head's next version",
         "REQ-N2", replacement("REQ-N2", "CHENV-0002", 4), "V12",
         "envelope-not-head"),
        ("a replacement of an envelope that does not exist", "REQ-N3",
         replacement("REQ-N3", "CHENV-0042", 4), "V12", "envelope-not-head"),
        ("the head, with the head's own version", "REQ-N4",
         replacement("REQ-N4", "CHENV-0003", 3), "V12",
         "envelope-version-not-successor"),
        ("the head, skipping a version", "REQ-N5",
         replacement("REQ-N5", "CHENV-0003", 5), "V12",
         "envelope-version-not-successor"),
        ("an initial envelope for a subject with a chain", "REQ-N6",
         statement("REQ-N6"), "V12", "envelope-subject-exists"),
        ("a version-2 replacement naming no predecessor", "REQ-N7",
         statement("REQ-N7", operation="replacement",
                   envelope=envelope_with(lambda e: e.update(envelope_version=2))),
         "V5", "envelope-invalid"),
        ("a malformed predecessor reference", "REQ-N8",
         replacement("REQ-N8", "CHENV-3", 4), "V5", "envelope-invalid"),
        ("a replacement approved as initial", "REQ-N9",
         replacement("REQ-N9", "CHENV-0003", 4, operation="initial"), "V6",
         "approval-operation-mismatch")):
    publish(approvals, request, body)
    refuses(store, approvals, stage, reason, label, request_id=request)
publish(approvals, "REQ-N10", replacement("REQ-N10", "CHENV-0003", 4,
                                          subject="CINST-000012"))
refuses(store, approvals, "V12", "envelope-subject-absent",
        "a replacement naming another subject's head, for a subject with none",
        request_id="REQ-N10")
publish(approvals, "REQ-0100", statement("REQ-0100", subject="CINST-000012"))
check(ingest(store, approvals, "REQ-0100").envelope_id == "CHENV-0004",
      "the second subject's chain starts at CHENV-0004")
publish(approvals, "REQ-N11", replacement("REQ-N11", "CHENV-0003", 2,
                                          subject="CINST-000012"))
refuses(store, approvals, "V12", "envelope-not-head",
        "a replacement naming another subject's head", request_id="REQ-N11")
# The cross-plane table: an identical replacement under a new request, once
# the first is accepted, is a competing successor.
publish(approvals, "REQ-N12", replacement("REQ-N12", "CHENV-0002", 3))
refuses(store, approvals, "V12", "envelope-not-head",
        "a resubmission of an accepted replacement under a new request",
        request_id="REQ-N12")
check(verifies(store, approvals).clean, "after every refusal, verify is clean")

print("--- C2: replay and conflicting approval evidence ---")
store, approvals, _ = chain_of(2)
publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2,
                                           exit_value="1400"))
refuses(store, approvals, "V11", "request-identity-conflict",
        "an accepted replacement's request with different content",
        request_id="REQ-0002")
publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2,
                                           approving_authority="another-review"))
refuses(store, approvals, "V11", "request-identity-conflict",
        "an accepted replacement's request with a different approver",
        request_id="REQ-0002")
publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2))
check(ingest(store, approvals, "REQ-0002").status == "replayed",
      "restoring the original statement replays again")

print("--- frozen subjects: missing or ambiguous heads ---")


def frozen_case(label, build, findings):
    """`build(store, approvals)` breaks the chain of a 1-record subject. Every
    write for that subject then refuses, and verify names the broken rule."""
    store, approvals, _ = chain_of(1)
    build(store, approvals)
    publish(approvals, "REQ-F1", replacement("REQ-F1", "CHENV-0001", 2,
                                             exit_value="1300"))
    refuses(store, approvals, "V12", "envelope-subject-frozen",
            f"{label}: a replacement", request_id="REQ-F1")
    publish(approvals, "REQ-F2", statement("REQ-F2"))
    refuses(store, approvals, "V12", "envelope-subject-frozen",
            f"{label}: an initial envelope", request_id="REQ-F2")
    report = verifies(store, approvals)
    check(set(findings) <= set(codes(report)) and SUBJECT in report.frozen
          and SUBJECT not in dict(report.heads),
          f"{label}: verify reports {findings}, freezes the subject and names "
          f"no head ({codes(report)})")
    publish(approvals, "REQ-F3", statement("REQ-F3", subject="CINST-000099"))
    check(ingest(store, approvals, "REQ-F3").accepted,
          f"{label}: other subjects are unaffected")
    return store, approvals


frozen_case("a fork (W4)", lambda s, a: (
    plant(s, replacement("REQ-P2", "CHENV-0001", 2), "CHENV-0002", a),
    plant(s, replacement("REQ-P3", "CHENV-0001", 2, exit_value="1450"),
          "CHENV-0003", a)), ["chain-fork"])
frozen_case("two roots (W1)", lambda s, a: plant(
    s, statement("REQ-P2", approved_at="2026-11-17T09:00:00-06:00"),
    "CHENV-0002", a), ["chain-root-not-unique"])
frozen_case("a missing predecessor (W2)", lambda s, a: plant(
    s, replacement("REQ-P2", "CHENV-0009", 2), "CHENV-0002", a),
    ["chain-predecessor-missing"])
frozen_case("a skipped version (W3)", lambda s, a: plant(
    s, replacement("REQ-P2", "CHENV-0001", 3), "CHENV-0002", a),
    ["chain-version-not-successor"])
frozen_case("an unverifiable member (W5)", lambda s, a: (
    s.root / "capability-health-envelopes" / "CHENV-0001.yaml").write_text(
    (s.root / "capability-health-envelopes" / "CHENV-0001.yaml").read_text()
    .replace("'1500'", "'1499'")), ["record-unverified"])
frozen_case("a member whose filename is not its identifier (W5)", lambda s, a: (
    s.root / "capability-health-envelopes" / "CHENV-0001.yaml").rename(
    s.root / "capability-health-envelopes" / "CHENV-0008.yaml"),
    ["record-unverified"])

# A subject with no root but one record superseding a missing one.
store, approvals = fresh_store(), fresh("approvals")
plant(store, replacement("REQ-P2", "CHENV-0001", 2), "CHENV-0002", approvals)
report = verifies(store, approvals)
check(codes(report) == ["chain-predecessor-missing", "chain-root-not-unique"]
      and report.frozen == (SUBJECT,),
      f"a chain with no root breaks W1 and W2 ({codes(report)})")
publish(approvals, "REQ-F1", replacement("REQ-F1", "CHENV-0002", 3))
refuses(store, approvals, "V12", "envelope-subject-frozen",
        "a replacement of a rootless chain's only member", request_id="REQ-F1")

# A record naming another subject's envelope breaks ITS subject's chain only.
store, approvals, _ = chain_of(1)
plant(store, replacement("REQ-P2", "CHENV-0001", 2, subject="CINST-000012"),
      "CHENV-0002", approvals)
report = verifies(store, approvals)
check(dict(report.heads) == {SUBJECT: "CHENV-0001"}
      and report.frozen == (("capability-instance", "CINST-000012"),),
      "a record superseding another subject's envelope freezes its own subject "
      "and leaves the other's head alone")
publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2))
check(ingest(store, approvals, "REQ-0002").envelope_id == "CHENV-0003",
      "the untouched subject is still replaced normally")

print("--- committed-unverified and unreadable records ---")
store, approvals, _ = chain_of(1)
publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2,
                                           exit_value="1500"))
result = ingest(Corrupting(store.root), approvals, "REQ-0002")
check(result.status == "committed-unverified" and result.envelope_id == "CHENV-0002",
      "a replacement that does not read back is committed-unverified")
report = verifies(store, approvals)
check(codes(report) == ["record-unverified"]
      and report.findings[0].envelope_id == "CHENV-0002"
      and report.frozen == (SUBJECT,) and not report.heads,
      "verify reports the committed-unverified record and the subject has no head")
publish(approvals, "REQ-0003", replacement("REQ-0003", "CHENV-0002", 3))
refuses(store, approvals, "V12", "envelope-subject-frozen",
        "a replacement of the committed-unverified head", request_id="REQ-0003")
publish(approvals, "REQ-0004", replacement("REQ-0004", "CHENV-0001", 2,
                                           exit_value="1300"))
refuses(store, approvals, "V12", "envelope-subject-frozen",
        "a replacement routing around it: no recovery in H7b (O-5)",
        request_id="REQ-0004")
refuses(store, approvals, "V11", "envelope-subject-frozen",
        "retrying the committed-unverified request", request_id="REQ-0002")

for label, content in (("a record that is not YAML", "{unclosed: ["),
                       ("a record that is not a mapping", "- a list\n"),
                       ("a record naming no subject", "envelope_id: CHENV-0007\n")):
    store, approvals, _ = chain_of(1)
    (store.root / "capability-health-envelopes" / "CHENV-0007.yaml").write_text(content)
    publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2))
    refuses(store, approvals, "V12", "envelope-store-unreadable",
            f"{label}: a replacement of an unrelated subject's head is refused "
            f"(O-5: unattributable blocks all)", request_id="REQ-0002")
    report = verifies(store, approvals)
    check(report.blocked and "record-unattributable" in codes(report)
          and dict(report.heads) == {SUBJECT: "CHENV-0001"},
          f"{label}: verify reports ingestion blocked and still names the "
          f"intact head")
store, approvals, _ = chain_of(1)
link = store.root / "capability-health-envelopes" / "CHENV-0007.yaml"
link.symlink_to(store.root / "capability-health-envelopes" / "CHENV-0001.yaml")
report = verifies(store, approvals)
check(report.blocked and "record-unattributable" in codes(report)
      and "store-structural" in codes(report),
      "a symbolic link in the record directory is unattributable and structural")

print("--- verify: retained statements, request identity, parameters ---")
store, approvals, _ = chain_of(2)
(approvals / "REQ-0001.json").unlink()
report = verifies(store, approvals)
check(codes(report) == ["approval-statement-unavailable"]
      and report.findings[0].envelope_id == "CHENV-0001"
      and report.frozen == (SUBJECT,),
      "a missing retained statement is reported against its record")
publish(approvals, "REQ-0001", statement("REQ-0001", approving_authority="else"))
report = verifies(store, approvals)
check(codes(report) == ["approval-statement-mismatch"],
      "a retained statement that differs from the one recorded is reported")
publish(approvals, "REQ-0001", raw=canonical_json.serialise(
    statement("REQ-0001")) + b"\n")
check(codes(verifies(store, approvals)) == ["approval-statement-mismatch"],
      "a retained statement differing by one byte is reported")
publish(approvals, "REQ-0001", statement("REQ-0001"))
check(verifies(store, approvals).clean, "the restored statement verifies")
publish(approvals, "REQ-0001", statement("REQ-0001"), mode=0o666)
check(codes(verifies(store, approvals)) == ["approval-statement-unavailable"],
      "a world-writable retained statement is unavailable, as at V2")
publish(approvals, "REQ-0001", statement("REQ-0001"))
report = verifies(store, approvals, trusted_uid=0)
check(codes(report) == ["approval-statement-unavailable"] * 2,
      "with root as the trusted owner, statements this user owns verify nothing")
# Documented limit: ingestion's W5 is the record's own consistency, so a
# missing retained statement for a chain member is found by verify only.
(approvals / "REQ-0002.json").unlink()
publish(approvals, "REQ-0003", replacement("REQ-0003", "CHENV-0002", 3))
check(ingest(store, approvals, "REQ-0003").accepted,
      "ingestion does not re-open its predecessors' statements (verify does)")

store, approvals, _ = chain_of(1)
plant(store, statement("REQ-0001", subject="CINST-000012"), "CHENV-0002",
      None)
report = verifies(store, approvals)
check(sorted((f.code, f.envelope_id) for f in report.findings)
      == [("approval-statement-mismatch", "CHENV-0002"),
          ("request-identity-ambiguous", "CHENV-0001"),
          ("request-identity-ambiguous", "CHENV-0002")],
      f"two records claiming one request are both reported ({report.findings})")

store, approvals, _ = chain_of(1)
for label, kwargs, reason in (
        ("own UID without the fixture opt-in", {"allow_own_uid_fixture": False},
         "trusted-uid-is-own-uid"),
        ("a text trusted_uid", {"trusted_uid": "0"}, "parameters-invalid")):
    report = verifies(store, approvals, **kwargs)
    check(report.status == "refused" and report.reason == reason
          and not report.findings, f"verify refuses {label}")
check(I.verify(object(), approval_root=approvals, trusted_uid=0).reason
      == "parameters-invalid", "verify refuses something that is not a store")

print("--- verify changes nothing ---")
store, approvals, _ = chain_of(2)
plant(store, replacement("REQ-P3", "CHENV-0001", 2, exit_value="1450"),
      "CHENV-0003")
(store.root / "capability-health-envelopes" / ".CHENV-0004.tmp").write_text("x")


def metadata(tree):
    return {str(p.relative_to(tree)): (p.stat().st_mode, p.stat().st_mtime_ns,
                                       p.stat().st_size)
            for p in [tree, *sorted(tree.rglob("*"))]}


bytes_before, meta_before = snapshot(store), metadata(store.root)
approvals_before = metadata(approvals)
report = verifies(HealthStore(store.root), approvals)
check(snapshot(store) == bytes_before and metadata(store.root) == meta_before
      and metadata(approvals) == approvals_before,
      "verify of a broken store leaves every byte, mode and mtime unchanged, "
      "in the store and in the approvals")
check({"chain-fork", "approval-statement-unavailable", "store-structural"}
      <= set(codes(report)),
      f"and it reports what it found ({codes(report)})")
with store.request_critical_section("REQ-HOLDER"):
    held_report = verifies(HealthStore(store.root), approvals)
check(held_report == report, "verify takes no lock: it runs while the section "
                             "is held and finds the same")

print("--- permanent identifier gaps after allocation ---")


class FailingWrite(HealthStore):
    def write_record(self, kind, record):
        raise HealthStoreError("injected write failure")


store, approvals, _ = chain_of(1)
publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2))
result = ingest(FailingWrite(store.root), approvals, "REQ-0002")
check(result.stage == "V15" and result.reason == "write-refused",
      "a replacement whose write fails after allocation is refused at V15")
check((store.root / "sequences" / f"{ENV}.seq").read_text().strip() == "2",
      "CHENV-0002 was consumed")
retry = ingest(store, approvals, "REQ-0002")
check(retry.accepted and retry.envelope_id == "CHENV-0003",
      "the retried replacement is CHENV-0003, still superseding the head "
      "CHENV-0001: the gap is permanent")
report = verifies(store, approvals)
check(report.clean and dict(report.heads) == {SUBJECT: "CHENV-0003"},
      "a gap in the series is not a finding: chains follow supersedes, not "
      "numbers")
(store.root / "capability-health-envelopes" / ".CHENV-0004.tmp").write_text("x")
publish(approvals, "REQ-0003", replacement("REQ-0003", "CHENV-0003", 3))
result = ingest(store, approvals, "REQ-0003")
check(result.reason == "write-refused", "debris refuses its name at V15")
report = verifies(store, approvals)
check(codes(report) == ["store-structural"] and dict(report.heads)
      == {SUBJECT: "CHENV-0003"},
      "verify reports the debris and the head is unchanged")
check(ingest(store, approvals, "REQ-0003").envelope_id == "CHENV-0005",
      "the next attempt takes CHENV-0005")

print("--- interrupted replacements: crashes before and after the link ---")


class CrashBeforeLink(HealthStore):
    def _pre_link_sync_point(self, destination, temporary):
        os._exit(19)


for crash_class, code, label in ((CrashBeforeLink, 19, "before"),
                                 (CrashAfterLink, 17, "after")):
    store, approvals, _ = chain_of(1)
    publish(approvals, "REQ-0002", replacement("REQ-0002", "CHENV-0001", 2))

    def crashing(store_root=store.root, cls=crash_class, approvals=approvals):
        ingest(cls(store_root), approvals, "REQ-0002")

    child = CTX.Process(target=crashing)
    child.start()
    child.join(BOUND)
    check(child.exitcode == code,
          f"a replacing process died {label} its record was linked")
    publish(approvals, "REQ-X", replacement("REQ-X", "CHENV-0001", 2,
                                            exit_value="1300"))
    competitor = ingest(HealthStore(store.root), approvals, "REQ-X")
    retry = ingest(HealthStore(store.root), approvals, "REQ-0002")
    if label == "after":
        check(competitor.reason == "envelope-not-head",
              "after the link: a competing replacement is not the head's successor")
        check(retry.status == "replayed" and retry.envelope_id == "CHENV-0002",
              "after the link: the crashed request resolves as a replay")
        check(verifies(store, approvals).clean, "after the link: verify is clean")
    else:
        check(competitor.accepted and competitor.envelope_id == "CHENV-0003",
              "before the link: nothing of the crashed write is a successor, so "
              "a competitor may succeed")
        check(retry.reason == "envelope-not-head",
              "before the link: the crashed request is now refused, not replayed")
        report = verifies(store, approvals)
        check(codes(report) == ["store-structural"]
              and dict(report.heads) == {SUBJECT: "CHENV-0003"},
              "before the link: verify reports the crashed write's debris only")

print("--- L-1 and L-2: competing replacements of one head ---")


def prepare_root(race_root):
    ingest(HealthStore(race_root), race_approvals, "REQ-ROOT")


publish(race_approvals, "REQ-ROOT", statement("REQ-ROOT"))
publish(race_approvals, "REQ-R1", replacement("REQ-R1", "CHENV-0001", 2))
publish(race_approvals, "REQ-R2", replacement("REQ-R2", "CHENV-0001", 2,
                                              exit_value="1300"))
held, blocked, outcomes, race_root = race("REQ-R1", "REQ-R2", prepare=prepare_root)
check(held and blocked, "L-2 the first process holds the section after head "
                        "selection and the second is observed blocked")
check(sorted(outcomes) == [("REQ-R1", "accepted", None, "CHENV-0002"),
                           ("REQ-R2", "refused", "envelope-not-head", None)],
      f"L-2 two processes replace one head: one accepted, one not-head ({outcomes})")
check(sorted(p.name for p in (race_root / "capability-health-envelopes")
             .glob("*.yaml")) == ["CHENV-0001.yaml", "CHENV-0002.yaml"],
      "L-2 exactly one new record")
check(verifies(HealthStore(race_root), race_approvals).clean,
      "L-2 the chain verifies")

held, blocked, outcomes, race_root = race("REQ-R1", "REQ-R1", prepare=prepare_root)
check(held and blocked and sorted(outcomes)
      == [("REQ-R1", "accepted", None, "CHENV-0002"),
          ("REQ-R1", "replayed", None, "CHENV-0002")],
      f"L-4 for a replacement: accepted once, replayed once ({outcomes})")
publish(race_approvals, "REQ-R3", replacement("REQ-R3", "CHENV-0001", 2))
held, blocked, outcomes, race_root = race(
    "REQ-R3", "REQ-R3", prepare=prepare_root,
    between=lambda: publish(race_approvals, "REQ-R3", replacement(
        "REQ-R3", "CHENV-0001", 2, exit_value="1300")))
check(held and blocked and sorted(outcomes)
      == [("REQ-R3", "accepted", None, "CHENV-0002"),
          ("REQ-R3", "refused", "request-identity-conflict", None)],
      f"L-5 for a replacement: one accepted, one conflict ({outcomes})")

# L-1: the same race between two threads of one process, each with its own
# store object. flock belongs to the open file description, so this proves
# the section excludes within a process as well as across processes.
thread_root = fresh("store")
HealthStore(thread_root)
prepare_root(thread_root)
holder = {"subject_checked:reached": threading.Event(),
          "subject_checked:release": threading.Event()}
waiter = {"lock_contended:reached": threading.Event(),
          "lock_contended:release": threading.Event()}
waiter["lock_contended:release"].set()
thread_results = []


def thread_child(request_id, events):
    outcome = ingest(Gate(thread_root, events), race_approvals, request_id)
    thread_results.append((request_id, outcome.status, outcome.reason,
                           outcome.envelope_id))


first = threading.Thread(target=thread_child, args=("REQ-R1", holder))
first.start()
held = holder["subject_checked:reached"].wait(BOUND)
second = threading.Thread(target=thread_child, args=("REQ-R2", waiter))
second.start()
blocked = waiter["lock_contended:reached"].wait(BOUND)
holder["subject_checked:release"].set()
first.join(BOUND)
second.join(BOUND)
check(held and blocked, "L-1 the first thread holds the section after head "
                        "selection and the second is observed blocked")
check(sorted(thread_results) == [("REQ-R1", "accepted", None, "CHENV-0002"),
                                 ("REQ-R2", "refused", "envelope-not-head", None)],
      f"L-1 two threads replace one head: one accepted, one not-head "
      f"({thread_results})")
check(len(list((thread_root / "capability-health-envelopes").glob("*.yaml"))) == 2,
      "L-1 exactly one new record")

print("--- L-11 for C2: a bypassing fork is detected, not prevented ---")
store, approvals, _ = chain_of(2)
with store.request_critical_section("REQ-HOLDER"):
    plant(store, replacement("REQ-FORK", "CHENV-0001", 2, exit_value="1300"),
          "CHENV-0003")
check((store.root / "capability-health-envelopes" / "CHENV-0003.yaml").is_file(),
      "L-11 a competing successor was written directly while the lock was held")
report = verifies(store, approvals)
check({"chain-fork", "approval-statement-unavailable"} <= set(codes(report))
      and report.frozen == (SUBJECT,),
      f"L-11 verify reports the fork and the unapproved record "
      f"({codes(report)})")
publish(approvals, "REQ-0003", replacement("REQ-0003", "CHENV-0002", 3))
refuses(store, approvals, "V12", "envelope-subject-frozen",
        "L-11 and ingestion refuses the forked subject", request_id="REQ-0003")

check(OBSERVED_FINDINGS == I.FINDINGS,
      f"every verify finding is exercised: missing "
      f"{sorted(I.FINDINGS - OBSERVED_FINDINGS)}, unknown "
      f"{sorted(OBSERVED_FINDINGS - I.FINDINGS)}")

print("--- L-10: ingestion is the only envelope writer in the Health plane ---")
writers = []
for path in sorted((root / "tools/health").rglob("*.py")):
    if "__pycache__" in path.parts:
        continue
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and node.func.attr in ("write_record", "write_atomic"):
            writers.append(path.relative_to(root).as_posix())
check(sorted(set(writers)) == ["tools/health/ingest.py", "tools/health/store.py"],
      f"only ingest.py writes records, through the store: {sorted(set(writers))}")

print("--- the result vocabulary ---")
check(OBSERVED_REASONS - {None} <= I.REFUSALS,
      "every observed refusal reason is in the closed vocabulary")
check(I.REFUSALS - OBSERVED_REASONS == set(),
      f"every reason in the vocabulary is exercised above: "
      f"{sorted(I.REFUSALS - OBSERVED_REASONS)}")

print("--- boundaries: no Trust, Fabric or Capability at runtime (T0) ---")
probe = subprocess.run(
    [sys.executable, "-c",
     "import sys; sys.path.insert(0, sys.argv[1]); import tools.health.ingest; "
     "print(' '.join(sorted(m for m in sys.modules if m.startswith('tools.'))))",
     str(root)], capture_output=True, text=True, check=True)
loaded = probe.stdout.split()
check(not [m for m in loaded if m.split(".")[1] in
           ("trust", "fabric", "capability", "collectors", "observation")],
      f"importing ingestion loads no other plane: {loaded}")
check({"tools.common.canonical_json", "tools.common.trusted_source"} <= set(loaded),
      "ingestion uses the shared encoder and trusted_source")

shutil.rmtree(SCRATCH, ignore_errors=True)
check(not SCRATCH.exists(), "the scratch fixture tree is removed")
print()
if failures:
    print(f"Health ingestion validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All health ingestion assertions passed.")
PY

if [[ -e "${PRODUCTION_HEALTH_ROOT}" ]]; then
  production_after="present"
else
  production_after="absent"
fi
if [[ "${production_before}" == "absent" && "${production_after}" == "absent" ]]; then
  printf 'PASS: %s is absent before and after\n' "${PRODUCTION_HEALTH_ROOT}"
else
  printf 'FAIL: %s was %s before and %s after\n' "${PRODUCTION_HEALTH_ROOT}" \
    "${production_before}" "${production_after}" >&2
  exit 1
fi
