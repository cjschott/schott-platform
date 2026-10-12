#!/usr/bin/env bash
set -Eeuo pipefail

# G11-H: instance admission rehearsal integrity, and advertisement currentness.
#
# TWO CORRECTIONS, AND THE TEST GAP THAT HID BOTH.
#
# R15. `admit_instance` ends by proving the freshly minted identity is not the
#      one it supersedes. Under `rehearsing()` nothing is minted and `_commit`
#      reports that as `None`; for a FIRST admission `supersedes` is `None`
#      too, so the guard compared two absences and refused every preflight of a
#      first admission -- with `supersedes-different-capability`, a reason
#      naming supersession for a request that supersedes nothing. The write
#      path was always correct, so the defect was invisible to anything that
#      only exercised writes.
#
# R16. Admission checked that the advertisement was FRESH and never that it was
#      CURRENT. `advertisement_head` existed and was called only from the
#      renewal rule at the other end of the chain. A superseded advertisement
#      well inside its window was therefore admissible, and the instance would
#      have been permanently bound to a claim the host had already replaced.
#
# WHY THE SUITE MISSED THEM. Only `select` and `declare-package` were ever
# exercised through `--preflight` anywhere in the repository, so no test ever
# rehearsed an instance admission -- and every admission test used an
# advertisement that was both fresh and current, so freshness and currentness
# were never separated. Both gaps are closed here: the CLI preflight of a first
# admission is exercised end to end, and the four advertisement states
# (current+fresh, superseded+fresh, current+expired, superseded+expired) are
# each pinned to their own outcome.
#
# THE GUARD IS NOT DELETED. It is scoped to the case it can speak about. Three
# proofs below: the condition is unchanged for every committed write, C1's
# allocator structurally cannot produce the collision it guards against, and
# the guard still fires when a damaged allocator is simulated.
#
# FIXTURE ONLY. Every case works in a temporary root. Nothing here touches
# /var/lib/kyri, and the suite proves it did not.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-28-g11-g-cinst-000001-preflight.md
#   docs/development/reports/eng-0005/2026-08-28-g11-h-cinst-preflight-integrity.md
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
import json, os, subprocess, sys, tempfile
import yaml
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

from tools.fabric import admission as A
from tools.fabric.admission import (
    admit_instance, declare_capability, declare_contract, declare_package,
    admit_subject, register_advertisement, advertisement_head,
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
STAMP = datetime(2026, 8, 2, 9, 0, 0, tzinfo=ZONE)
LATER = STAMP + timedelta(days=1)
YEAR = STAMP + timedelta(days=365)
OPERATOR = "operator:g11h"
PROV = {"class": "declared", "source": "g11-h"}
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
            decided_at=STAMP, reason="Granted for the G11-H fixture world.",
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


def world():
    tmp = Path(tempfile.mkdtemp())
    store = FabricStore(tmp / "fabric", expected_uid=UID, expected_gid=GID)
    trust, host_grant, package_grant = seeded_trust(tmp)
    cap = declare_capability(
        store, request_id="g11h-cap", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, name="boundary probe", description="A probe.",
        effect_class="computational", contract_ids=(), provenance=PROV)
    con = declare_contract(
        store, request_id="g11h-con", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, capability_id=cap.record_id, contract_version="1.0.0",
        effect_class="computational", determinism_class="deterministic",
        request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
        failure_modes=("adapter-error",), resource_requirements={},
        compatible_with=(), provenance=PROV)
    pkg = declare_package(
        store, request_id="g11h-pkg", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, capability_id=cap.record_id, contract_id=con.record_id,
        satisfied_contract_versions=("1.0.0",), package_version="1.0.0",
        artifact_reference="tree:probe/1.0.0", resource_requirements={},
        trust_domain="capability-package", provenance=PROV)
    host = admit_subject(
        store, trust, request_id="g11h-host", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP, evaluated_at=STAMP,
        node_identity_reference=NODE,
        fabric_node_trust_record_id=host_grant.record.record_id,
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=PROV)
    adv = register_advertisement(
        store, request_id="g11h-adv", actor=host.record_id, recorded_at=STAMP,
        capability_host_id=host.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile={"architecture": "x86-64"},
        observed_at=STAMP, valid_until=LATER, provenance=PROV)
    return dict(tmp=tmp, store=store, trust=trust, cap=cap, con=con, pkg=pkg,
                host=host, adv=adv, host_grant=host_grant,
                package_grant=package_grant)


def body_of(w, **overrides):
    fields = dict(
        request_id="g11h-inst", actor=OPERATOR, approving_authority=OPERATOR,
        recorded_at=STAMP, evaluated_at=STAMP,
        capability_id=w["cap"].record_id,
        capability_package_id=w["pkg"].record_id,
        capability_host_id=w["host"].record_id,
        contract_id=w["con"].record_id,
        satisfied_contract_versions=("1.0.0",),
        verified_resource_profile=dict(PROFILE),
        admission_decision_id="approval/g11h",
        package_trust_record_id=w["package_grant"].record.record_id,
        host_trust_record_id=w["host_grant"].record.record_id,
        admission_scope={"permitted_capabilities": ["CAPDEF-0001"],
                         "permitted_operations": ["execute"],
                         "permitted_data_classifications": ["internal"],
                         "permitted_targets": [NODE]},
        admitted_at=STAMP, admitted_until=LATER, provenance=PROV,
        advertisement_id=w["adv"].record_id)
    fields.update(overrides)
    return fields


def admission_of(w, **overrides):
    return admit_instance(w["store"], w["trust"], **body_of(w, **overrides))


def renew(w, **overrides):
    fields = dict(
        request_id="g11h-adv-2", actor=w["host"].record_id, recorded_at=LATER,
        capability_host_id=w["host"].record_id,
        capability_package_id=w["pkg"].record_id, contract_id=w["con"].record_id,
        satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile={"architecture": "x86-64"},
        observed_at=LATER, valid_until=LATER + timedelta(days=1),
        provenance=PROV, supersedes=w["adv"].record_id)
    fields.update(overrides)
    return register_advertisement(w["store"], **fields)


def nothing_allocated(w, label):
    """A refusal must leave the instance sequence untouched."""
    records = list(w["store"].list_records("capability-instance"))
    seq = Path(w["tmp"]) / "fabric" / "sequences" / "capability-instance.seq"
    check(not records and not seq.exists(),
          f"    -> {label}: no instance written, capability-instance.seq absent")


# ===========================================================================
# R15 -- the rehearsal of a FIRST admission
# ===========================================================================
print("\n--- R15: a first admission can be rehearsed ---")

w = world()
with A.rehearsing():
    pre = admission_of(w)
check(pre.outcome == A.PREFLIGHT and pre.reason is None,
      f"a first admission rehearses to preflight (got {pre.outcome}/{pre.reason})")
check(pre.record_id is None, "the rehearsal names no record")
nothing_allocated(w, "first-admission rehearsal")

predicted = w["store"].peek_next_id("capability-instance")
written = admission_of(w)
check(written.outcome == A.ACCEPTED, "the same body is accepted when written")
check(written.record_id == predicted,
      f"the written identity is the predicted one ({predicted})")
check(pre.request_digest == written.request_digest,
      "the rehearsal and the write share one request digest")

# The superseding case must keep working: it was never broken, and a fix that
# only moved the defect would show up here.
w2 = world()
first = admission_of(w2)
with A.rehearsing():
    mig = admission_of(w2, request_id="g11h-inst-mig", supersedes=first.record_id)
check(mig.outcome == A.PREFLIGHT,
      f"a superseding admission still rehearses to preflight (got {mig.outcome}/{mig.reason})")

# --- the minted-identity guard is scoped, not removed -----------------------
print("\n--- R15: the minted-identity guard is preserved ---")

# 1. For a committed write `allocated` is always a minted identity, so the
#    added `is not None` term is always true and the condition is unchanged.
equivalent = True
for allocated, supersedes, prior_root in (
        ("CINST-000002", "CINST-000001", None),
        ("CINST-000001", "CINST-000001", None),
        ("CINST-000003", "CINST-000002", "CINST-000001"),
        ("CINST-000001", "CINST-000002", "CINST-000001")):
    before = (allocated == supersedes) or (prior_root is not None
                                           and allocated == prior_root)
    after = allocated is not None and ((allocated == supersedes)
                                       or (prior_root is not None
                                           and allocated == prior_root))
    equivalent = equivalent and (before == after)
check(equivalent,
      "for every write-path case the guard's verdict is unchanged by the scoping")

# 2. C1 cannot produce the collision: the allocator skips occupied names.
w3 = world()
seeded = admission_of(w3)
seq = Path(w3["tmp"]) / "fabric" / "sequences" / "capability-instance.seq"
seq.write_text("0\n")
check(w3["store"].peek_next_id("capability-instance") != seeded.record_id,
      "with the sequence rewound C1 still refuses to re-mint an occupied identity")

# 3. And the guard still fires when a damaged allocator is simulated -- which
#    is the only way its precondition can be reached, and the reason it exists.
class DamagedStore(FabricStore):
    def allocate_id(self, kind):
        if kind == "capability-instance":
            return "CINST-000001"
        return super().allocate_id(kind)
    def write(self, kind, record):
        return None

damaged = DamagedStore(Path(w3["tmp"]) / "fabric", expected_uid=UID, expected_gid=GID)
forced = admit_instance(damaged, w3["trust"],
                        **body_of(w3, request_id="g11h-inst-forced",
                                  supersedes="CINST-000001"))
check(forced.outcome == A.REFUSED
      and forced.reason == "supersedes-different-capability",
      f"a damaged allocator that re-mints the superseded identity still refuses "
      f"(got {forced.outcome}/{forced.reason})")


# ===========================================================================
# R15 -- through the released CLI, which is where the gap was
# ===========================================================================
print("\n--- R15: admit-instance --preflight, end to end ---")

w4 = world()
approved = Path(w4["tmp"]) / "cli-approved"
approved.mkdir()
cli_body = body_of(w4)
for field in ("recorded_at", "evaluated_at", "admitted_at", "admitted_until"):
    cli_body[field] = cli_body[field].isoformat()
cli_body["satisfied_contract_versions"] = list(cli_body["satisfied_contract_versions"])
approved.joinpath("inst.json").write_text(json.dumps(cli_body, indent=2) + "\n")

completed = subprocess.run(
    [sys.executable, "-m", "tools.fabric.cli", "admit-instance", "--preflight",
     "--store-root", str(Path(w4["tmp"]) / "fabric"),
     "--expected-uid", str(UID), "--expected-gid", str(GID),
     "--trust-store-root", str(Path(w4["tmp"]) / "trust"),
     "--input-file", "inst.json", "--approved-directory", str(approved)],
    capture_output=True, text=True, cwd=".")
check(completed.returncode == 0,
      f"the CLI preflight of a first admission exits zero (got {completed.returncode})")
try:
    payload = json.loads(completed.stdout)
except ValueError:
    payload = {}
    check(False, f"the CLI emitted a readable payload ({completed.stderr.strip()[:120]})")
check(payload.get("would_accept") is True,
      f"the CLI preflight reports would_accept true (got {payload.get('would_accept')})")
check(payload.get("rehearsal_outcome") == "preflight",
      f"the CLI preflight rehearsal outcome is preflight "
      f"(got {payload.get('rehearsal_outcome')}/{payload.get('rehearsal_reason')})")
check(payload.get("predicted_record_id") == "CINST-000001",
      f"the CLI preflight predicts CINST-000001 (got {payload.get('predicted_record_id')})")
check(payload.get("mutated") is False, "the CLI preflight reports mutating nothing")
check(payload.get("destination_exists") is False,
      "the CLI preflight reports the destination absent")
nothing_allocated(w4, "CLI preflight")


# ===========================================================================
# R16 -- the advertisement must be current, not merely fresh
# ===========================================================================
print("\n--- R16: freshness and currentness are independent ---")

# current + fresh -> accepted, and rehearsable
w5 = world()
with A.rehearsing():
    ok_pre = admission_of(w5)
check(ok_pre.outcome == A.PREFLIGHT,
      "a current, fresh advertisement rehearses to preflight")
ok = admission_of(w5)
check(ok.outcome == A.ACCEPTED, "a current, fresh advertisement is admitted")

# superseded + fresh -> refused as superseded, NOT as stale
w6 = world()
renewed = renew(w6)
check(renewed.outcome == A.ACCEPTED, "the fixture renewal is accepted")
check(advertisement_head(w6["store"], w6["adv"].record_id) == renewed.record_id,
      "the renewal is the chain head")
stale_free = admission_of(w6, request_id="g11h-inst-superseded")
check(stale_free.outcome == A.REFUSED
      and stale_free.reason == "advertisement-record-superseded",
      f"a superseded but still-fresh advertisement refuses as superseded "
      f"(got {stale_free.outcome}/{stale_free.reason})")
check(stale_free.reason != "advertisement-not-fresh",
      "a temporally fresh advertisement is never reported as stale")
nothing_allocated(w6, "superseded advertisement")

# current + expired -> refused as stale, NOT as superseded
w7 = world()
after_expiry = LATER + timedelta(hours=1)
expired = admission_of(w7, request_id="g11h-inst-expired",
                       evaluated_at=after_expiry,
                       admitted_until=after_expiry + timedelta(days=1))
check(expired.outcome == A.REFUSED and expired.reason == "advertisement-not-fresh",
      f"a current but expired advertisement refuses as not fresh "
      f"(got {expired.outcome}/{expired.reason})")
nothing_allocated(w7, "expired advertisement")

# superseded + expired -> superseded wins, deliberately: the operator's action
# is to consume the head, which is fresh, not to renew what they named.
w8 = world()
renew(w8)
both = admission_of(w8, request_id="g11h-inst-both",
                    evaluated_at=after_expiry,
                    admitted_until=after_expiry + timedelta(days=1))
check(both.outcome == A.REFUSED and both.reason == "advertisement-record-superseded",
      f"an advertisement that is both superseded and expired reports superseded "
      f"(got {both.outcome}/{both.reason})")
nothing_allocated(w8, "superseded and expired advertisement")

# The head itself is admissible after a renewal -- the rule excludes the
# predecessor, not the lineage.
w9 = world()
head = renew(w9)
onto_head = admission_of(w9, request_id="g11h-inst-head",
                         advertisement_id=head.record_id,
                         evaluated_at=LATER, admitted_at=LATER,
                         admitted_until=LATER + timedelta(days=1))
check(onto_head.outcome == A.ACCEPTED,
      f"the renewal itself is admissible (got {onto_head.outcome}/{onto_head.reason})")


# ===========================================================================
# R16 -- a damaged advertisement chain still fails closed
# ===========================================================================
print("\n--- R16: damaged chains fail closed through the existing traversal ---")

def advert_path(w, identity):
    return Path(w["tmp"]) / "fabric" / "capability-advertisements" / f"{identity}.yaml"

def rewrite(w, identity, **changes):
    path = advert_path(w, identity)
    record = yaml.safe_load(path.read_text())
    record.update(changes)
    path.write_text(yaml.safe_dump(record, sort_keys=True))

# forked: two successors claim one predecessor
w10 = world()
renew(w10)
forked_source = advert_path(w10, w10["adv"].record_id)
clone = yaml.safe_load(forked_source.read_text())
clone["advertisement_id"] = "CADV-000009"
clone["supersedes"] = w10["adv"].record_id
advert_path(w10, "CADV-000009").write_text(yaml.safe_dump(clone, sort_keys=True))
forked = admission_of(w10, request_id="g11h-inst-forked")
check(forked.outcome == A.REFUSED and forked.reason == "advertisement-chain-forked",
      f"a forked advertisement chain refuses (got {forked.outcome}/{forked.reason})")
nothing_allocated(w10, "forked chain")

# cyclic: a record that supersedes itself
w11 = world()
rewrite(w11, w11["adv"].record_id, supersedes=w11["adv"].record_id)
cyclic = admission_of(w11, request_id="g11h-inst-cyclic")
check(cyclic.outcome == A.REFUSED and cyclic.reason == "advertisement-chain-cyclic",
      f"a cyclic advertisement chain refuses (got {cyclic.outcome}/{cyclic.reason})")
nothing_allocated(w11, "cyclic chain")

# incoherent: a successor naming a predecessor that is not there
w12 = world()
orphan = yaml.safe_load(advert_path(w12, w12["adv"].record_id).read_text())
orphan["advertisement_id"] = "CADV-000009"
orphan["supersedes"] = "CADV-000008"
advert_path(w12, "CADV-000009").write_text(yaml.safe_dump(orphan, sort_keys=True))
incoherent = admission_of(w12, request_id="g11h-inst-incoherent")
check(incoherent.outcome == A.REFUSED
      and incoherent.reason == "advertisement-chain-incoherent",
      f"an unreadable advertisement chain refuses "
      f"(got {incoherent.outcome}/{incoherent.reason})")
nothing_allocated(w12, "incoherent chain")

# The rule reads through the governed helper, not a second traversal.
source = Path("tools/fabric/admission.py").read_text()
check(source.count("def advertisement_head(") == 1,
      "there is exactly one advertisement lineage traversal")
check("advertisement_head(store, advertisement_id) != advertisement_id" in source,
      "instance admission consumes that traversal rather than reimplementing it")

print(f"\n{failures} assertion(s) failed." if failures
      else "\nAll G11-H instance admission integrity assertions passed.")
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
