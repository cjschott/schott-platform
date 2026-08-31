#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-Y. Invoke-time revalidation of current Fabric eligibility.
#
# A `CSEL` is a historical decision. G11-W proved the invocation bridge
# rechecked lifecycle, supersession, and the admission window, but never read
# the advertisement — so a binding whose admission outlives its advertisement
# stayed invocable through that tail while the Fabric's own engine had already
# ruled it ineligible on ELIG-6. Two components disagreeing about whether a
# binding may serve is the defect; this suite pins them into agreement.
#
# The bridge asks the released engine rather than re-deriving twelve
# conditions, so anything the Fabric later counts as eligibility — trust
# standing, quarantine, availability — is followed here without a second
# implementation to keep in step.
#
# A route-head change is deliberately NOT an invoke refusal: the question at
# invoke is whether the selected binding is still eligible, not whether the
# routing plane would choose it again.
#
# Every fixture is built through released governance operations in a temporary
# directory. Nothing here reads or writes a production path, stages a package,
# allocates a CINV, authorises a launch, or reaches an adapter.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
BEFORE="$(mktemp)"
AFTER="$(mktemp)"
trap 'rm -f "${BEFORE}" "${AFTER}"' EXIT
if [[ -d "${PRODUCTION_FABRIC}" ]]; then
  ( cd "${PRODUCTION_FABRIC}" && find . -mindepth 1 -printf '%y %m %s %p\n' | sort ) > "${BEFORE}"
fi

python3 - <<'PYTHON'
import os, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

import yaml

from tools.capability.fabric_evidence import verify_selected_evidence
from tools.fabric import admission as A
from tools.fabric import eligibility as E
from tools.fabric.admission import (
    admit_instance, admit_subject, create_route, declare_capability,
    declare_contract, declare_package, refresh_subject, register_advertisement)
from tools.fabric.selection import select_candidate
from tools.fabric.store import FabricStore
from tools.trust.evaluator import create_decision
from tools.trust.models import (
    TrustEvidenceReference, TrustScope, TrustVerificationDetails, VerificationMethod)
from tools.trust.root_authority import declare_root_authority, load_root_declaration
from tools.trust.store import TrustStore

UID, GID = os.geteuid(), os.getegid()
Z = timezone(timedelta(hours=-5))
BASE = datetime(2026, 8, 1, 9, 0, 0, tzinfo=Z)
YEAR = BASE + timedelta(days=365)
OP = "primary-platform-operator"
NODE = "HOST-0001"
PROV = {"class": "declared",
        "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md"}
PROFILE = {"architecture": "x86-64"}
RS = {"authority": "tools/x/p.py", "schema": "s", "schema_version": 1}
PS = {"envelope": {"authority": "tools/x/e.py", "schema": "e", "schema_version": 1},
      "content": {"authority": "tools/x/c.py", "schema": "c", "schema_version": 1}}
SCOPE = {"permitted_capabilities": ("CAPDEF-0001",),
         "permitted_operations": ("execute",),
         "permitted_data_classifications": ("internal",),
         "permitted_targets": (NODE,)}

FAILURES = []


def check(condition, label):
    print(("PASS: " if condition else "FAIL: ") + label)
    if not condition:
        FAILURES.append(label)


def world(tmp, *, advert_hours=48, admit_hours=48):
    """One governed world, built through released operations.

    `advert_hours` and `admit_hours` are separate on purpose: an admission that
    outlives its advertisement is exactly the R17 tail this suite exists to
    refuse at invoke, and the fixture has to be able to produce one.

    Since G11-AG the write path no longer PERMITS one -- `admit_instance`
    refuses `admitted_until > advertisement.valid_until` with
    `admission-window-exceeds-advertisement`. So when the two differ, the
    binding is admitted bounded and its stored `admitted_until` is then
    extended directly, reproducing the record CINST-000001 already is rather
    than minting one through a path that now correctly refuses.

    That is a change of fixture construction, not of coverage. What this suite
    asserts is a RUNTIME property -- that invoke re-evaluates and refuses a
    binding whose advertisement has lapsed -- and historical records of exactly
    this shape still exist, so it must keep holding.
    """
    root = Path(tmp)
    store = FabricStore(root / "fabric", expected_uid=UID, expected_gid=GID)
    trust = TrustStore(root / "trust")
    approved = root / "approved"
    approved.mkdir()
    approved.joinpath("root.yaml").write_text(yaml.safe_dump({
        "display_name": "Operator Root Authority",
        "external_identity_reference": "secret-source://approved/operator-root",
        "verification_method": VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        "verification_details": {
            "subject_property": "operator-root-identity",
            "observed_value_reference": "/approved/evidence/root-observed.txt",
            "comparison_source": "in-person-verification-record",
            "performed_by": "operator-role-reference",
            "performed_at": BASE.isoformat()},
        "evidence_references": [{"evidence_id": "TEVID-000001",
                                 "kind": "attestation",
                                 "reference": "/approved/evidence/root.txt",
                                 "recorded_at": BASE.isoformat()}],
        "created_at": BASE.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"}}))
    authority = declare_root_authority(trust, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    def decide(subject, subject_type, state, at=BASE, revokes=None):
        return create_decision(
            trust, subject_id=subject, subject_type=subject_type,
            requested_state=state, actor_authority_id=authority.authority_id,
            decided_at=at, reason="Decided for the G11-Y eligibility fixture.",
            evidence_references=(TrustEvidenceReference(
                evidence_id=trust.peek_next_id("evidence"), kind="fingerprint",
                reference="/approved/evidence/fingerprint.txt", recorded_at=at),),
            verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
            verification_details=TrustVerificationDetails(
                subject_property="ssh-host-key-fingerprint",
                observed_value_reference="/approved/evidence/observed.txt",
                comparison_source="printed-console-readout",
                performed_by="operator-role-reference", performed_at=at),
            revokes_record_id=revokes,
            scope=TrustScope(
                scope_id=trust.allocate_id("scope"), subject_type=subject_type,
                validity_start=BASE, validity_end=YEAR, **SCOPE))

    host_grant = decide(NODE, "fabric-node", "trusted")
    package_grant = decide("CPKG-0001", "capability-package", "trusted")

    cap = declare_capability(
        store, request_id="g11y-cap", actor=OP, approving_authority=OP,
        recorded_at=BASE, name="kyri-execution-boundary-verification",
        description="Boundary probe.", effect_class="computational",
        contract_ids=(), provenance=PROV)
    con = declare_contract(
        store, request_id="g11y-con", actor=OP, approving_authority=OP,
        recorded_at=BASE, capability_id=cap.record_id, contract_version="1.0.0",
        effect_class="computational", determinism_class="deterministic",
        request_shape=RS, response_shape=PS, failure_modes=("adapter-error",),
        resource_requirements={}, compatible_with=(), provenance=PROV)
    pkg = declare_package(
        store, request_id="g11y-pkg", actor=OP, approving_authority=OP,
        recorded_at=BASE, capability_id=cap.record_id, contract_id=con.record_id,
        satisfied_contract_versions=("1.0.0",), package_version="1.0.0",
        artifact_reference="tree:kyri-execution-boundary-verification/1.0.0",
        resource_requirements={}, trust_domain="capability-package",
        provenance=PROV)
    host = admit_subject(
        store, trust, request_id="g11y-host", actor=OP, approving_authority=OP,
        recorded_at=BASE, evaluated_at=BASE, node_identity_reference=NODE,
        fabric_node_trust_record_id=host_grant.record.record_id,
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=PROV)

    observed = BASE + timedelta(hours=1)
    advert = register_advertisement(
        store, request_id="g11y-adv", actor=host.record_id, recorded_at=observed,
        capability_host_id=host.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile=dict(PROFILE), observed_at=observed,
        valid_until=observed + timedelta(hours=advert_hours), provenance=PROV)

    admitted = observed + timedelta(hours=2)
    instance = admit_instance(
        store, trust, request_id="g11y-inst", actor=OP, approving_authority=OP,
        recorded_at=admitted, evaluated_at=admitted, capability_id=cap.record_id,
        capability_package_id=pkg.record_id, capability_host_id=host.record_id,
        contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
        verified_resource_profile=dict(PROFILE),
        admission_decision_id="eng-0005-g11y",
        package_trust_record_id=package_grant.record.record_id,
        host_trust_record_id=host_grant.record.record_id,
        advertisement_id=advert.record_id, admission_scope=dict(SCOPE),
        admitted_at=admitted,
        admitted_until=observed + timedelta(hours=min(admit_hours, advert_hours)),
        provenance=PROV)
    for result in (cap, con, pkg, host, advert, instance):
        assert result.outcome == A.ACCEPTED, (result.record_id, result.reason)

    if admit_hours > advert_hours:
        # The historical shape, reproduced rather than minted -- see the
        # docstring. Only `admitted_until` moves; every other field is exactly
        # what the released admission wrote.
        # Written with plain file IO on purpose: the store refuses to rewrite a
        # record, which is correct and is not being tested around. The fixture
        # is standing in a historical artefact, not performing an operation.
        path = store.path_for("capability-instance", instance.record_id)
        record = yaml.safe_load(path.read_text(encoding="utf-8"))
        record["admitted_until"] = (
            observed + timedelta(hours=admit_hours)).isoformat()
        mode = path.stat().st_mode & 0o7777
        path.chmod(0o600)
        path.write_text(yaml.safe_dump(record, sort_keys=True), encoding="utf-8")
        path.chmod(mode)

    routed = admitted + timedelta(minutes=5)
    route = create_route(
        store, request_id="g11y-route", actor=OP, approving_authority=OP,
        recorded_at=routed, capability_id=cap.record_id, contract_id=con.record_id,
        accepted_contract_versions=("1.0.0",), locality="local-only",
        candidate_instances=(instance.record_id,), data_classification="internal",
        route_version=1, provenance=PROV)
    assert route.outcome == A.ACCEPTED, route.reason

    chosen = routed + timedelta(minutes=5)
    selection = select_candidate(
        store, trust, request_id="g11y-select", actor=OP, recorded_at=chosen,
        evaluated_at=chosen, capability_id=cap.record_id,
        contract_id=con.record_id, accepted_contract_versions=("1.0.0",),
        data_classification="internal", locality="local-only", provenance=PROV,
        local_node_identity=NODE)
    assert selection.outcome == A.ACCEPTED, (selection.outcome, selection.reason)
    assert selection.selected_instance_id == instance.record_id

    return {"root": root, "fabric": root / "fabric", "trust": root / "trust",
            "store": store, "trust_store": trust, "authority": authority,
            "decide": decide, "instance": instance.record_id,
            "package": pkg.record_id, "selection": selection.record_id,
            "host_grant": host_grant.record.record_id,
            "package_grant": package_grant.record.record_id,
            "advert_expires": observed + timedelta(hours=advert_hours),
            "admit_expires": observed + timedelta(hours=admit_hours),
            "admitted_at": admitted, "capability": cap.record_id,
            "contract": con.record_id, "host": host.record_id, "routed": routed}


def verify(w, *, at, operation="execute", **overrides):
    asked = dict(selection_id=w["selection"], instance_id=w["instance"],
                 capability_package_id=w["package"], operation=operation,
                 trust_root=str(w["trust"]), evaluated_at=at)
    asked.update(overrides)
    return verify_selected_evidence(str(w["fabric"]), expected_uid=UID,
                                    expected_gid=GID, **asked)


def fabric_says(w, at):
    """What the Fabric's own engine concludes at the same instant."""
    return E.evaluate_eligibility(
        w["store"], w["trust_store"], instance_id=w["instance"],
        request={"capability_id": w["capability"], "contract_id": w["contract"],
                 "accepted_contract_versions": ("1.0.0",),
                 "data_classification": "internal"},
        evaluated_at=at)


def inventory(base):
    entries = {}
    for path in sorted(Path(base).rglob("*")):
        entries[str(path.relative_to(base))] = (
            path.lstat().st_mode,
            path.read_bytes() if path.is_file() else b"")
    return entries


print("=" * 74)
print("PART 1 — the bridge asks for current eligibility, through a trust root")
print("=" * 74)

import inspect
signature = inspect.signature(verify_selected_evidence)
check("trust_root" in signature.parameters,
      "verify_selected_evidence takes a trust root")
if "trust_root" in signature.parameters:
    check(signature.parameters["trust_root"].default is inspect.Parameter.empty,
          "the trust root has no default")

from tools.capability import coordinator as _coordinator
check("trust_root" in inspect.signature(_coordinator.prepare_invocation).parameters,
      "prepare_invocation takes a trust root")

import tools.capability.fabric_evidence as _bridge
source = inspect.getsource(_bridge)
# Named, not merely mentioned: a docstring that talks about eligibility is not
# a call to the engine that decides it.
check("evaluate_eligibility" in source,
      "the bridge calls the released evaluate_eligibility rather than "
      "re-deriving the conditions")
for condition in ("ELIG-1", "ELIG-7", "ELIG-12"):
    check(condition not in source,
          f"the bridge does not restate {condition} itself")

print()
print("=" * 74)
print("PART 2 — the current production shape is supported")
print("=" * 74)

with TemporaryDirectory() as tmp:
    w = world(tmp)
    at = w["admitted_at"] + timedelta(hours=1)
    before = inventory(w["fabric"])
    verdict = verify(w, at=at)
    check(fabric_says(w, at).eligible, "the Fabric calls the binding eligible")
    check(verdict.supported,
          f"the bridge supports a currently eligible binding ({verdict.reason})")
    check(verdict.reason is None, "a supported verdict names no refusal")
    check(inventory(w["fabric"]) == before, "verification wrote nothing")

print()
print("=" * 74)
print("PART 3 — the R17 tail: Fabric and invoke must agree")
print("=" * 74)

with TemporaryDirectory() as tmp:
    # Advertisement lapses at T1, admission runs to T2 > T1. The selection was
    # taken while both were live.
    w = world(tmp, advert_hours=6, admit_hours=48)
    tail = w["advert_expires"] + timedelta(hours=1)
    check(tail < w["admit_expires"],
          "the fixture really has a tail: the instant is inside the admission "
          "window and past the advertisement")
    fabric = fabric_says(w, tail)
    check(not fabric.eligible and "ELIG-6" in fabric.unmet,
          f"the Fabric refuses on ELIG-6 in the tail (unmet={list(fabric.unmet)})")
    verdict = verify(w, at=tail)
    check(not verdict.supported,
          f"the bridge refuses in the tail too ({verdict.reason})")
    check(verdict.reason == "selected-instance-no-longer-eligible",
          f"the refusal names current ineligibility (got {verdict.reason})")
    check("advertisement-not-fresh" in (verdict.eligibility_reasons or ()),
          f"the underlying Fabric reason is carried for audit "
          f"({verdict.eligibility_reasons})")

    # Before the advertisement lapses, the same binding is still fine.
    early = w["admitted_at"] + timedelta(minutes=30)
    check(fabric_says(w, early).eligible and verify(w, at=early).supported,
          "before the tail opens, both agree the binding is eligible")

print()
print("=" * 74)
print("PART 4 — dynamic authority the bridge now follows")
print("=" * 74)

with TemporaryDirectory() as tmp:
    w = world(tmp)
    at = w["admit_expires"] + timedelta(hours=1)
    fabric, verdict = fabric_says(w, at), verify(w, at=at)
    check(not fabric.eligible, "the admission window has closed: the Fabric refuses")
    check(not verdict.supported and verdict.reason == "admission-window-not-open",
          f"the admission window has closed: the bridge refuses ({verdict.reason})")

with TemporaryDirectory() as tmp:
    w = world(tmp)
    drained = refresh_subject(
        w["store"], w["trust_store"], request_id="g11y-drain", actor=OP,
        approving_authority=OP, recorded_at=w["routed"], evaluated_at=w["routed"],
        capability_host_id=w["host"], fabric_node_trust_record_id=w["host_grant"],
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="draining", provenance=PROV)
    check(drained.outcome == A.ACCEPTED,
          f"the host is drained through the released operation ({drained.reason})")
    at = w["admitted_at"] + timedelta(hours=1)
    fabric, verdict = fabric_says(w, at), verify(w, at=at)
    check(not fabric.eligible,
          f"the drained host is ineligible to the Fabric (unmet={list(fabric.unmet)})")
    check(not verdict.supported and verdict.reason == "selected-instance-no-longer-eligible",
          f"the drained host refuses at the bridge ({verdict.reason})")

for subject, subject_type, grant_key, label in (
        (NODE, "fabric-node", "host_grant", "host"),
        ("CPKG-0001", "capability-package", "package_grant", "package")):
    for state in ("revoked", "quarantined"):
        with TemporaryDirectory() as tmp:
            w = world(tmp)
            at = w["admitted_at"] + timedelta(hours=1)
            w["decide"](subject, subject_type, state, at=w["routed"],
                        revokes=w[grant_key] if state == "revoked" else None)
            fabric, verdict = fabric_says(w, at), verify(w, at=at)
            check(not fabric.eligible,
                  f"the {label} standing is {state}: the Fabric refuses "
                  f"(unmet={list(fabric.unmet)})")
            check(not verdict.supported
                  and verdict.reason == "selected-instance-no-longer-eligible",
                  f"the {label} standing is {state}: the bridge refuses "
                  f"({verdict.reason})")
            check(verdict.eligibility_reasons,
                  f"the {label} {state} refusal carries the Fabric reason "
                  f"({verdict.eligibility_reasons})")

print()
print("=" * 74)
print("PART 4B — the read-only adapters answer exactly as the real stores do")
print("=" * 74)

# The bridge hands C5 two objects that expose reads and nothing else. That is
# only safe if it changes no answer: a narrowed surface that quietly degraded a
# precise verdict into "unreadable" would refuse for the wrong reason and hide
# the real one.
from tools.capability.fabric_evidence import _FabricReader, _TrustReader

def both_ways(w, at):
    request = {"capability_id": w["capability"], "contract_id": w["contract"],
               "accepted_contract_versions": ("1.0.0",),
               "data_classification": "internal"}
    direct = E.evaluate_eligibility(w["store"], w["trust_store"],
                                    instance_id=w["instance"], request=request,
                                    evaluated_at=at)
    adapted = E.evaluate_eligibility(
        _FabricReader(str(w["fabric"]), UID, GID),
        _TrustReader(TrustStore.open_for_read(str(w["trust"]))),
        instance_id=w["instance"], request=request, evaluated_at=at)
    return direct, adapted

for label, revoke in (("a healthy world", False), ("a revoked host", True)):
    with TemporaryDirectory() as tmp:
        w = world(tmp)
        if revoke:
            w["decide"](NODE, "fabric-node", "revoked", at=w["routed"],
                        revokes=w["host_grant"])
        at = w["admitted_at"] + timedelta(hours=1)
        direct, adapted = both_ways(w, at)
        check(direct.eligible == adapted.eligible
              and tuple(direct.unmet) == tuple(adapted.unmet)
              and tuple(direct.reasons) == tuple(adapted.reasons),
              f"{label}: the adapters and the real stores agree exactly "
              f"(direct={direct.eligible}/{list(direct.unmet)} "
              f"adapted={adapted.eligible}/{list(adapted.unmet)})")

for surface, banned in ((_FabricReader, ("write", "allocate_id",
                                         "request_critical_section")),
                        (_TrustReader, ("write", "allocate_id"))):
    for name in banned:
        check(not hasattr(surface, name),
              f"{surface.__name__} exposes no {name}")

print()
print("=" * 74)
print("PART 5 — a route-head change alone is not an invoke refusal")
print("=" * 74)

with TemporaryDirectory() as tmp:
    w = world(tmp)
    at = w["admitted_at"] + timedelta(hours=2)
    # A second binding is admitted and the route moves to it. The historical
    # selection still names the first, which is still perfectly eligible.
    second = admit_instance(
        w["store"], w["trust_store"], request_id="g11y-inst-2", actor=OP,
        approving_authority=OP, recorded_at=w["routed"], evaluated_at=w["routed"],
        capability_id=w["capability"], capability_package_id=w["package"],
        capability_host_id=w["host"], contract_id=w["contract"],
        satisfied_contract_versions=("1.0.0",),
        verified_resource_profile=dict(PROFILE),
        admission_decision_id="eng-0005-g11y-second",
        package_trust_record_id="TREC-000002", host_trust_record_id="TREC-000001",
        advertisement_id="CADV-000001", admission_scope=dict(SCOPE),
        admitted_at=w["routed"], admitted_until=w["admit_expires"],
        provenance=PROV)
    check(second.outcome == A.ACCEPTED,
          f"a second binding is admitted ({second.outcome}/{second.reason})")
    moved = create_route(
        w["store"], request_id="g11y-route-2", actor=OP, approving_authority=OP,
        recorded_at=w["routed"] + timedelta(minutes=1),
        capability_id=w["capability"], contract_id=w["contract"],
        accepted_contract_versions=("1.0.0",), locality="local-only",
        candidate_instances=(second.record_id,), data_classification="internal",
        route_version=2, provenance=PROV, supersedes="CROUTE-0001")
    check(moved.outcome == A.ACCEPTED,
          f"the route moves to the second binding ({moved.reason})")

    verdict = verify(w, at=at)
    check(verdict.supported,
          f"the historical selection still verifies after the route moved "
          f"({verdict.reason})")
    check(fabric_says(w, at).eligible,
          "and the Fabric still calls the originally selected binding eligible")

print()
print("=" * 74)
print("PART 6 — the G11-X operation and scope authority is unchanged")
print("=" * 74)

with TemporaryDirectory() as tmp:
    w = world(tmp)
    at = w["admitted_at"] + timedelta(hours=1)
    verdict = verify(w, at=at, operation="delete")
    check(not verdict.supported
          and verdict.reason == "operation-not-permitted-by-scope",
          f"an unpermitted operation still refuses for its own reason "
          f"(got {verdict.reason})")
    verdict = verify(w, at=at, operation=None)
    check(not verdict.supported and verdict.reason == "operation-not-supplied",
          f"an absent operation still refuses for its own reason "
          f"(got {verdict.reason})")
    verdict = verify(w, at=at, instance_id="CINST-000009")
    check(not verdict.supported
          and verdict.reason == "claimed-instance-not-selected",
          f"a claimed instance the selection did not choose still refuses "
          f"(got {verdict.reason})")

print()
if FAILURES:
    print(f"FAILURES: {len(FAILURES)}")
    for item in FAILURES:
        print(f"  - {item}")
    sys.exit(1)
print("Invoke current-eligibility validation passed.")
PYTHON
status=$?

if [[ -d "${PRODUCTION_FABRIC}" ]]; then
  ( cd "${PRODUCTION_FABRIC}" && find . -mindepth 1 -printf '%y %m %s %p\n' | sort ) > "${AFTER}"
  if diff -q "${BEFORE}" "${AFTER}" >/dev/null; then
    printf 'PASS: %s\n' "no production path changed while this suite ran"
  else
    printf 'FAIL: %s\n' "a production path changed while this suite ran" >&2
    status=1
  fi
fi

exit "${status}"
