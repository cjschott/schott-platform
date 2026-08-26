#!/usr/bin/env bash
set -Eeuo pipefail

# G11-A: instance admission integrity and governed advertisement supersession.
#
# THREE CORRECTIONS, ALL THE SAME SHAPE: something the runtime already relies
# on was not stated where it could be enforced.
#
# A1. `CapabilityInstance.advertisement_id` was modelled optional while
#     `admit_instance` passed it through `_identifier`, which refuses `None`.
#     So the runtime already required it and the model said otherwise. A model
#     that is not authoritative about what a valid record is cannot refuse a
#     record nobody admitted -- a hand-built or legacy instance with no
#     advertisement was constructible, storable, and reloadable, and every
#     eligibility answer about it would have been derived from a claim that was
#     never named.
#
# A2. `_effective_scope` intersects `permitted_targets` and refuses an empty
#     result, but `admit_instance` never asked whether the machine it was
#     admitting was IN that set. With one host the two are indistinguishable.
#     With two they are not, and a `CapabilityInstance` is immutable.
#
# A3. Advertisements are immutable and supersede by new record only, but no
#     released operation could set `supersedes`, so a renewal was an unlinked
#     new record and nothing could say which claim was current.
#
# WHAT THE CHAIN IS READ FROM. Nothing points forward. `superseded_by` is
# never written by any released operation for any record kind, and the head is
# derived by reverse lookup over `supersedes` -- the doctrine `_successors`
# states and that hosts and instances already follow. These cases pin that for
# advertisements too, rather than introducing a mutable backlink into an
# append-only record.
#
# FIXTURE ONLY. Every case works in a temporary root. Nothing here touches
# /var/lib/kyri, and the suite proves it did not.
#
# Governed by:
#   platform-model/schemas/capability-instance.schema.yaml
#   platform-model/schemas/capability-advertisement.schema.yaml
#   docs/decisions/ADR-0012-distributed-capability-fabric.md

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
from dataclasses import fields as dataclass_fields
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

from tools.common.yaml_strict import load_strict
from tools.fabric import admission as A
from tools.fabric.admission import (
    admit_instance, declare_capability, declare_contract, declare_package,
    admit_subject, register_advertisement,
)
from tools.fabric.errors import FabricError
from tools.fabric.models import RECORD_MODELS
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
OPERATOR = "operator:g11"
PROV = {"class": "declared", "source": "g11-a"}
NODE = "HOST-0001"
OTHER_NODE = "HOST-0002"
PROFILE = {"architecture": "x86-64", "host_memory_mb": 8192}

REQUEST_SHAPE = {"authority": "tools/x/payload.py", "schema": "s", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/x/env.py", "schema": "e", "schema_version": 1},
    "content": {"authority": "tools/x/con.py", "schema": "c", "schema_version": 1},
}


# --- one throwaway world -----------------------------------------------------

def seeded_trust(root, node=NODE, targets=(NODE,)):
    """A trust store with a root authority and two granted standings.

    Built through the released declaration and decision paths, exactly as the
    fabric runtime suite does, so the fixture cannot drift from what the
    platform actually writes.
    """
    store = TrustStore(Path(root) / "trust")
    approved = Path(root) / "approved"
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

    def grant(subject, subject_type, permitted_targets):
        return create_decision(
            store, subject_id=subject, subject_type=subject_type,
            requested_state="trusted", actor_authority_id=authority.authority_id,
            decided_at=STAMP, reason="Granted for the G11-A fixture world.",
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
                permitted_targets=tuple(permitted_targets),
                validity_start=STAMP, validity_end=YEAR))

    host_grant = grant(node, "fabric-node", targets)
    package_grant = grant("CPKG-0001", "capability-package", targets)
    return store, host_grant, package_grant


def world(node=NODE, targets=(NODE,)):
    tmp = Path(tempfile.mkdtemp())
    store = FabricStore(tmp / "fabric", expected_uid=UID, expected_gid=GID)
    trust, host_grant, package_grant = seeded_trust(tmp, node, targets)
    cap = declare_capability(
        store, request_id="g11-cap", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, name="boundary probe", description="A probe.",
        effect_class="computational", contract_ids=(), provenance=PROV)
    con = declare_contract(
        store, request_id="g11-con", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, capability_id=cap.record_id, contract_version="1.0.0",
        effect_class="computational", determinism_class="deterministic",
        request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
        failure_modes=("adapter-error",), resource_requirements={},
        compatible_with=(), provenance=PROV)
    pkg = declare_package(
        store, request_id="g11-pkg", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, capability_id=cap.record_id, contract_id=con.record_id,
        satisfied_contract_versions=("1.0.0",), package_version="1.0.0",
        artifact_reference="tree:probe/1.0.0", resource_requirements={},
        trust_domain="capability-package", provenance=PROV)
    host = admit_subject(
        store, trust, request_id="g11-host", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP, evaluated_at=STAMP,
        node_identity_reference=node,
        fabric_node_trust_record_id=host_grant.record.record_id,
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=PROV)
    adv = register_advertisement(
        store, request_id="g11-adv", actor=host.record_id, recorded_at=STAMP,
        capability_host_id=host.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile={"architecture": "x86-64"},
        observed_at=STAMP, valid_until=LATER, provenance=PROV)
    return dict(tmp=tmp, store=store, trust=trust, cap=cap, con=con, pkg=pkg,
                host=host, adv=adv, host_grant=host_grant,
                package_grant=package_grant)


def admission(w, **overrides):
    fields = dict(
        request_id="g11-inst", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, evaluated_at=STAMP,
        capability_id=w["cap"].record_id,
        capability_package_id=w["pkg"].record_id,
        capability_host_id=w["host"].record_id,
        contract_id=w["con"].record_id,
        satisfied_contract_versions=("1.0.0",),
        verified_resource_profile=dict(PROFILE),
        admission_decision_id="approval/g11",
        package_trust_record_id=w["package_grant"].record.record_id,
        host_trust_record_id=w["host_grant"].record.record_id,
        admission_scope={"permitted_capabilities": ["CAPDEF-0001"],
                         "permitted_operations": ["execute"],
                         "permitted_data_classifications": ["internal"],
                         "permitted_targets": [NODE]},
        admitted_at=STAMP, admitted_until=LATER, provenance=PROV,
        advertisement_id=w["adv"].record_id)
    fields.update(overrides)
    return admit_instance(w["store"], w["trust"], **fields)


def renewal(w, **overrides):
    fields = dict(
        request_id="g11-adv-2", actor=w["host"].record_id, recorded_at=LATER,
        capability_host_id=w["host"].record_id,
        capability_package_id=w["pkg"].record_id, contract_id=w["con"].record_id,
        satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile={"architecture": "x86-64"},
        observed_at=LATER, valid_until=LATER + timedelta(days=1),
        provenance=PROV, supersedes=w["adv"].record_id)
    fields.update(overrides)
    return register_advertisement(w["store"], **fields)


INSTANCE_SCHEMA = load_strict("platform-model/schemas/capability-instance.schema.yaml")
ADVERT_SCHEMA = load_strict("platform-model/schemas/capability-advertisement.schema.yaml")
Instance = RECORD_MODELS["capability-instance"]
Advertisement = RECORD_MODELS["capability-advertisement"]

INSTANCE_BODY = dict(
    instance_id="CINST-000001", capability_id="CAPDEF-0001",
    capability_package_id="CPKG-0001", capability_host_id="CHOST-0001",
    contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
    verified_resource_profile=dict(PROFILE),
    admission_decision_id="approval/g11",
    package_trust_record_id="TREC-000002", host_trust_record_id="TREC-000001",
    effective_scope={"permitted_targets": (NODE,)},
    admitted_at=STAMP, admitted_until=LATER, provenance=dict(PROV),
    lifecycle_state="admitted", advertisement_id="CADV-000001")


# ===========================================================================
# G11-A1 -- an instance is permanently bound to the advertisement that
#           admitted it
# ===========================================================================

print("\n--- G11-A1: advertisement_id is mandatory ---")

check("advertisement_id" in INSTANCE_SCHEMA["required_fields"],
      "the instance schema requires advertisement_id")
check("advertisement_id" not in (INSTANCE_SCHEMA.get("optional_fields") or ()),
      "the instance schema no longer lists advertisement_id as optional")

# The model is the authority on what a valid record is. A record nobody could
# have admitted must not be constructible.
for omitted, description in (
    ({}, "omitted entirely"),
    ({"advertisement_id": None}, "explicitly null"),
    ({"advertisement_id": ""}, "empty"),
    ({"advertisement_id": "CADV-1"}, "outside the CADV grammar"),
    ({"advertisement_id": "CHOST-0001"}, "an identifier of another kind"),
):
    body = dict(INSTANCE_BODY)
    if omitted:
        body.update(omitted)
    else:
        body.pop("advertisement_id")
    raised = None
    try:
        Instance(**body)
    except FabricError as error:
        raised = error
    except TypeError as error:      # a required field with no default
        raised = error
    check(raised is not None,
          f"an instance whose advertisement_id is {description} is refused")

good = Instance(**INSTANCE_BODY)
check(good.advertisement_id == "CADV-000001",
      "a valid instance carries the exact advertisement identity")

stored = good.to_dict()
check(stored.get("advertisement_id") == "CADV-000001",
      "the serialised instance names the advertisement")

# Serialise, drop the binding, and reload. A record that lost the advertisement
# on disk is refused rather than reconstructed with a hole in it.
carried = {name: stored[name] for name in
           (field.name for field in dataclass_fields(Instance))
           if name in stored}
carried["admitted_at"] = INSTANCE_BODY["admitted_at"]
carried["admitted_until"] = INSTANCE_BODY["admitted_until"]
check(Instance(**carried).advertisement_id == "CADV-000001",
      "the identity survives a round trip through the model")
carried.pop("advertisement_id")
reloaded = None
try:
    Instance(**carried)
except (FabricError, TypeError) as error:
    reloaded = error
check(reloaded is not None,
      "an instance reloaded without its advertisement is refused")
check("advertisement_id" in INSTANCE_SCHEMA["lifecycle_carried_fields"],
      "a lifecycle successor carries the advertisement identity forward")

with tempfile.TemporaryDirectory() as tmp:
    w = world()
    accepted = admission(w)
    check(accepted.outcome == "accepted",
          "an admission naming a resolvable advertisement is accepted")
    reread = w["store"].read_record("capability-instance", accepted.record_id)
    check(reread.get("advertisement_id") == w["adv"].record_id,
          "the durable instance names the advertisement actually evaluated")

    for value, description in (
        (None, "no advertisement at all"),
        ("CADV-999999", "an advertisement that does not resolve"),
        ("not-an-identifier", "a malformed advertisement identity"),
    ):
        w2 = world()
        before = w2["store"].counts().get("capability-instance", 0)
        result = admission(w2, advertisement_id=value, request_id="g11-inst-bad")
        check(result.record_id is None,
              f"an admission carrying {description} is refused")
        check(w2["store"].counts().get("capability-instance", 0) == before,
              f"an admission carrying {description} allocates nothing")


# ===========================================================================
# G11-A2 -- the machine being admitted must be a permitted target
# ===========================================================================

print("\n--- G11-A2: effective target binding ---")

w = world(node=NODE, targets=(NODE,))
accepted = admission(w, request_id="g11-target-ok")
check(accepted.outcome == "accepted",
      "a host whose node identity is a permitted target is admitted")
stored = w["store"].read_record("capability-instance", accepted.record_id)
check(NODE in tuple(stored["effective_scope"]["permitted_targets"]),
      "the composed scope names the admitted machine")

# The scope is non-empty and authorises a target -- just not this one. That is
# a different answer from an empty intersection and is reported as such.
w = world(node=OTHER_NODE, targets=(NODE,))
before_counts = w["store"].counts().get("capability-instance", 0)
before_seq = (w["tmp"] / "fabric" / "sequences" / "capability-instance.seq").exists()
refused = admission(
    w, request_id="g11-target-bad",
    admission_scope={"permitted_capabilities": ["CAPDEF-0001"],
                     "permitted_operations": ["execute"],
                     "permitted_data_classifications": ["internal"],
                     "permitted_targets": [NODE, OTHER_NODE]})
check(refused.record_id is None,
      "a host whose node identity is not a permitted target is refused")
check(refused.reason == A.REASON_TARGET_SCOPE,
      f"the refusal is named {A.REASON_TARGET_SCOPE}")
check(refused.reason != A.REASON_EMPTY_SCOPE,
      "an unauthorised target is not reported as an empty intersection")
check(w["store"].counts().get("capability-instance", 0) == before_counts,
      "an unauthorised target allocates no instance")
check((w["tmp"] / "fabric" / "sequences" / "capability-instance.seq").exists()
      == before_seq,
      "an unauthorised target advances no sequence")

# An intersection that is genuinely empty keeps its own distinct reason.
w = world(node=OTHER_NODE, targets=(NODE,))
empty = admission(
    w, request_id="g11-target-empty",
    admission_scope={"permitted_capabilities": ["CAPDEF-0001"],
                     "permitted_operations": ["execute"],
                     "permitted_data_classifications": ["internal"],
                     "permitted_targets": [OTHER_NODE]})
check(empty.reason == A.REASON_EMPTY_SCOPE,
      "an empty target intersection is still reported as an empty scope")

check(A.REASON_TARGET_SCOPE != A.REASON_EMPTY_SCOPE
      and A.REASON_TARGET_SCOPE != A.REASON_CAPABILITY_SCOPE,
      "the target refusal is distinct from the empty-scope and capability reasons")


# ===========================================================================
# G11-A3 -- governed advertisement supersession
# ===========================================================================

print("\n--- G11-A3: advertisement renewal and supersession ---")

check("supersedes" in (ADVERT_SCHEMA.get("optional_fields") or ()),
      "the advertisement schema still offers supersedes")

w = world()
first = w["adv"]
check(w["store"].read_record("capability-advertisement",
                             first.record_id).get("supersedes") is None,
      "a first advertisement supersedes nothing")

second = renewal(w)
check(second.outcome == "accepted", "a renewal naming its predecessor is accepted")
stored_second = w["store"].read_record("capability-advertisement", second.record_id)
check(stored_second.get("supersedes") == first.record_id,
      "the renewal names the advertisement it replaces")

before = w["store"].read_record("capability-advertisement", first.record_id)
check(before.get("superseded_by") is None,
      "the superseded advertisement is not given a backlink")
check(before.get("supersedes") is None,
      "the superseded advertisement is otherwise untouched")

head = A.advertisement_head(w["store"], first.record_id)
check(head == second.record_id,
      "the head of the chain is the record nothing supersedes")
check(A.advertisement_head(w["store"], second.record_id) == second.record_id,
      "the head of a head is itself")

RENEWAL_REFUSALS = (
    ({"supersedes": "CADV-999999"}, "a predecessor that does not exist",
     A.REASON_UNRESOLVED),
    ({"supersedes": "not-an-identifier"}, "a malformed predecessor",
     A.REASON_CONTENT),
    ({"supersedes": "CHOST-0001"}, "a predecessor of another record kind",
     A.REASON_CONTENT),
)
for overrides, description, expected in RENEWAL_REFUSALS:
    w2 = world()
    result = renewal(w2, request_id="g11-adv-bad", **overrides)
    check(result.record_id is None, f"a renewal naming {description} is refused")
    check(result.reason == expected,
          f"a renewal naming {description} is named {expected}")

# Same host, same package, same contract. A change to any of those is a new
# binding, not a renewal of this one.
w2 = world()
other = declare_package(
    w2["store"], request_id="g11-pkg-2", actor=OPERATOR,
    approving_authority=OPERATOR, recorded_at=STAMP,
    capability_id=w2["cap"].record_id, contract_id=w2["con"].record_id,
    satisfied_contract_versions=("1.0.0",), package_version="2.0.0",
    artifact_reference="tree:probe/2.0.0", resource_requirements={},
    trust_domain="capability-package", provenance=PROV)
changed = renewal(w2, request_id="g11-adv-pkg",
                  capability_package_id=other.record_id)
check(changed.record_id is None,
      "a renewal changing the package is refused as a different binding")
check(changed.reason == A.REASON_RENEWAL_PACKAGE,
      f"a package change is named {A.REASON_RENEWAL_PACKAGE}")

w2 = world()
other_con = declare_contract(
    w2["store"], request_id="g11-con-2", actor=OPERATOR,
    approving_authority=OPERATOR, recorded_at=STAMP,
    capability_id=w2["cap"].record_id, contract_version="2.0.0",
    effect_class="computational", determinism_class="deterministic",
    request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
    failure_modes=("adapter-error",), resource_requirements={},
    compatible_with=(), provenance=PROV)
changed = renewal(w2, request_id="g11-adv-con", contract_id=other_con.record_id)
check(changed.record_id is None,
      "a renewal changing the contract is refused as a different binding")
# Through the reachable path, deliberately. A renewal must name the same
# package, a package names exactly one contract, and the body's contract was
# already required to be that one -- so a contract change is refused before
# any renewal rule runs, and a renewal-specific contract reason could never be
# produced. Asserting the reason that can actually occur keeps the test honest
# about which check is doing the work.
check(changed.reason == A.REASON_PACKAGE_CONTRACT,
      f"a contract change is named {A.REASON_PACKAGE_CONTRACT}")
check(not hasattr(A, "REASON_RENEWAL_CONTRACT"),
      "no unreachable renewal-contract reason is carried in the vocabulary")

# A different host is a different subject's claim entirely.
w2 = world()
second_host = admit_subject(
    w2["store"], w2["trust"], request_id="g11-host-2", actor=OPERATOR,
    approving_authority=OPERATOR, recorded_at=STAMP, evaluated_at=STAMP,
    node_identity_reference=NODE,
    fabric_node_trust_record_id=w2["host_grant"].record.record_id,
    verified_resource_profile=dict(PROFILE),
    verification_reference="/approved/observed.txt",
    location_class="on-premises", data_classification="internal",
    availability_intent="in-service", provenance=PROV)
wrong_host = renewal(w2, request_id="g11-adv-host",
                     actor=second_host.record_id,
                     capability_host_id=second_host.record_id)
check(wrong_host.record_id is None,
      "a renewal by a different host is refused")
check(wrong_host.reason == A.REASON_RENEWAL_HOST,
      f"a host change is named {A.REASON_RENEWAL_HOST}")

# Self-supersession, and superseding something already superseded.
w2 = world()
renewed = renewal(w2, request_id="g11-adv-head")
forked = renewal(w2, request_id="g11-adv-fork")
check(forked.record_id is None,
      "a second renewal of an already-superseded advertisement is refused")
check(forked.reason == A.REASON_RENEWAL_NOT_HEAD,
      f"superseding a superseded advertisement is named {A.REASON_RENEWAL_NOT_HEAD}")

# The successor is still a self-report inside a valid window.
w2 = world()
stale = renewal(w2, request_id="g11-adv-stale",
                observed_at=STAMP - timedelta(days=3),
                valid_until=STAMP - timedelta(days=2))
check(stale.record_id is None,
      "a renewal whose window never covered its own request is refused")
check(stale.reason == A.REASON_WINDOW,
      "a stale renewal keeps the committed invalid-validity-window reason")

w2 = world()
impostor = renewal(w2, request_id="g11-adv-impostor", actor=OPERATOR)
check(impostor.record_id is None,
      "a renewal whose actor is not the subject is refused")
check(impostor.reason == A.REASON_NOT_SUBJECT,
      "a renewal by a non-subject keeps the actor-is-not-the-subject reason")

w2 = world()
greedy = renewal(w2, request_id="g11-adv-greedy",
                 advertised_resource_profile={"host_memory_mb": 65536})
check(greedy.record_id is None,
      "a renewal claiming more than the verified profile is refused")
check(greedy.reason == A.REASON_RESOURCE_CLAIM,
      "an enlarged renewal keeps the resource-claim-not-verified reason")

# Nothing about a refused renewal reaches the store.
w2 = world()
before_counts = w2["store"].counts().get("capability-advertisement", 0)
w2_refused = renewal(w2, request_id="g11-adv-nothing", supersedes="CADV-999999")
check(w2_refused.record_id is None, "a refused renewal names no record")
check(w2["store"].counts().get("capability-advertisement", 0) == before_counts,
      "a refused renewal allocates nothing")

# --- every refusal leaves the plane exactly as it found it -------------------
#
# Asserted as one sweep rather than case by case, so a refusal that quietly
# spent a sequence position or touched the record it was replacing cannot hide
# behind a neighbour that did not.
def forensic(root):
    entries = []
    for path in sorted(Path(root).rglob("*")):
        if path.is_file():
            entries.append((str(path.relative_to(root)), path.read_bytes()))
    return tuple(entries)

REFUSED_RENEWALS = (
    ({"supersedes": "CADV-999999"}, "an absent predecessor"),
    ({"supersedes": "not-an-identifier"}, "a malformed predecessor"),
    ({"supersedes": "CHOST-0001"}, "a predecessor of another kind"),
    ({"actor": OPERATOR}, "an actor that is not the subject"),
    ({"observed_at": STAMP - timedelta(days=3),
      "valid_until": STAMP - timedelta(days=2)}, "a window already closed"),
    ({"advertised_resource_profile": {"host_memory_mb": 65536}},
     "a claim beyond the verified profile"),
)
for overrides, description in REFUSED_RENEWALS:
    w2 = world()
    fabric_root = w2["tmp"] / "fabric"
    before_tree = forensic(fabric_root)
    before_prior = w2["store"].read_record("capability-advertisement",
                                           w2["adv"].record_id)
    result = renewal(w2, request_id="g11-adv-forensic", **overrides)
    check(result.record_id is None, f"a renewal with {description} is refused")
    check(forensic(fabric_root) == before_tree,
          f"a renewal with {description} writes nothing and spends no sequence")
    check(w2["store"].read_record("capability-advertisement",
                                  w2["adv"].record_id) == before_prior,
          f"a renewal with {description} leaves the predecessor byte-identical")

# --- an accepted renewal leaves its predecessor byte-identical ---------------
w2 = world()
prior_before = (w2["tmp"] / "fabric" / "capability-advertisements"
                / f"{w2['adv'].record_id}.yaml").read_bytes()
accepted_renewal = renewal(w2, request_id="g11-adv-immutable")
check(accepted_renewal.outcome == "accepted", "the renewal under test is accepted")
prior_after = (w2["tmp"] / "fabric" / "capability-advertisements"
               / f"{w2['adv'].record_id}.yaml").read_bytes()
check(prior_after == prior_before,
      "an accepted renewal leaves the predecessor's bytes untouched")

# --- damaged chains are refused, never walked --------------------------------
#
# The released write path cannot produce any of these. A damaged, tampered or
# hand-edited store can, and a traversal that resolved them would report a head
# no readable record supports.
def _damage(store, identity, **fields):
    """Rewrite one advertisement in place. Fixture only; simulates damage."""
    path = Path(store.root) / "capability-advertisements" / f"{identity}.yaml"
    record = yaml.safe_load(path.read_text(encoding="utf-8"))
    record.update(fields)
    path.write_text(yaml.safe_dump(record, sort_keys=True), encoding="utf-8")

def _refuses(callable_, expected, description):
    try:
        callable_()
    except Exception as error:                                  # noqa: BLE001
        check(expected in str(error) or expected == getattr(error, "reason", None),
              f"{description} is refused as {expected}")
        return
    check(False, f"{description} is refused as {expected}")

# A self-loop: the degenerate cycle. Unreachable through the write path,
# because a record's identity is minted after every check has passed.
w2 = world()
_damage(w2["store"], w2["adv"].record_id, supersedes=w2["adv"].record_id)
_refuses(lambda: A.advertisement_head(w2["store"], w2["adv"].record_id),
         A.REASON_ADVERT_CYCLIC, "an advertisement superseding itself")
check(not hasattr(A, "REASON_RENEWAL_SELF"),
      "no unreachable self-supersession reason is carried in the vocabulary")

# A cycle of two.
w2 = world()
second = renewal(w2, request_id="g11-adv-cycle")
_damage(w2["store"], w2["adv"].record_id, supersedes=second.record_id)
_refuses(lambda: A.advertisement_head(w2["store"], w2["adv"].record_id),
         A.REASON_ADVERT_CYCLIC, "a two-record cycle")

# A fork: two records claiming the same predecessor.
w2 = world()
one = renewal(w2, request_id="g11-adv-fork-a")
two = register_advertisement(
    w2["store"], request_id="g11-adv-fork-b", actor=w2["host"].record_id,
    recorded_at=LATER, capability_host_id=w2["host"].record_id,
    capability_package_id=w2["pkg"].record_id, contract_id=w2["con"].record_id,
    satisfied_contract_versions=("1.0.0",),
    advertised_resource_profile={"architecture": "x86-64"},
    observed_at=LATER, valid_until=LATER + timedelta(days=1), provenance=PROV)
check(two.outcome == "accepted", "a second unrelated claim is accepted")
_damage(w2["store"], two.record_id, supersedes=w2["adv"].record_id)
_refuses(lambda: A.advertisement_head(w2["store"], w2["adv"].record_id),
         A.REASON_ADVERT_FORKED, "two records claiming one predecessor")

# A successor whose predecessor is missing does not become the head.
w2 = world()
orphan = renewal(w2, request_id="g11-adv-orphan")
(Path(w2["store"].root) / "capability-advertisements"
 / f"{w2['adv'].record_id}.yaml").unlink()
_refuses(lambda: A.advertisement_head(w2["store"], orphan.record_id),
         A.REASON_ADVERT_INCOHERENT, "a successor whose predecessor is absent")

# --- and the sound chain still resolves --------------------------------------
w2 = world()
renewal(w2, request_id="g11-adv-chain")
check(A.advertisement_head(w2["store"], w2["adv"].record_id) is not None,
      "a sound chain resolves to a head")

# --- superseded_by is derived, never written ---------------------------------
#
# Not one released operation writes it, for any of the seven record classes.
# The head is derived by reverse lookup over `supersedes`, which is the
# doctrine `_successors` states and hosts and instances already follow.
import tools.fabric.admission as _adm
_source = Path("tools/fabric/admission.py").read_text(encoding="utf-8")
check("superseded_by=" not in _source,
      "no released Fabric operation assigns superseded_by")
w2 = world()
renewed = renewal(w2, request_id="g11-adv-derived")
for identity in (w2["adv"].record_id, renewed.record_id):
    stored = w2["store"].read_record("capability-advertisement", identity)
    check(stored.get("superseded_by") is None,
          f"{identity} carries no superseded_by backlink")

print(f"\n{failures} assertion(s) failed." if failures
      else "\nAll G11-A integrity assertions passed.")
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
