#!/usr/bin/env bash
set -Eeuo pipefail

# G11-N: register-advertisement must be rehearsable, and its rehearsal must
# answer the same question the write answers.
#
# THE GAP THIS CLOSES. `register-advertisement` has always been registered in
# `WRITE_OPERATIONS` and `CREATED_KINDS`, so `command_preflight` was reachable
# for it, and a production preflight of it was run successfully during the
# CADV-000002 renewal ceremony. Neither fact is coverage: nothing in the suite
# had ever driven it, so nothing would notice if it stopped working. G11-K's
# mechanical audit listed it among the operations with no permanent coverage,
# and it is the next one due in production for the CADV-000003 renewal.
#
# WHAT WAS FOUND. Nothing wrong, in either shape that matters. A FIRST
# advertisement -- `supersedes` absent -- rehearses to preflight, which is the
# exact shape that was broken in `admit_instance` (R15): there, a post-commit
# guard compared the unallocated identity against an absent predecessor and
# refused every first-admission preflight. `register_advertisement` cannot have
# that defect, because it RETURNS `_commit(...)` directly and evaluates nothing
# afterwards. Asserted structurally below, so a future edit that introduced a
# post-commit guard would have to confront this test.
#
# No source change accompanies this suite.
#
# WHAT IS PINNED HERE. Both rehearsal shapes end to end through the released
# CLI; preflight/write equivalence by one predicted identity and one request
# digest; rehearsal determinism; and every refusal `register_advertisement` can
# produce -- structure, references, windows, the resource claim, host currency,
# and all four renewal rules -- each proven to allocate nothing and to advance
# no sequence.
#
# FIXTURE ONLY. Every case works in a temporary root built through the released
# operations. Nothing here reads or writes production authority, and the suite
# proves both stores are unchanged.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-28-g11-n-advertisement-preflight-and-renewal.md
#   docs/decisions/ADR-0012-distributed-capability-fabric.md
#   platform-model/schemas/capability-advertisement.schema.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

PRODUCTION_FABRIC=/var/lib/kyri/fabric              # prod-path-reference
PRODUCTION_TRUST=/var/lib/kyri/trust                # prod-path-reference
production_state() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    { find "${path}" -printf '%y %m %n %U:%G %s %p\n' 2>/dev/null | sort
      find "${path}" -type f -exec sha256sum {} + 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
  else
    printf 'absent'
  fi
}
FABRIC_BEFORE="$(production_state "${PRODUCTION_FABRIC}")"
TRUST_BEFORE="$(production_state "${PRODUCTION_TRUST}")"

python3 - <<'PY'
import json, os, subprocess, sys, tempfile
import yaml
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

from tools.fabric import admission as A
from tools.fabric.admission import (
    admit_subject, declare_capability, declare_contract, declare_package,
    register_advertisement, advertisement_head,
)
from tools.fabric.identifiers import CAPABILITY_ADVERTISEMENT_ID
from tools.fabric.store import FabricStore
from tools.trust.evaluator import create_decision
from tools.trust.models import (
    TrustEvidenceReference, TrustScope, TrustVerificationDetails, VerificationMethod)
from tools.trust.root_authority import declare_root_authority, load_root_declaration
from tools.trust.store import TrustStore

failures = 0
def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        failures += 1
        print(f"FAIL: {description}", file=sys.stderr)

UID, GID = os.geteuid(), os.getegid()
Z = timezone(timedelta(hours=-5))
STAMP = datetime(2026, 8, 2, 9, 0, 0, tzinfo=Z)
LATER = STAMP + timedelta(days=1)
YEAR = STAMP + timedelta(days=365)
OP = "operator:g11n"
PROV = {"class": "declared", "source": "g11-n"}
NODE = "HOST-0001"
PROFILE = {"architecture": "x86-64"}
RS = {"authority": "tools/x/p.py", "schema": "s", "schema_version": 1}
PS = {"envelope": {"authority": "tools/x/e.py", "schema": "e", "schema_version": 1},
      "content": {"authority": "tools/x/c.py", "schema": "c", "schema_version": 1}}


def seeded_trust(root):
    store = TrustStore(Path(root) / "trust")
    ap = Path(root) / "ap"; ap.mkdir(exist_ok=True)
    ap.joinpath("root.yaml").write_text(yaml.safe_dump({
        "display_name": "Operator Root Authority",
        "external_identity_reference": "secret-source://approved/operator-root",
        "verification_method": VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        "verification_details": {
            "subject_property": "operator-root-identity",
            "observed_value_reference": "/approved/evidence/root-observed.txt",
            "comparison_source": "in-person-verification-record",
            "performed_by": "operator-role-reference",
            "performed_at": STAMP.isoformat()},
        "evidence_references": [{"evidence_id": "TEVID-000001", "kind": "attestation",
                                 "reference": "/approved/evidence/root.txt",
                                 "recorded_at": STAMP.isoformat()}],
        "created_at": STAMP.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"}}))
    auth = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(ap)))

    def grant(subject, subject_type):
        return create_decision(
            store, subject_id=subject, subject_type=subject_type,
            requested_state="trusted", actor_authority_id=auth.authority_id,
            decided_at=STAMP, reason="Granted for the G11-N advertisement world.",
            evidence_references=(TrustEvidenceReference(
                evidence_id=store.peek_next_id("evidence"), kind="fingerprint",
                reference="/approved/evidence/fingerprint.txt", recorded_at=STAMP),),
            verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
            verification_details=TrustVerificationDetails(
                subject_property="ssh-host-key-fingerprint",
                observed_value_reference="/approved/evidence/observed.txt",
                comparison_source="printed-console-readout",
                performed_by="operator-role-reference", performed_at=STAMP),
            scope=TrustScope(
                scope_id=store.allocate_id("scope"), subject_type=subject_type,
                permitted_capabilities=("CAPDEF-0001",),
                permitted_operations=("execute",),
                permitted_data_classifications=("internal",),
                permitted_targets=(NODE,),
                validity_start=STAMP, validity_end=YEAR))

    return store, grant(NODE, "fabric-node"), grant("CPKG-0001", "capability-package")


def world(second_package=False):
    """A host that may advertise, and nothing advertised yet."""
    tmp = Path(tempfile.mkdtemp())
    store = FabricStore(tmp / "fabric", expected_uid=UID, expected_gid=GID)
    trust, hg, pg = seeded_trust(tmp)
    cap = declare_capability(store, request_id="g11n-cap", actor=OP,
        approving_authority=OP, recorded_at=STAMP, name="probe",
        description="A probe.", effect_class="computational", contract_ids=(),
        provenance=PROV)
    con = declare_contract(store, request_id="g11n-con", actor=OP,
        approving_authority=OP, recorded_at=STAMP, capability_id=cap.record_id,
        contract_version="1.0.0", effect_class="computational",
        determinism_class="deterministic", request_shape=RS, response_shape=PS,
        failure_modes=("adapter-error",), resource_requirements={},
        compatible_with=(), provenance=PROV)
    pkg = declare_package(store, request_id="g11n-pkg", actor=OP,
        approving_authority=OP, recorded_at=STAMP, capability_id=cap.record_id,
        contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
        package_version="1.0.0", artifact_reference="tree:probe/1.0.0",
        resource_requirements={}, trust_domain="capability-package", provenance=PROV)
    second = None
    if second_package:
        second = declare_package(store, request_id="g11n-pkg-2", actor=OP,
            approving_authority=OP, recorded_at=STAMP, capability_id=cap.record_id,
            contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
            package_version="2.0.0", artifact_reference="tree:probe/2.0.0",
            resource_requirements={}, trust_domain="capability-package",
            provenance=PROV)
    host = admit_subject(store, trust, request_id="g11n-host", actor=OP,
        approving_authority=OP, recorded_at=STAMP, evaluated_at=STAMP,
        node_identity_reference=NODE, fabric_node_trust_record_id=hg.record.record_id,
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=PROV)
    return dict(tmp=tmp, store=store, trust=trust, cap=cap, con=con, pkg=pkg,
                second=second, host=host)


def body_of(w, **overrides):
    fields = dict(
        request_id="g11n-adv", actor=w["host"].record_id, recorded_at=STAMP,
        capability_host_id=w["host"].record_id,
        capability_package_id=w["pkg"].record_id, contract_id=w["con"].record_id,
        satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile=dict(PROFILE),
        observed_at=STAMP, valid_until=LATER, provenance=PROV)
    fields.update(overrides)
    return fields


def advertise(w, **overrides):
    return register_advertisement(w["store"], **body_of(w, **overrides))


def seq_path(w):
    return Path(w["tmp"]) / "fabric" / "sequences" / "capability-advertisement.seq"


def nothing_allocated(w, label, expect_records=0, expect_seq=None):
    records = list(w["store"].list_records("capability-advertisement"))
    seq = seq_path(w)
    now = seq.read_text().strip() if seq.exists() else None
    ok = len(records) == expect_records and now == expect_seq
    check(ok, f"    -> {label}: {expect_records} advertisement(s), sequence "
              f"{'absent' if expect_seq is None else expect_seq}"
              + ("" if ok else f"  [got {len(records)} / {now}]"))


def trust_state(w):
    root = Path(w["tmp"]) / "trust"
    return {str(p.relative_to(root)): __import__("hashlib").sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


# ===========================================================================
# 1. structure: the R15 shape cannot exist here
# ===========================================================================
print("\n--- register_advertisement has no post-commit guard ---")

source = Path("tools/fabric/admission.py").read_text()
start = source.index("def register_advertisement")
end = source.index("\ndef ", start + 10)
fn = source[start:end]
tail = fn[fn.index("return _commit("):]
check("_commit" in tail and "allocated ==" not in tail,
      "register_advertisement returns _commit directly and evaluates nothing after it")
check(CAPABILITY_ADVERTISEMENT_ID.fullmatch("CADV-000001") is not None
      and CAPABILITY_ADVERTISEMENT_ID.fullmatch("CADV-0001") is None,
      "advertisement identifiers are six digits")


# ===========================================================================
# 2. a FIRST advertisement rehearses -- the shape R15 broke in admit_instance
# ===========================================================================
print("\n--- a first advertisement (supersedes absent) ---")

w = world()
check(w["store"].peek_next_id("capability-advertisement") == "CADV-000001",
      "the first advertisement identity is CADV-000001")
trust_before = trust_state(w)

with A.rehearsing():
    first_pre = register_advertisement(
        FabricStore.open_for_read(str(Path(w["tmp"]) / "fabric"),
                                  expected_uid=UID, expected_gid=GID),
        **body_of(w))
check(first_pre.outcome == A.PREFLIGHT and first_pre.reason is None,
      f"a first advertisement rehearses to preflight "
      f"(got {first_pre.outcome}/{first_pre.reason})")
check(first_pre.record_id is None, "the rehearsal names no record")
nothing_allocated(w, "first-advertisement rehearsal")
check(trust_state(w) == trust_before, "the rehearsal mutated no Trust state")

# determinism: rehearsing twice over an unchanged store answers identically
with A.rehearsing():
    again = register_advertisement(
        FabricStore.open_for_read(str(Path(w["tmp"]) / "fabric"),
                                  expected_uid=UID, expected_gid=GID),
        **body_of(w))
check(again.outcome == first_pre.outcome
      and again.request_digest == first_pre.request_digest,
      "a repeated rehearsal over an unchanged store answers identically")
nothing_allocated(w, "repeated rehearsal")

first = advertise(w)
check(first.outcome == A.ACCEPTED, f"the same body is accepted when written "
                                   f"(got {first.outcome}/{first.reason})")
check(first.record_id == "CADV-000001", f"the written identity is the predicted one "
                                        f"({first.record_id})")
check(first.request_digest == first_pre.request_digest,
      "the rehearsal and the write share one request digest")
nothing_allocated(w, "after the first write", expect_records=1, expect_seq="1")


# ===========================================================================
# 3. a SUCCESSOR advertisement rehearses
# ===========================================================================
print("\n--- a successor advertisement (supersedes the head) ---")

renewal = dict(request_id="g11n-adv-2", recorded_at=LATER, observed_at=LATER,
               valid_until=LATER + timedelta(days=1), supersedes=first.record_id)
predicted = w["store"].peek_next_id("capability-advertisement")
check(predicted == "CADV-000002", f"the successor identity is CADV-000002 ({predicted})")

with A.rehearsing():
    succ_pre = register_advertisement(
        FabricStore.open_for_read(str(Path(w["tmp"]) / "fabric"),
                                  expected_uid=UID, expected_gid=GID),
        **body_of(w, **renewal))
check(succ_pre.outcome == A.PREFLIGHT and succ_pre.reason is None,
      f"a successor advertisement rehearses to preflight "
      f"(got {succ_pre.outcome}/{succ_pre.reason})")
nothing_allocated(w, "successor rehearsal", expect_records=1, expect_seq="1")

succ = advertise(w, **renewal)
check(succ.outcome == A.ACCEPTED, f"the successor is accepted when written "
                                  f"(got {succ.outcome}/{succ.reason})")
check(succ.record_id == predicted, "the successor takes the predicted identity")
check(succ.request_digest == succ_pre.request_digest,
      "the successor rehearsal and write share one request digest")

stored = w["store"].read_record("capability-advertisement", succ.record_id)
check(stored.get("supersedes") == first.record_id,
      "the successor names its predecessor")
check((stored.get("evidence") or {}).get("reason_category") == "supersession",
      "the successor is filed as supersession")
check(first.record_id in ((stored.get("evidence") or {}).get("causal_references") or ()),
      "the successor's evidence references the predecessor")
prior = w["store"].read_record("capability-advertisement", first.record_id)
check(prior.get("superseded_by") is None,
      "the predecessor acquires no superseded_by backlink")
check(advertisement_head(w["store"], first.record_id) == succ.record_id,
      "the chain head moves to the successor")


# ===========================================================================
# 4. replay and request identity
# ===========================================================================
print("\n--- request identity ---")

replay = advertise(w, **renewal)
check(replay.outcome == A.EXACT_REPLAY and replay.record_id == succ.record_id,
      f"an identical replay is exact-replay returning the original identity "
      f"(got {replay.outcome} -> {replay.record_id})")
conflict = advertise(w, **dict(renewal, provenance=dict(PROV, source="elsewhere")))
check(conflict.outcome == A.CONFLICT and conflict.reason == "request_identity_conflict",
      f"the same request_id with a changed body conflicts "
      f"(got {conflict.outcome}/{conflict.reason})")
check(len(list(w["store"].list_records("capability-advertisement"))) == 2,
      "    -> replay and conflict left exactly two advertisements")


# ===========================================================================
# 5. refusals, in the released vocabulary
# ===========================================================================
print("\n--- refusals ---")

def refuses(label, expect_reason, expect_outcome=A.REFUSED, prep=None, **overrides):
    fresh = world()
    if prep:
        prep(fresh)
    result = advertise(fresh, **overrides)
    check(result.outcome == expect_outcome and result.reason == expect_reason,
          f"{label} (got {result.outcome}/{result.reason})")
    nothing_allocated(fresh, label)

# structure
refuses("an approving authority refuses -- a self-report is not approved",
        "unexpected-approving-authority", approving_authority=OP)
refuses("a window that ends before it opens refuses", "invalid-validity-window",
        valid_until=STAMP - timedelta(hours=1))
refuses("a window that closed before recorded_at refuses", "invalid-validity-window",
        observed_at=STAMP - timedelta(days=3), valid_until=STAMP - timedelta(days=2))
refuses("a window that opens after recorded_at refuses", "invalid-validity-window",
        observed_at=STAMP + timedelta(hours=1),
        valid_until=STAMP + timedelta(days=1))
refuses("an empty accepted version set refuses", "versions-not-declared",
        satisfied_contract_versions=())
refuses("a malformed host identifier refuses", "malformed-operation-content",
        A.INVALID, capability_host_id="CHOST-1")

# references and relationships
refuses("an unknown host refuses", "unresolved-reference", A.NOT_FOUND,
        capability_host_id="CHOST-0009", actor="CHOST-0009")
refuses("an unknown package refuses", "unresolved-reference", A.NOT_FOUND,
        capability_package_id="CPKG-0009")
refuses("a host advertising something that is not itself refuses",
        "actor-is-not-the-subject", actor="somebody-else")
refuses("a version the package does not declare refuses", "versions-not-declared",
        satisfied_contract_versions=("9.9.9",))
refuses("a resource claim the host has not verified refuses",
        "resource-claim-not-verified",
        advertised_resource_profile={"architecture": "x86-64", "host_cpu_cores": 8})

# a contract that is not the package's
def other_contract(fresh):
    fresh["other_con"] = declare_contract(
        fresh["store"], request_id="g11n-con-2", actor=OP, approving_authority=OP,
        recorded_at=STAMP, capability_id=fresh["cap"].record_id,
        contract_version="2.0.0", effect_class="computational",
        determinism_class="deterministic", request_shape=RS, response_shape=PS,
        failure_modes=("adapter-error",), resource_requirements={},
        compatible_with=(), provenance=PROV)
fresh = world(); other_contract(fresh)
mismatch = advertise(fresh, contract_id=fresh["other_con"].record_id)
check(mismatch.outcome == A.REFUSED and mismatch.reason == "contract-not-of-package",
      f"a contract the package does not name refuses "
      f"(got {mismatch.outcome}/{mismatch.reason})")
nothing_allocated(fresh, "contract not of package")


# ===========================================================================
# 6. renewal rules -- all four
# ===========================================================================
print("\n--- renewal ---")

def renewed_world(second_package=False):
    fresh = world(second_package=second_package)
    base = advertise(fresh)
    assert base.outcome == A.ACCEPTED, base.to_dict()
    return fresh, base

fresh, base = renewed_world()
r1 = advertise(fresh, request_id="g11n-r1", recorded_at=LATER, observed_at=LATER,
               valid_until=LATER + timedelta(days=1), supersedes="CADV-000009")
check(r1.outcome == A.NOT_FOUND and r1.reason == "unresolved-reference",
      f"R1: a predecessor that does not exist refuses (got {r1.outcome}/{r1.reason})")

# R2 needs a second host that resolves, so the renewal rule -- not the
# reference check -- is what objects. Cloned in the fixture, as the released
# path cannot mint a second host without a second trust grant.
fresh, base = renewed_world()
hp = Path(fresh["tmp"]) / "fabric" / "capability-hosts" / f"{fresh['host'].record_id}.yaml"
twin = yaml.safe_load(hp.read_text())
twin["capability_host_id"] = "CHOST-0002"
twin["node_identity_reference"] = "HOST-0002"
(hp.parent / "CHOST-0002.yaml").write_text(yaml.safe_dump(twin, sort_keys=True))
r2 = advertise(fresh, request_id="g11n-r2", recorded_at=LATER, observed_at=LATER,
               valid_until=LATER + timedelta(days=1), supersedes=base.record_id,
               capability_host_id="CHOST-0002", actor="CHOST-0002")
check(r2.outcome == A.REFUSED and r2.reason == "renewal-of-another-host",
      f"R2: renewing another host's advertisement refuses "
      f"(got {r2.outcome}/{r2.reason})")

fresh, base = renewed_world(second_package=True)
r3 = advertise(fresh, request_id="g11n-r3", recorded_at=LATER, observed_at=LATER,
               valid_until=LATER + timedelta(days=1), supersedes=base.record_id,
               capability_package_id=fresh["second"].record_id)
check(r3.outcome == A.REFUSED and r3.reason == "renewal-changes-package",
      f"R3: a renewal that changes the package refuses (got {r3.outcome}/{r3.reason})")

fresh, base = renewed_world()
mid = advertise(fresh, request_id="g11n-mid", recorded_at=LATER, observed_at=LATER,
                valid_until=LATER + timedelta(days=1), supersedes=base.record_id)
check(mid.outcome == A.ACCEPTED, "a first renewal is accepted")
r4 = advertise(fresh, request_id="g11n-r4", recorded_at=LATER + timedelta(hours=1),
               observed_at=LATER + timedelta(hours=1),
               valid_until=LATER + timedelta(days=2), supersedes=base.record_id)
check(r4.outcome == A.REFUSED and r4.reason == "renewal-predecessor-not-current",
      f"R4: renewing an already-superseded predecessor refuses "
      f"(got {r4.outcome}/{r4.reason})")

# an EXPIRED predecessor is still a lawful predecessor -- freshness gates
# consumption, not supersession. This is the G11-F ruling, pinned.
fresh, base = renewed_world()
much_later = LATER + timedelta(days=30)
expired_ok = advertise(fresh, request_id="g11n-expired-pred",
                       recorded_at=much_later, observed_at=much_later,
                       valid_until=much_later + timedelta(days=1),
                       supersedes=base.record_id)
check(expired_ok.outcome == A.ACCEPTED,
      f"an EXPIRED predecessor may still be superseded "
      f"(got {expired_ok.outcome}/{expired_ok.reason})")

# a damaged chain fails closed through the governed traversal
fresh, base = renewed_world()
path = Path(fresh["tmp"]) / "fabric" / "capability-advertisements" / f"{base.record_id}.yaml"
damaged = yaml.safe_load(path.read_text())
damaged["supersedes"] = base.record_id
path.write_text(yaml.safe_dump(damaged, sort_keys=True))
cyclic = advertise(fresh, request_id="g11n-cyclic", recorded_at=LATER,
                   observed_at=LATER, valid_until=LATER + timedelta(days=1),
                   supersedes=base.record_id)
check(cyclic.outcome == A.REFUSED and cyclic.reason == "advertisement-chain-cyclic",
      f"a cyclic advertisement chain refuses (got {cyclic.outcome}/{cyclic.reason})")

# a superseded HOST declaration cannot advertise
fresh = world()
host_path = Path(fresh["tmp"]) / "fabric" / "capability-hosts" / f"{fresh['host'].record_id}.yaml"
clone = yaml.safe_load(host_path.read_text())
clone["capability_host_id"] = "CHOST-0002"
clone["supersedes"] = fresh["host"].record_id
(host_path.parent / "CHOST-0002.yaml").write_text(yaml.safe_dump(clone, sort_keys=True))
superseded_host = advertise(fresh, request_id="g11n-host-superseded")
check(superseded_host.outcome == A.REFUSED
      and superseded_host.reason == "host-record-superseded",
      f"a superseded host declaration cannot advertise "
      f"(got {superseded_host.outcome}/{superseded_host.reason})")
nothing_allocated(fresh, "superseded host")


# ===========================================================================
# 7. the CLI preflight, end to end -- where the gap actually was
# ===========================================================================
print("\n--- register-advertisement --preflight, through the released CLI ---")

for label, extra, expect_id in (
        ("first", {}, "CADV-000001"),
        ("successor", {"supersedes": "CADV-000001"}, "CADV-000002")):
    fresh = world()
    if expect_id == "CADV-000002":
        seeded = advertise(fresh)
        assert seeded.outcome == A.ACCEPTED, seeded.to_dict()
    approved = Path(fresh["tmp"]) / "cli-approved"; approved.mkdir()
    payload = body_of(fresh, request_id=f"g11n-cli-{label}", **extra)
    if expect_id == "CADV-000002":
        payload.update(recorded_at=LATER, observed_at=LATER,
                       valid_until=LATER + timedelta(days=1))
    for field in ("recorded_at", "observed_at", "valid_until"):
        payload[field] = payload[field].isoformat()
    payload["satisfied_contract_versions"] = list(payload["satisfied_contract_versions"])
    approved.joinpath("adv.json").write_text(json.dumps(payload, indent=2) + "\n")

    done = subprocess.run(
        [sys.executable, "-m", "tools.fabric.cli", "register-advertisement",
         "--preflight", "--store-root", str(Path(fresh["tmp"]) / "fabric"),
         "--expected-uid", str(UID), "--expected-gid", str(GID),
         "--input-file", "adv.json", "--approved-directory", str(approved)],
        capture_output=True, text=True, cwd=".")
    check(done.returncode == 0,
          f"the CLI preflight of a {label} advertisement exits zero "
          f"(got {done.returncode}: {done.stderr.strip()[:100]})")
    try:
        out = json.loads(done.stdout)
    except ValueError:
        out = {}
        check(False, f"the {label} CLI preflight emitted a readable payload")
    check(out.get("would_accept") is True,
          f"the {label} CLI preflight reports would_accept true "
          f"(got {out.get('would_accept')})")
    check(out.get("rehearsal_outcome") == "preflight"
          and out.get("rehearsal_reason") is None,
          f"the {label} rehearsal reached preflight with no reason")
    check(out.get("predicted_record_id") == expect_id,
          f"the {label} CLI preflight predicts {expect_id} "
          f"(got {out.get('predicted_record_id')})")
    check(out.get("mutated") is False and out.get("destination_exists") is False,
          f"the {label} CLI preflight mutates nothing and finds no destination")
    expected_records = 0 if expect_id == "CADV-000001" else 1
    expected_seq = None if expect_id == "CADV-000001" else "1"
    nothing_allocated(fresh, f"{label} CLI preflight",
                      expect_records=expected_records, expect_seq=expected_seq)


# ===========================================================================
# 8. registration
# ===========================================================================
print("\n--- registration ---")
runner = Path("tools/dev/run-validation.sh").read_text()
ci = Path(".github/workflows/ci.yml").read_text()
check("tests/test-fabric-advertisement-preflight.sh" in runner
      and "tests/test-fabric-advertisement-preflight.sh" in ci,
      "this suite runs in local validation and in CI")

print(f"\n{failures} assertion(s) failed." if failures
      else "\nAll G11-N advertisement preflight assertions passed.")
sys.exit(1 if failures else 0)
PY
STATUS=$?

printf '\n'
PROBLEMS=0
if [[ "$(production_state "${PRODUCTION_FABRIC}")" != "${FABRIC_BEFORE}" ]]; then
  printf 'FAIL: the production Fabric store moved\n' >&2; PROBLEMS=1
fi
if [[ "$(production_state "${PRODUCTION_TRUST}")" != "${TRUST_BEFORE}" ]]; then
  printf 'FAIL: the production Trust store moved\n' >&2; PROBLEMS=1
fi
if (( PROBLEMS == 0 )); then
  printf 'PASS: the production Fabric and Trust stores are unchanged\n'
else
  STATUS=1
fi

exit "${STATUS}"
