#!/usr/bin/env bash
set -Eeuo pipefail

# G11-K: create-route must be rehearsable before the first production route is
# written, and its rehearsal must answer the same question the write answers.
#
# THE GAP THIS CLOSES. `create-route` is registered in `WRITE_OPERATIONS` and in
# `CREATED_KINDS`, so `command_preflight` has always been reachable for it -- and
# nothing had ever driven it. G11-J's mechanical audit found six of the eleven
# write operations with no permanent preflight coverage, and `create-route` was
# the next one due to be used in production.
#
# WHY THAT MATTERS RATHER THAN BEING TIDINESS. R15 was a real defect in
# `admit_instance`'s rehearsal path -- a first admission could not be
# preflighted at all -- and it was found the first time anybody actually
# preflighted that operation, on the eve of spending a governance identity.
# An untested rehearsal path is not a working one; it is an unmeasured one.
#
# WHAT WAS FOUND. Nothing wrong. `create-route --preflight` behaves correctly on
# its first exercise: it predicts the identity, mutates nothing, and refuses for
# the same reasons the write refuses. No source change accompanies this suite.
#
# WHAT IS PINNED HERE.
#
#   * the CLI preflight, end to end, and that it allocates nothing;
#   * preflight/write equivalence -- one predicted identity, one request digest;
#   * every refusal `create_route` can produce, in the released vocabulary,
#     each proven to allocate nothing;
#   * the route identifier is FOUR digits (CROUTE-0001), not six -- routes share
#     the narrow width with CAPDEF/CCON/CPKG/CHOST, while CADV/CINST/CSEL are
#     six. Pinned because prior reports assumed six and the operator input
#     filename follows the identity;
#   * that `create_route` does NOT require its predecessor to be the chain head,
#     and what selection does when that produces a fork. Recorded as observed
#     behaviour, not asserted as correct -- see the G11-K report.
#
# FIXTURE ONLY. Every case works in a temporary root built through the released
# operations. Nothing here reads or writes production authority, and the suite
# proves both stores are unchanged.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-28-g11-k-create-route-preflight.md
#   docs/decisions/ADR-0012-distributed-capability-fabric.md
#   platform-model/schemas/capability-route.schema.yaml

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
    admit_instance, admit_subject, create_route, declare_capability,
    declare_contract, declare_package, register_advertisement,
    withdraw_instance,
)
from tools.fabric.identifiers import CAPABILITY_ROUTE_ID
from tools.fabric.store import FabricStore
from tools.trust.evaluator import create_decision
from tools.trust.models import (
    TrustEvidenceReference, TrustScope, TrustVerificationDetails,
    VerificationMethod,
)
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
ZONE = timezone(timedelta(hours=-5))
STAMP = datetime(2026, 8, 2, 9, 0, 0, tzinfo=ZONE)
LATER = STAMP + timedelta(days=1)
YEAR = STAMP + timedelta(days=365)
OPERATOR = "operator:g11k"
PROV = {"class": "declared", "source": "g11-k"}
NODE = "HOST-0001"
PROFILE = {"architecture": "x86-64", "host_memory_mb": 8192}

REQUEST_SHAPE = {"authority": "tools/x/payload.py", "schema": "s", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/x/env.py", "schema": "e", "schema_version": 1},
    "content": {"authority": "tools/x/con.py", "schema": "c", "schema_version": 1},
}


def seeded_trust(root):
    store = TrustStore(Path(root) / "trust")
    approved = Path(root) / "approved"
    approved.mkdir(exist_ok=True)
    approved.joinpath("root.yaml").write_text(yaml.safe_dump({
        "display_name": "Operator Root Authority",
        "external_identity_reference": "secret-source://approved/operator-root",
        "verification_method": VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        "verification_details": {
            "subject_property": "operator-root-identity",
            "observed_value_reference": "/approved/evidence/root-observed.txt",
            "comparison_source": "in-person-verification-record",
            "performed_by": "operator-role-reference",
            "performed_at": STAMP.isoformat()},
        "evidence_references": [{
            "evidence_id": "TEVID-000001", "kind": "attestation",
            "reference": "/approved/evidence/root-attestation.txt",
            "recorded_at": STAMP.isoformat()}],
        "created_at": STAMP.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"},
    }), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    def grant(subject, subject_type):
        return create_decision(
            store, subject_id=subject, subject_type=subject_type,
            requested_state="trusted", actor_authority_id=authority.authority_id,
            decided_at=STAMP, reason="Granted for the G11-K fixture world.",
            evidence_references=(TrustEvidenceReference(
                evidence_id=store.peek_next_id("evidence"), kind="fingerprint",
                reference="/approved/evidence/fingerprint.txt",
                recorded_at=STAMP),),
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


def world(second_binding=False):
    """The minimum authority create-route needs: one admitted binding."""
    tmp = Path(tempfile.mkdtemp())
    store = FabricStore(tmp / "fabric", expected_uid=UID, expected_gid=GID)
    trust, host_grant, package_grant = seeded_trust(tmp)
    cap = declare_capability(
        store, request_id="g11k-cap", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, name="boundary probe", description="A probe.",
        effect_class="computational", contract_ids=(), provenance=PROV)
    con = declare_contract(
        store, request_id="g11k-con", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, capability_id=cap.record_id, contract_version="1.0.0",
        effect_class="computational", determinism_class="deterministic",
        request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
        failure_modes=("adapter-error",), resource_requirements={},
        compatible_with=(), provenance=PROV)
    pkg = declare_package(
        store, request_id="g11k-pkg", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, capability_id=cap.record_id, contract_id=con.record_id,
        satisfied_contract_versions=("1.0.0",), package_version="1.0.0",
        artifact_reference="tree:probe/1.0.0", resource_requirements={},
        trust_domain="capability-package", provenance=PROV)
    host = admit_subject(
        store, trust, request_id="g11k-host", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP, evaluated_at=STAMP,
        node_identity_reference=NODE,
        fabric_node_trust_record_id=host_grant.record.record_id,
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=PROV)
    adv = register_advertisement(
        store, request_id="g11k-adv", actor=host.record_id, recorded_at=STAMP,
        capability_host_id=host.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile={"architecture": "x86-64"},
        observed_at=STAMP, valid_until=LATER, provenance=PROV)

    def admit(request_id):
        return admit_instance(
            store, trust, request_id=request_id, actor=OPERATOR,
            approving_authority=OPERATOR, recorded_at=STAMP, evaluated_at=STAMP,
            capability_id=cap.record_id, capability_package_id=pkg.record_id,
            capability_host_id=host.record_id, contract_id=con.record_id,
            satisfied_contract_versions=("1.0.0",),
            verified_resource_profile=dict(PROFILE),
            admission_decision_id="approval/g11k",
            package_trust_record_id=package_grant.record.record_id,
            host_trust_record_id=host_grant.record.record_id,
            admission_scope={"permitted_capabilities": ["CAPDEF-0001"],
                             "permitted_operations": ["execute"],
                             "permitted_data_classifications": ["internal"],
                             "permitted_targets": [NODE]},
            admitted_at=STAMP, admitted_until=LATER, provenance=PROV,
            advertisement_id=adv.record_id)

    inst = admit("g11k-inst")
    second = admit("g11k-inst-2") if second_binding else None
    return dict(tmp=tmp, store=store, trust=trust, cap=cap, con=con, pkg=pkg,
                host=host, adv=adv, inst=inst, second=second)


def route_body(w, **overrides):
    fields = dict(
        request_id="g11k-route", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, capability_id=w["cap"].record_id,
        contract_id=w["con"].record_id,
        accepted_contract_versions=("1.0.0",), locality="local-only",
        candidate_instances=(w["inst"].record_id,),
        data_classification="internal", route_version=1, provenance=PROV)
    fields.update(overrides)
    return fields


def routed(w, **overrides):
    return create_route(w["store"], **route_body(w, **overrides))


def nothing_allocated(w, label):
    records = list(w["store"].list_records("capability-route"))
    seq = Path(w["tmp"]) / "fabric" / "sequences" / "capability-route.seq"
    check(not records and not seq.exists(),
          f"    -> {label}: no route written, capability-route.seq absent")


# ===========================================================================
# 1. the identifier grammar, pinned
# ===========================================================================
print("\n--- the route identifier is four digits ---")

check(CAPABILITY_ROUTE_ID.fullmatch("CROUTE-0001") is not None,
      "CROUTE-0001 matches the released route identifier grammar")
check(CAPABILITY_ROUTE_ID.fullmatch("CROUTE-000001") is None,
      "CROUTE-000001 does NOT match: routes are four digits, not six")

w = world()
check(w["store"].peek_next_id("capability-route") == "CROUTE-0001",
      "the first route identity a store would allocate is CROUTE-0001")


# ===========================================================================
# 2. the CLI preflight, end to end -- the gap this suite closes
# ===========================================================================
print("\n--- create-route --preflight, through the released CLI ---")

w = world()
approved = Path(w["tmp"]) / "cli-approved"
approved.mkdir()
body = route_body(w)
body["recorded_at"] = body["recorded_at"].isoformat()
body["accepted_contract_versions"] = list(body["accepted_contract_versions"])
body["candidate_instances"] = list(body["candidate_instances"])
approved.joinpath("route.json").write_text(json.dumps(body, indent=2) + "\n")

completed = subprocess.run(
    [sys.executable, "-m", "tools.fabric.cli", "create-route", "--preflight",
     "--store-root", str(Path(w["tmp"]) / "fabric"),
     "--expected-uid", str(UID), "--expected-gid", str(GID),
     "--input-file", "route.json", "--approved-directory", str(approved)],
    capture_output=True, text=True, cwd=".")
check(completed.returncode == 0,
      f"the CLI preflight exits zero (got {completed.returncode}: "
      f"{completed.stderr.strip()[:120]})")
try:
    payload = json.loads(completed.stdout)
except ValueError:
    payload = {}
    check(False, "the CLI preflight emitted a readable payload")
check(payload.get("outcome") == "preflight", "the CLI reports outcome preflight")
check(payload.get("would_accept") is True,
      f"the CLI reports would_accept true (got {payload.get('would_accept')})")
check(payload.get("rehearsal_outcome") == "preflight"
      and payload.get("rehearsal_reason") is None,
      f"the rehearsal itself reached preflight with no reason "
      f"(got {payload.get('rehearsal_outcome')}/{payload.get('rehearsal_reason')})")
check(payload.get("predicted_record_id") == "CROUTE-0001",
      f"the CLI predicts CROUTE-0001 (got {payload.get('predicted_record_id')})")
check(payload.get("record_kind") == "capability-route", "the record kind is capability-route")
check(payload.get("mutated") is False, "the CLI reports mutating nothing")
check(payload.get("destination_exists") is False, "the destination is reported absent")
nothing_allocated(w, "CLI preflight")
CLI_DIGEST = payload.get("request_digest")


# ===========================================================================
# 3. preflight / write equivalence
# ===========================================================================
print("\n--- the rehearsal answers what the write answers ---")

w = world()
predicted = w["store"].peek_next_id("capability-route")
with A.rehearsing():
    pre = routed(w)
check(pre.outcome == A.PREFLIGHT and pre.reason is None,
      f"an in-process rehearsal reaches preflight (got {pre.outcome}/{pre.reason})")
check(pre.record_id is None, "the rehearsal names no record")
nothing_allocated(w, "in-process rehearsal")

written = routed(w)
check(written.outcome == A.ACCEPTED,
      f"the same body is accepted when written (got {written.outcome}/{written.reason})")
check(written.record_id == predicted,
      f"the written identity is the predicted one ({predicted})")
check(pre.request_digest == written.request_digest,
      "the rehearsal and the write share one request digest")

stored = w["store"].read_record("capability-route", written.record_id)
check(stored.get("capability_id") == w["cap"].record_id
      and stored.get("contract_id") == w["con"].record_id,
      "the stored route names the rehearsed capability and contract")
check(tuple(stored.get("candidate_instances") or ()) == (w["inst"].record_id,),
      "the stored route carries the rehearsed candidate list, in order")
check(stored.get("route_version") == 1 and stored.get("locality") == "local-only"
      and stored.get("data_classification") == "internal",
      "the stored route carries the rehearsed version, locality and classification")
check((stored.get("evidence") or {}).get("reason_category") == "route-change",
      f"a first route is filed as route-change "
      f"(got {(stored.get('evidence') or {}).get('reason_category')})")
check(stored.get("overlap_window") is None, "a first route declares no overlap window")
check(stored.get("supersedes") is None, "a first route supersedes nothing")


# ===========================================================================
# 4. negative controls -- every refusal create_route can produce
# ===========================================================================
print("\n--- refusals, in the released vocabulary ---")

def refuses(label, expect_reason, expect_outcome=A.REFUSED, prep=None, **overrides):
    w = world()
    if prep:
        prep(w)
    result = routed(w, **overrides)
    check(result.outcome == expect_outcome and result.reason == expect_reason,
          f"{label} (got {result.outcome}/{result.reason})")
    nothing_allocated(w, label)

refuses("an unknown candidate instance refuses", "unresolved-reference",
        A.NOT_FOUND, candidate_instances=("CINST-000999",))
refuses("a malformed candidate identifier refuses", "malformed-operation-content",
        A.INVALID, candidate_instances=("CINST-1",))
refuses("an empty candidate list refuses", "no-declared-candidate",
        candidate_instances=())
refuses("an empty accepted version set refuses", "versions-not-declared",
        accepted_contract_versions=())
refuses("an unknown locality refuses", "unknown-locality", A.INVALID,
        locality="orbital")
refuses("an unknown data classification refuses", "unknown-data-classification",
        A.INVALID, data_classification="secret")
refuses("route_version zero refuses", "invalid-route-version", route_version=0)
refuses("a non-integer route_version refuses", "invalid-route-version",
        A.INVALID, route_version="1")
refuses("an unknown superseded route refuses", "unresolved-reference",
        A.NOT_FOUND, supersedes="CROUTE-0009", route_version=2)
refuses("an overlap window without supersession refuses",
        "overlap-window-without-supersession",
        overlap_starts_at=STAMP, overlap_ends_at=LATER)
refuses("a half-declared overlap window refuses", "malformed-overlap-window",
        A.INVALID, overlap_starts_at=STAMP)

# a duplicated candidate needs two identical entries
w = world()
dup = routed(w, candidate_instances=(w["inst"].record_id, w["inst"].record_id))
check(dup.outcome == A.REFUSED and dup.reason == "duplicate-candidate",
      f"a duplicated candidate refuses (got {dup.outcome}/{dup.reason})")
nothing_allocated(w, "duplicate candidate")

# a candidate belonging to a different request class
w = world()
other = declare_capability(
    w["store"], request_id="g11k-cap-2", actor=OPERATOR, approving_authority=OPERATOR,
    recorded_at=STAMP, name="other", description="Another.",
    effect_class="computational", contract_ids=(), provenance=PROV)
mismatch = routed(w, capability_id=other.record_id)
check(mismatch.outcome == A.REFUSED and mismatch.reason == "contract-not-of-capability",
      f"a contract that is not the capability's refuses "
      f"(got {mismatch.outcome}/{mismatch.reason})")
nothing_allocated(w, "contract not of capability")

# A binding that has been withdrawn. `create_route` reads the NAMED record's
# lifecycle_state, and a binding root's state is frozen at "admitted" forever --
# the withdrawal lives in a successor record. So the route is accepted, and the
# refusal arrives at selection instead. Both halves are pinned: the observed
# acceptance, and the compensating control that makes the system fail closed.
w = world()
gone = withdraw_instance(
    w["store"], request_id="g11k-withdraw", actor=OPERATOR,
    approving_authority=OPERATOR, recorded_at=STAMP,
    instance_id=w["inst"].record_id, provenance=PROV)
check(gone.outcome == A.ACCEPTED, "the fixture withdrawal is accepted")
root_state = w["store"].read_record("capability-instance", w["inst"].record_id)
successor_state = w["store"].read_record("capability-instance", gone.record_id)
check(root_state.get("lifecycle_state") == "admitted"
      and successor_state.get("lifecycle_state") == "withdrawn",
      "the withdrawal is a successor record; the binding root stays 'admitted'")
withdrawn = routed(w, request_id="g11k-route-withdrawn")
check(withdrawn.outcome == A.ACCEPTED,
      f"OBSERVED: create_route accepts a route naming a WITHDRAWN binding's root "
      f"(got {withdrawn.outcome}/{withdrawn.reason})")

# The compensating control: selection refuses to select it.
from tools.fabric.selection import select_candidate
picked = select_candidate(
    w["store"], w["trust"], request_id="g11k-select-withdrawn", actor=OPERATOR,
    recorded_at=STAMP, evaluated_at=STAMP, capability_id=w["cap"].record_id,
    contract_id=w["con"].record_id, accepted_contract_versions=("1.0.0",),
    data_classification="internal", locality="local-only", provenance=PROV,
    local_node_identity=NODE)
check(picked.selected_instance_id is None,
      f"selection selects nothing from a route naming a withdrawn binding "
      f"(got {picked.selected_instance_id})")
chosen = w["store"].read_record("capability-selection", picked.record_id)
reasons = [r for entry in (chosen.get("excluded_candidates") or [])
           for r in (entry.get("reasons") or [])]
check("instance-not-admitted" in reasons,
      f"and excludes it as instance-not-admitted (got {reasons})")

# routing to a lifecycle successor rather than the binding root
w = world()
successor = withdraw_instance(
    w["store"], request_id="g11k-withdraw-2", actor=OPERATOR,
    approving_authority=OPERATOR, recorded_at=STAMP,
    instance_id=w["inst"].record_id, provenance=PROV)
not_root = routed(w, request_id="g11k-route-successor",
                  candidate_instances=(successor.record_id,))
check(not_root.outcome == A.REFUSED
      and not_root.reason == "candidate-not-a-binding-root",
      f"routing to a lifecycle successor refuses "
      f"(got {not_root.outcome}/{not_root.reason})")


# ===========================================================================
# 5. supersession
# ===========================================================================
print("\n--- route supersession ---")

w = world(second_binding=True)
first = routed(w)
check(first.outcome == A.ACCEPTED, "the first route is accepted")

bad_version = routed(w, request_id="g11k-route-v1again",
                     supersedes=first.record_id, route_version=1)
check(bad_version.outcome == A.REFUSED
      and bad_version.reason == "invalid-route-version",
      f"a successor whose version does not increase refuses "
      f"(got {bad_version.outcome}/{bad_version.reason})")

other_cap = declare_capability(
    w["store"], request_id="g11k-cap-3", actor=OPERATOR, approving_authority=OPERATOR,
    recorded_at=STAMP, name="third", description="Third.",
    effect_class="computational", contract_ids=(), provenance=PROV)
other_con = declare_contract(
    w["store"], request_id="g11k-con-3", actor=OPERATOR, approving_authority=OPERATOR,
    recorded_at=STAMP, capability_id=other_cap.record_id, contract_version="1.0.0",
    effect_class="computational", determinism_class="deterministic",
    request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
    failure_modes=("adapter-error",), resource_requirements={},
    compatible_with=(), provenance=PROV)
wrong_subject = create_route(
    w["store"], **route_body(w, request_id="g11k-route-subject",
                             capability_id=other_cap.record_id,
                             contract_id=other_con.record_id,
                             supersedes=first.record_id, route_version=2))
check(wrong_subject.outcome == A.REFUSED
      and wrong_subject.reason == "supersedes-different-subject",
      f"a successor for a different request class refuses "
      f"(got {wrong_subject.outcome}/{wrong_subject.reason})")

# a valid cutover, with an overlap window that genuinely shows both
cutover = routed(w, request_id="g11k-route-cutover", supersedes=first.record_id,
                 route_version=2,
                 candidate_instances=(w["inst"].record_id, w["second"].record_id),
                 overlap_starts_at=STAMP, overlap_ends_at=LATER)
check(cutover.outcome == A.ACCEPTED,
      f"a cutover carrying one candidate and adding one is accepted "
      f"(got {cutover.outcome}/{cutover.reason})")

w2 = world(second_binding=True)
base = routed(w2)
no_cutover = routed(w2, request_id="g11k-route-nocut", supersedes=base.record_id,
                    route_version=2, overlap_starts_at=STAMP, overlap_ends_at=LATER)
check(no_cutover.outcome == A.REFUSED
      and no_cutover.reason == "overlap-window-without-cutover",
      f"an overlap that adds nothing refuses "
      f"(got {no_cutover.outcome}/{no_cutover.reason})")

w3 = world(second_binding=True)
base3 = routed(w3)
no_coex = routed(w3, request_id="g11k-route-nocoex", supersedes=base3.record_id,
                 route_version=2, candidate_instances=(w3["second"].record_id,),
                 overlap_starts_at=STAMP, overlap_ends_at=LATER)
check(no_coex.outcome == A.REFUSED
      and no_coex.reason == "overlap-window-without-coexistence",
      f"an overlap that carries nothing forward refuses "
      f"(got {no_coex.outcome}/{no_coex.reason})")


# ===========================================================================
# 6. replay and conflict
# ===========================================================================
print("\n--- request identity ---")

w = world()
one = routed(w)
again = routed(w)
check(again.outcome == A.EXACT_REPLAY and again.record_id == one.record_id,
      f"an identical replay is exact-replay returning the original identity "
      f"(got {again.outcome} -> {again.record_id})")
conflict = routed(w, description="a different route entirely")
check(conflict.outcome == A.CONFLICT
      and conflict.reason == "request_identity_conflict",
      f"the same request_id with a changed body conflicts "
      f"(got {conflict.outcome}/{conflict.reason})")
check(len(list(w["store"].list_records("capability-route"))) == 1,
      "    -> replay and conflict left exactly one route")


# ===========================================================================
# 7. what create_route does NOT check, recorded as observed behaviour
# ===========================================================================
print("\n--- observed: the predecessor need not be the chain head ---")

# create_route requires the successor's version to exceed its predecessor's and
# the request class to match, but never asks whether the predecessor is still
# the head. Two successors of one predecessor are therefore creatable, and
# selection's own traversal is what objects. Pinned as observed behaviour so a
# future change to either side is visible; the G11-K report asks for a ruling.
w = world(second_binding=True)
root = routed(w)
branch_a = routed(w, request_id="g11k-branch-a", supersedes=root.record_id,
                  route_version=2)
branch_b = routed(w, request_id="g11k-branch-b", supersedes=root.record_id,
                  route_version=3)
check(branch_a.outcome == A.ACCEPTED and branch_b.outcome == A.ACCEPTED,
      "two successors of one route are both accepted: head-ness is not checked")

from tools.fabric import selection as S
from tools.fabric.errors import FabricError
forked_reason = None
try:
    S._chain_heads(w["store"], "capability-route")
except FabricError as error:
    forked_reason = str(error)
except Exception as error:  # noqa: BLE001
    forked_reason = f"{type(error).__name__}: {error}"
check(forked_reason is not None,
      f"selection refuses to read a forked route chain rather than picking a winner "
      f"({forked_reason})")


# ===========================================================================
# 8. registration
# ===========================================================================
print("\n--- registration ---")

runner = Path("tools/dev/run-validation.sh").read_text()
ci = Path(".github/workflows/ci.yml").read_text()
check("tests/test-fabric-route-preflight.sh" in runner
      and "tests/test-fabric-route-preflight.sh" in ci,
      "this suite runs in local validation and in CI")

print(f"\n{failures} assertion(s) failed." if failures
      else "\nAll G11-K route preflight assertions passed.")
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
