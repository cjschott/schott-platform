#!/usr/bin/env bash
set -Eeuo pipefail

# G11-AG: an admission may not claim authority its advertisement does not have.
#
# THE DEFECT. `admit_instance` checked three clock facts and never the fourth.
# It required the advertisement to be fresh at `evaluated_at`, the binding not
# to begin before the claim, and the admission window not to be already closed.
# It never required the admission window to END inside the advertisement's.
#
# So `admitted_until > advertisement.valid_until` was admissible, and the
# interval [valid_until, admitted_until) is an R17 tail: the instance is
# lifecycle-admitted and its ELIG-7 window is open, while ELIG-6 refuses
# because the claim it depends on has lapsed. Historical CINST-000001 has
# exactly this shape. G11-Q avoided it for CINST-000002 by hand, setting
# `admitted_until == CADV-000003.valid_until` -- ceremony discipline, not
# structure.
#
# THE INVARIANT. `admitted_until <= advertisement.valid_until`.
#
# Both windows are half-open and right-exclusive -- admission is
# `admitted_at <= t < admitted_until` and the claim is
# `observed_at <= t < valid_until`, in `_admitted`/`_advertised` and in
# `admit_instance` alike. So equality is exact coincidence, not a one-instant
# overhang, and it is accepted rather than tolerated.
#
# THIS IS DEFENCE IN DEPTH, NOT A REPLACEMENT. G11-Y re-evaluates every
# condition at invoke, and must continue to: a bound admission can still become
# ineligible through trust, quarantine, host availability, or the advertisement
# lapsing early. §I pins that the write-time bound removes nothing.
#
# HISTORY IS NOT REWRITTEN. CINST-000001 stays as evidence, and would fail this
# invariant if resubmitted. Nothing migrates, backfills, or rewrites it; it
# already fails closed at runtime, and §H pins that too.
#
# FIXTURE ONLY. Every case works in a temporary root. Nothing here touches
# /var/lib/kyri, and the suite proves it did not.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-28-g11-q-cinst-000002-renewal-preparation.md
#   docs/development/reports/eng-0005/2026-08-29-g11-y-invoke-current-eligibility.md
#   platform-model/schemas/capability-instance.schema.yaml

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
import os, sys, tempfile
import yaml
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

from tools.fabric import admission as A
from tools.fabric import eligibility as E
from tools.fabric.admission import (
    admit_instance, declare_capability, declare_contract, declare_package,
    admit_subject, register_advertisement, rehearsing,
)
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

# The four instants the invariant is about, named as the brief names them.
T0 = datetime(2026, 8, 2, 9, 0, 0, tzinfo=ZONE)   # advertisement observed_at
T1 = T0                                            # admitted_at
T2 = T0 + timedelta(days=1)                        # advertisement valid_until
T3 = T2 + timedelta(days=1)                        # overlong admitted_until
INSIDE = T2 - timedelta(hours=1)                   # a bounded admitted_until
TAIL = T2 + timedelta(hours=1)                     # an instant in the R17 tail
YEAR = T0 + timedelta(days=365)

OPERATOR = "operator:g11ag"
PROV = {"class": "declared", "source": "g11-ag"}
NODE = "HOST-0001"
PROFILE = {"architecture": "x86-64", "host_memory_mb": 8192}
REQUEST_SHAPE = {"authority": "tools/x/payload.py", "schema": "s", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/x/env.py", "schema": "e", "schema_version": 1},
    "content": {"authority": "tools/x/con.py", "schema": "c", "schema_version": 1},
}


# --- one throwaway world ----------------------------------------------------

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
            "performed_at": T0.isoformat()},
        "evidence_references": [{
            "evidence_id": "TEVID-000001", "kind": "attestation",
            "reference": "/approved/evidence/root-attestation.txt",
            "recorded_at": T0.isoformat()}],
        "created_at": T0.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"},
    }), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    def grant(subject, subject_type):
        return create_decision(
            store, subject_id=subject, subject_type=subject_type,
            requested_state="trusted", actor_authority_id=authority.authority_id,
            decided_at=T0, reason="Granted for the G11-AG fixture world.",
            evidence_references=(TrustEvidenceReference(
                evidence_id=store.peek_next_id("evidence"), kind="fingerprint",
                reference="/approved/evidence/fingerprint.txt",
                recorded_at=T0),),
            verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
            verification_details=TrustVerificationDetails(
                subject_property="ssh-host-key-fingerprint",
                observed_value_reference="/approved/evidence/observed.txt",
                comparison_source="printed-console-readout",
                performed_by="operator-role-reference", performed_at=T0),
            scope=TrustScope(
                scope_id=store.allocate_id("scope"), subject_type=subject_type,
                permitted_capabilities=("CAPDEF-0001",),
                permitted_operations=("execute",),
                permitted_data_classifications=("internal",),
                permitted_targets=(NODE,),
                validity_start=T0, validity_end=YEAR))

    return store, grant(NODE, "fabric-node"), grant("CPKG-0001", "capability-package")


def world():
    tmp = Path(tempfile.mkdtemp())
    store = FabricStore(tmp / "fabric", expected_uid=UID, expected_gid=GID)
    trust, host_grant, package_grant = seeded_trust(tmp)
    cap = declare_capability(
        store, request_id="g11ag-cap", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=T0, name="boundary probe", description="A probe.",
        effect_class="computational", contract_ids=(), provenance=PROV)
    con = declare_contract(
        store, request_id="g11ag-con", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=T0, capability_id=cap.record_id, contract_version="1.0.0",
        effect_class="computational", determinism_class="deterministic",
        request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
        failure_modes=("adapter-error",), resource_requirements={},
        compatible_with=(), provenance=PROV)
    pkg = declare_package(
        store, request_id="g11ag-pkg", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=T0, capability_id=cap.record_id, contract_id=con.record_id,
        satisfied_contract_versions=("1.0.0",), package_version="1.0.0",
        artifact_reference="tree:probe/1.0.0", resource_requirements={},
        trust_domain="capability-package", provenance=PROV)
    host = admit_subject(
        store, trust, request_id="g11ag-host", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=T0, evaluated_at=T0,
        node_identity_reference=NODE,
        fabric_node_trust_record_id=host_grant.record.record_id,
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=PROV)
    adv = register_advertisement(
        store, request_id="g11ag-adv", actor=host.record_id, recorded_at=T0,
        capability_host_id=host.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile={"architecture": "x86-64"},
        observed_at=T0, valid_until=T2, provenance=PROV)
    return dict(tmp=tmp, store=store, trust=trust, cap=cap, con=con, pkg=pkg,
                host=host, adv=adv, host_grant=host_grant,
                package_grant=package_grant)


def body_of(w, **overrides):
    fields = dict(
        request_id="g11ag-inst", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=T0, evaluated_at=T0,
        capability_id=w["cap"].record_id,
        capability_package_id=w["pkg"].record_id,
        capability_host_id=w["host"].record_id,
        contract_id=w["con"].record_id,
        satisfied_contract_versions=("1.0.0",),
        verified_resource_profile=dict(PROFILE),
        admission_decision_id="approval/g11ag",
        package_trust_record_id=w["package_grant"].record.record_id,
        host_trust_record_id=w["host_grant"].record.record_id,
        admission_scope={"permitted_capabilities": ["CAPDEF-0001"],
                         "permitted_operations": ["execute"],
                         "permitted_data_classifications": ["internal"],
                         "permitted_targets": [NODE]},
        admitted_at=T1, admitted_until=T2, provenance=PROV,
        advertisement_id=w["adv"].record_id)
    fields.update(overrides)
    return fields


def admission_of(w, **overrides):
    return admit_instance(w["store"], w["trust"], **body_of(w, **overrides))


BOUND = "admission-window-exceeds-advertisement"

print("== B. the defect, and the R17 tail it creates ==\n")

# The overlong request the invariant exists to refuse: T3 > T2.
w = world()
overlong = admission_of(w, admitted_until=T3)
check(overlong.outcome == A.REFUSED,
      "an admission ending after its advertisement's validity is refused")
check(overlong.reason == BOUND,
      f"the refusal names the dependency: {overlong.reason!r} == {BOUND!r}")
check(w["store"].peek_next_id("capability-instance") == "CINST-000001",
      "the refused overlong admission allocated no instance identity")

# The tail itself, on a record of the shape the defect used to produce. Built
# as a mapping rather than written, because the write is now refused -- which
# is the point. The advertisement it names is the real fixture record, so
# ELIG-6 resolves it exactly as it would in production.
tail_instance = {
    "advertisement_id": w["adv"].record_id,
    "admission_decision_id": "approval/g11ag",
    "evidence": {"approving_authority": OPERATOR},
    "admitted_at": T1.isoformat(),
    "admitted_until": T3.isoformat(),
    "lifecycle_state": "admitted",
}
elig6 = E._advertised(w["store"], tail_instance, TAIL)
elig7 = E._admitted(tail_instance, TAIL)
check(elig6 is not None and elig6.status == E.UNMET
      and elig6.reason == "advertisement-not-fresh",
      "in the tail ELIG-6 refuses: the advertisement has lapsed")
check(elig7 is None,
      "in the tail ELIG-7 is met: the admission window is still open")
check(tail_instance["lifecycle_state"] == "admitted",
      "in the tail the binding is still lifecycle-admitted -- the R17 shape")

print("\n== C. the boundary ==\n")

w = world()
shorter = admission_of(w, admitted_until=INSIDE)
check(shorter.outcome == A.ACCEPTED,
      "an admission ending before its advertisement's validity is accepted")

w = world()
equal = admission_of(w, admitted_until=T2)
check(equal.outcome == A.ACCEPTED,
      "an admission ending exactly at valid_until is accepted -- both windows "
      "are half-open, so this is coincidence and not overhang")

w = world()
over_by_one = admission_of(w, admitted_until=T2 + timedelta(microseconds=1))
check(over_by_one.outcome == A.REFUSED and over_by_one.reason == BOUND,
      "one microsecond past valid_until is refused: the bound is not a tolerance")

# 4. admitted_at == valid_until. The existing freshness rule decides, because
#    evaluated_at is then outside the half-open claim window. Unchanged.
w = world()
at_edge = admission_of(w, admitted_at=T2, evaluated_at=T2, admitted_until=T3)
check(at_edge.outcome == A.REFUSED and at_edge.reason == "advertisement-not-fresh",
      "admitted_at == valid_until is still decided by freshness, not by the bound")

# 5. Malformed timestamps keep their existing refusal.
w = world()
malformed = admission_of(w, admitted_until="not-an-instant")
check(malformed.outcome == A.INVALID
      and malformed.reason == "timestamp-carries-no-offset",
      "a malformed admitted_until keeps the existing instant refusal")

w = world()
naive = admission_of(w, admitted_until=T2.replace(tzinfo=None))
check(naive.outcome == A.INVALID
      and naive.reason == "timestamp-carries-no-offset",
      "an offset-free admitted_until keeps the existing refusal")

# 9. A null dependency window. Derived, not assumed: the schema requires
#    admitted_until, and the human preflight refuses its absence before the
#    bound is ever reached.
w = world()
absent = admission_of(w, admitted_until=None)
check(absent.outcome == A.INVALID and absent.reason != BOUND,
      "an absent admitted_until is refused by the existing schema rule, not by "
      f"the bound (outcome={absent.outcome}, reason={absent.reason!r})")

# 6. An advertisement already stale at evaluated_at. Freshness still decides,
#    and it is reported before the bound.
w = world()
stale = admission_of(w, evaluated_at=TAIL, admitted_at=TAIL, admitted_until=T3)
check(stale.outcome == A.REFUSED and stale.reason == "advertisement-not-fresh",
      "an already-stale advertisement is still reported as not fresh")

# 8. A missing advertisement keeps its existing refusal.
w = world()
missing = admission_of(w, advertisement_id="CADV-000999", admitted_until=T3)
check(missing.outcome == A.NOT_FOUND and missing.reason == "unresolved-reference",
      "an unresolvable advertisement is still reported as unresolved")

print("\n== D/E. the check is one comparison in the existing clock block ==\n")

source = Path("tools/fabric/admission.py").read_text(encoding="utf-8")
check(source.count(f'"{BOUND}"') == 1,
      "the reason string is declared exactly once")
check("REASON_ADMISSION_UNBOUNDED" in source,
      "the reason is a named constant, not a literal at the comparison")
check(source.count("if admitted_until > expires:") == 1,
      "the bound is one comparison against the already-parsed valid_until")
check("_stored_instant(advertisement.get(\"valid_until\"))" in source,
      "no second timestamp parser was introduced")

print("\n== F. preflight and write share the rule ==\n")

# Refusal, rehearsed.
w = world()
before = w["store"].peek_next_id("capability-instance")
with rehearsing():
    rehearsed = admission_of(w, admitted_until=T3)
check(rehearsed.outcome == A.REFUSED and rehearsed.reason == BOUND,
      "preflight refuses the overlong admission with the same reason as the write")
check(w["store"].peek_next_id("capability-instance") == before,
      "the refused preflight left the instance sequence untouched")

# Acceptance, rehearsed then written, with the same body.
w = world()
with rehearsing():
    predicted = admission_of(w, admitted_until=T2)
check(predicted.outcome == A.PREFLIGHT,
      "a dependency-bounded preflight would accept")
check(predicted.record_id is None,
      "the rehearsal mints no identity -- nothing is allocated to report")
check(w["store"].peek_next_id("capability-instance") == "CINST-000001",
      "the accepted preflight allocated nothing, and the next identity still stands")
written = admission_of(w, admitted_until=T2)
check(written.outcome == A.ACCEPTED and written.record_id == "CINST-000001",
      "the real write accepts and lands on the identity the preflight left standing")
check(written.request_digest == predicted.request_digest,
      "preflight and write compute the same request digest")

print("\n== G. supersession is unchanged ==\n")

# The shape CINST-000003 will have: a renewed advertisement, a superseding
# instance, bounded by the new claim.
w = world()
first = admission_of(w, admitted_until=T2)
check(first.outcome == A.ACCEPTED, "the predecessor binding is admitted")

adv2 = register_advertisement(
    w["store"], request_id="g11ag-adv-2", actor=w["host"].record_id, recorded_at=T2,
    capability_host_id=w["host"].record_id,
    capability_package_id=w["pkg"].record_id, contract_id=w["con"].record_id,
    satisfied_contract_versions=("1.0.0",),
    advertised_resource_profile={"architecture": "x86-64"},
    observed_at=T2, valid_until=T3, supersedes=w["adv"].record_id, provenance=PROV)
check(adv2.outcome == A.ACCEPTED, "the renewed advertisement is registered")

successor = admission_of(
    w, request_id="g11ag-inst-2", recorded_at=T2, evaluated_at=T2,
    admitted_at=T2, admitted_until=T3, advertisement_id=adv2.record_id,
    supersedes=first.record_id)
check(successor.outcome == A.ACCEPTED,
      "a superseding admission bounded by its NEW advertisement is accepted")
check(successor.record_id != first.record_id,
      "the supersession created a new binding root, not an edit")

predecessor = w["store"].read_record("capability-instance", first.record_id)
check(predecessor.get("supersedes") is None
      and predecessor.get("lifecycle_state") == "admitted",
      "the predecessor record was not mutated by the supersession")

# And a superseding admission that overshoots its new claim is still refused.
w = world()
first = admission_of(w, admitted_until=T2)
adv2 = register_advertisement(
    w["store"], request_id="g11ag-adv-2", actor=w["host"].record_id, recorded_at=T2,
    capability_host_id=w["host"].record_id,
    capability_package_id=w["pkg"].record_id, contract_id=w["con"].record_id,
    satisfied_contract_versions=("1.0.0",),
    advertised_resource_profile={"architecture": "x86-64"},
    observed_at=T2, valid_until=T3, supersedes=w["adv"].record_id, provenance=PROV)
overshoot = admission_of(
    w, request_id="g11ag-inst-2", recorded_at=T2, evaluated_at=T2,
    admitted_at=T2, admitted_until=T3 + timedelta(days=1),
    advertisement_id=adv2.record_id, supersedes=first.record_id)
check(overshoot.outcome == A.REFUSED and overshoot.reason == BOUND,
      "a superseding admission is bounded by its own advertisement, not the old one")

# 7. A superseded advertisement is still reported as superseded, before the
#    bound, because that is the actionable fact (G11-H).
w = world()
adv2 = register_advertisement(
    w["store"], request_id="g11ag-adv-2", actor=w["host"].record_id, recorded_at=T2,
    capability_host_id=w["host"].record_id,
    capability_package_id=w["pkg"].record_id, contract_id=w["con"].record_id,
    satisfied_contract_versions=("1.0.0",),
    advertised_resource_profile={"architecture": "x86-64"},
    observed_at=T2, valid_until=T3, supersedes=w["adv"].record_id, provenance=PROV)
superseded = admission_of(w, admitted_until=T3)
check(superseded.outcome == A.REFUSED
      and superseded.reason == "advertisement-record-superseded",
      "a superseded advertisement is still reported as superseded, not as unbounded")

print("\n== H. history is not rewritten ==\n")

# The historical shape would be refused if resubmitted, and that is all this
# change does to it. Nothing migrates or backfills.
check(overlong.outcome == A.REFUSED,
      "the CINST-000001 shape would be refused if submitted today")
check("migrat" not in source.lower().split("def admit_instance")[1][:4000],
      "admit_instance carries no migration or backfill path")

print("\n== I. G11-Y invoke eligibility is untouched ==\n")

# A properly bounded binding still becomes ineligible when its advertisement
# lapses, so the write-time bound removes no runtime obligation.
w = world()
bounded = admission_of(w, admitted_until=T2)
record = w["store"].read_record("capability-instance", bounded.record_id)
after_expiry = T2 + timedelta(seconds=1)
check(E._advertised(w["store"], record, after_expiry).reason == "advertisement-not-fresh",
      "ELIG-6 still refuses a bounded binding once its advertisement lapses")
check(E._admitted(record, after_expiry).reason == "admission-window-expired",
      "ELIG-7 still refuses it too -- the windows now end together")
check(E._admitted(record, T0) is None,
      "and inside the window ELIG-7 is met, so nothing was over-tightened")

eligibility_source = Path("tools/fabric/eligibility.py").read_text(encoding="utf-8")
for condition in ("ELIG-6", "ELIG-7", "ELIG-10", "ELIG-11"):
    check(f'"{condition}"' in eligibility_source,
          f"{condition} is still evaluated at invoke")
check(BOUND not in eligibility_source,
      "the write-time bound was not copied into runtime eligibility")

print(f"\n{failures} assertion(s) failed." if failures
      else "\nAll G11-AG admission dependency bound assertions passed.")
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
