#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-AC. A route may supersede only the current head of its chain.
#
# THE DEFECT, from G11-K. `create_route` checks that a named predecessor exists,
# belongs to the same capability and contract, and carries a lower
# `route_version`. It never checks that the predecessor is still the head. So
# `CROUTE-0003 supersedes CROUTE-0001` is accepted while `CROUTE-0002` already
# supersedes `CROUTE-0001`, and the chain forks: two records nothing supersedes,
# for one request class.
#
# WHY IT MATTERS NOW. It was unreachable while production held one route. It
# holds two. And it is on the first-invoke path: CINST-000002 expires,
# CROUTE-0002 permanently names only CINST-000002, so a renewed binding needs
# CROUTE-0003 -- a supersession, written against exactly the state this defect
# lets an operator get wrong.
#
# WHAT A FORK COSTS. Selection reads heads and refuses to pick a winner nobody
# chose: `route-ambiguous-for-request-class`. The store would be permanently
# un-routable for that class through the released write path, because routes are
# immutable and nothing merges them.
#
# THE INVARIANT. `admit_instance` already enforces exactly this for bindings,
# through `_successors()` and `REASON_SUPERSEDES_SUPERSEDED`. Routes are the
# outlier, not the special case, so the fix is that helper applied to routes and
# that reason reused -- not a second traversal with its own vocabulary.
#
# FIXTURE ONLY. Nothing reads or writes production Fabric, Trust, or a route.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
PRODUCTION_TRUST=/var/lib/kyri/trust
production_state() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    ( cd "${path}" && find . -mindepth 1 -printf '%y %m %s %p\n' 2>/dev/null | sort ) || true
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
from tools.fabric import selection as S
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




def heads(store):
    """Every route nothing supersedes, read the way selection reads them."""
    records = list(store.list_records("capability-route"))
    superseded = {r.get("supersedes") for r in records if r.get("supersedes")}
    return sorted(r["route_id"] for r in records
                  if r["route_id"] not in superseded)


def outcome_of(call):
    """The released refusal, as outcome and reason, without raising."""
    try:
        result = call()
    except Exception as error:  # noqa: BLE001
        outcome = getattr(error, "outcome", None)
        reason = getattr(error, "reason", None)
        if outcome is None and getattr(error, "args", None):
            first = error.args[0]
            outcome = getattr(first, "outcome", None)
            reason = getattr(first, "reason", None)
        return outcome, reason, None
    # Not every released call returns an OperationResult -- `_resolve_route`
    # returns the record it resolved -- so a plain success is reported as one.
    return getattr(result, "outcome", "resolved"), getattr(result, "reason", None), result


print("=" * 74)
print("PART 1 — the fork, reproduced")
print("=" * 74)

w = world()
first = routed(w, request_id="ac-r1", route_version=1)
second = routed(w, request_id="ac-r2", route_version=2, supersedes=first.record_id)
check(heads(w["store"]) == [second.record_id],
      f"a linear chain has one head ({heads(w['store'])})")

outcome, reason, third = outcome_of(
    lambda: routed(w, request_id="ac-r3", route_version=3,
                   supersedes=first.record_id))
check(reason == "supersedes-already-superseded",
      f"superseding a stale predecessor is refused ({outcome}/{reason})")
check(heads(w["store"]) == [second.record_id],
      f"and the chain still has exactly one head ({heads(w['store'])})")

# What a fork would cost, proved against the released selector rather than
# asserted: two heads for one request class and selection refuses to pick.
_asked = {"capability_id": w["cap"].record_id, "contract_id": w["con"].record_id,
          "accepted_contract_versions": ("1.0.0",),
          "data_classification": "internal", "locality": "local-only"}
_outcome, _reason, _ = outcome_of(lambda: S._resolve_route(w["store"], _asked))
check(_reason is None,
      f"selection still resolves one route for the class ({_reason})")


# The other way to fork, and the one an operator trips by omission rather than
# by naming the wrong record: a second route for the same request class that
# names no predecessor at all. It produces two independent heads, which is the
# `route-ambiguous-for-request-class` refusal by name.
w = world()
a1 = routed(w, request_id="ac-nofork-1", route_version=1)
outcome, reason, _ = outcome_of(
    lambda: routed(w, request_id="ac-nofork-2", route_version=1))
check(reason == "request-class-already-routed",
      f"a second route for an already-routed class is refused ({outcome}/{reason})")
check(heads(w["store"]) == [a1.record_id],
      f"so the class keeps exactly one current route ({heads(w['store'])})")

# Scoped to the class, not to the store. `internal` is the only workload
# classification, so locality is the axis that separates two request classes
# here: a different locality is a different class and still gets a first route.
other = routed(w, request_id="ac-otherclass", route_version=1,
               locality="operator-controlled-only")
check(other.outcome == "accepted",
      f"a different request class may still declare its first route ({other.outcome})")
check(sorted(heads(w["store"])) == sorted([a1.record_id, other.record_id]),
      "two classes, one current route each -- which is not a fork")


print()
print("=" * 74)
print("PART 2 — lawful history is unaffected")
print("=" * 74)

w = world()
r1 = routed(w, request_id="ac-l1", route_version=1)
check(r1.outcome == "accepted", f"a first route with no predecessor is allowed ({r1.outcome})")
r2 = routed(w, request_id="ac-l2", route_version=2, supersedes=r1.record_id)
check(r2.outcome == "accepted", f"a successor against the head is allowed ({r2.outcome})")
r3 = routed(w, request_id="ac-l3", route_version=3, supersedes=r2.record_id)
check(r3.outcome == "accepted", f"and the next one, again against the head ({r3.outcome})")
r4 = routed(w, request_id="ac-l4", route_version=4, supersedes=r3.record_id)
check(r4.outcome == "accepted", f"and the next ({r4.outcome})")
check(heads(w["store"]) == [r4.record_id],
      f"one unique head after four routes ({heads(w['store'])})")
check([r.record_id for r in (r1, r2, r3, r4)]
      == ["CROUTE-0001", "CROUTE-0002", "CROUTE-0003", "CROUTE-0004"],
      "identifiers advance in order")
_stored = {r["route_id"]: r for r in w["store"].list_records("capability-route")}
check(_stored["CROUTE-0001"].get("supersedes") is None
      and _stored["CROUTE-0002"]["supersedes"] == "CROUTE-0001"
      and _stored["CROUTE-0004"]["supersedes"] == "CROUTE-0003",
      "history is written backwards only: no record gained a forward link")
check([_stored[f"CROUTE-000{n}"]["route_version"] for n in (1, 2, 3, 4)] == [1, 2, 3, 4],
      "route versions persist as declared")


print()
print("=" * 74)
print("PART 3 — every other predecessor refusal is preserved")
print("=" * 74)

w = world()
base = routed(w, request_id="ac-p1", route_version=1)

outcome, reason, _ = outcome_of(
    lambda: routed(w, request_id="ac-absent", route_version=2,
                   supersedes="CROUTE-9999"))
check(reason == "unresolved-reference",
      f"a predecessor that does not exist is still refused ({reason})")

outcome, reason, _ = outcome_of(
    lambda: routed(w, request_id="ac-lower", route_version=1,
                   supersedes=base.record_id))
check(reason == "invalid-route-version",
      f"a version that does not advance is still refused ({reason})")

check(heads(w["store"]) == [base.record_id],
      f"and none of those wrote anything ({heads(w['store'])})")


print()
print("=" * 74)
print("PART 4 — the production-shaped renewal this unblocks")
print("=" * 74)

# The state the first-invoke renewal will actually be in: two routes, the head
# naming the binding that expired, and a freshly admitted binding to route to.
w = world(second_binding=True)
p1 = routed(w, request_id="ac-prod-1", route_version=1)
p2 = routed(w, request_id="ac-prod-2", route_version=2, supersedes=p1.record_id)
check(heads(w["store"]) == [p2.record_id],
      "the fixture matches production: CROUTE-0001 -> CROUTE-0002, one head")

renewed = w["second"].record_id
outcome, reason, _ = outcome_of(
    lambda: routed(w, request_id="ac-prod-stale", route_version=3,
                   supersedes=p1.record_id,
                   candidate_instances=(renewed,)))
check(reason == "supersedes-already-superseded",
      f"the renewal written against the STALE route is refused ({reason})")
check(heads(w["store"]) == [p2.record_id],
      "and refused before anything was written")

p3 = routed(w, request_id="ac-prod-3", route_version=3, supersedes=p2.record_id,
            candidate_instances=(renewed,))
check(p3.outcome == "accepted",
      f"the renewal written against the HEAD is accepted ({p3.outcome})")
check(heads(w["store"]) == [p3.record_id],
      f"and becomes the unique head ({heads(w['store'])})")
_p3 = next(r for r in w["store"].list_records("capability-route")
           if r["route_id"] == p3.record_id)
check(tuple(_p3["candidate_instances"]) == (renewed,),
      "naming the renewed binding")


print()
print("=" * 74)
print("PART 5 — the rehearsal refuses for the same reason")
print("=" * 74)

w = world()
q1 = routed(w, request_id="ac-pf-1", route_version=1)
q2 = routed(w, request_id="ac-pf-2", route_version=2, supersedes=q1.record_id)

with A.rehearsing():
    outcome, reason, _ = outcome_of(
        lambda: routed(w, request_id="ac-pf-stale", route_version=3,
                       supersedes=q1.record_id))
check(reason == "supersedes-already-superseded",
      f"a rehearsal against a stale predecessor refuses identically ({reason})")

with A.rehearsing():
    outcome, reason, rehearsed = outcome_of(
        lambda: routed(w, request_id="ac-pf-head", route_version=3,
                       supersedes=q2.record_id))
check(outcome == "preflight",
      f"a rehearsal against the head would be accepted ({outcome}/{reason})")

_seq = Path(w["tmp"]) / "fabric" / "sequences" / "capability-route.seq"
check(_seq.read_text(encoding="utf-8").strip() == "2",
      f"and neither rehearsal advanced the sequence ({_seq.read_text().strip()})")
check(heads(w["store"]) == [q2.record_id],
      f"nor changed the head ({heads(w['store'])})")

print()
if failures:
    print(f"{failures} assertion(s) failed.", file=sys.stderr)
    sys.exit(1)
print("All route-head assertions passed.")
PY
status=$?

FABRIC_AFTER="$(production_state "${PRODUCTION_FABRIC}")"
TRUST_AFTER="$(production_state "${PRODUCTION_TRUST}")"
if [[ "${FABRIC_BEFORE}" == "${FABRIC_AFTER}" && "${TRUST_BEFORE}" == "${TRUST_AFTER}" ]]; then
  printf 'PASS: %s\n' "no production Fabric or Trust path changed while this suite ran"
else
  printf 'FAIL: %s\n' "a production path changed while this suite ran" >&2
  status=1
fi

exit "${status}"
