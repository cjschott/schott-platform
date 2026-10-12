#!/usr/bin/env bash
set -Eeuo pipefail

# The one-time governed repair that gives TAUTH-000001 the root establishment
# lineage record its ceremony allocated an identifier for and never wrote.
#
# THE DEFECT THIS SUITE EXISTS FOR.
#
# The Operator Root Authority ceremony ran on 2026-08-03 against commit
# 3dd5b84, whose `declare_root_authority` allocated a lineage identifier for
# the authority and wrote no lineage record. TAUTH-000001 and TAUDIT-000001
# both name TLIN-000001; `lineages/` holds nothing for it. Commit 58a56b5
# ("persist the root establishment lineage as a dedicated record type") fixed
# the write path fifteen hours later, but a fixed write path does not
# retroactively create a record, and a second root declaration is refused --
# correctly -- so the production store cannot be repaired by re-running the
# ceremony.
#
# ADR-0014 specifies the repair, constrains it, and deliberately does not
# authorise it. This suite implements what it specifies:
#
#   * exactly two new immutable records, TLIN-000001-v0001 and one backfill
#     audit event;
#   * every field reconstructed from immutable TAUTH/TAUDIT/TEVID authority,
#     nothing invented;
#   * no pre-existing record rewritten, proved by digest before and after;
#   * no lineage identifier allocated -- the ceremony already spent TLIN-000001;
#   * refused outright if a lineage record for TLIN-000001 already exists.
#
# WHAT IS NOT CHANGED. `validate-store` keeps every rule it has. A decision or
# record naming a lineage that does not exist still fails, and this suite
# proves it: the repair writes the missing record, it does not teach the
# validator to overlook missing records.
#
# Fixture-only. Every case runs against a temporary store built by this file.
# It performs no backfill against the live store and proves the live Trust and
# Fabric trees are byte-identical when it finishes.
#
# Governed by:
#   docs/decisions/ADR-0014-root-establishment-lineage.md
#   docs/trust/root-establishment-lineage.md
#   docs/trust/root-lineage-backfill-plan.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

LIVE_TRUST="/var/lib/kyri/trust"                   # prod-path-reference
LIVE_FABRIC="/var/lib/kyri/fabric"                 # prod-path-reference
live_state() {
  if [[ -e "$1" ]]; then
    { find "$1" -printf '%y %m %n %U:%G %s %p\n' 2>/dev/null | sort
      find "$1" -type f -exec sha256sum {} + 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
  else
    printf 'absent'
  fi
}
# Every case in this suite is fixture-only; the live store appears solely in the
# no-mutation proof below. On a runner there is no /var/lib/kyri, and `find` on
# an absent directory exits non-zero -- which under `set -Eeuo pipefail` killed
# this suite before it printed a single line. The guard is presence, not
# opt-out: on the production host the proof runs exactly as before.
LIVE_PRESENT=no
[[ -d "${LIVE_TRUST}" && -d "${LIVE_FABRIC}" ]] && LIVE_PRESENT=yes

count_live() { find "$1" -type f 2>/dev/null | wc -l || true; }

if [[ "${LIVE_PRESENT}" == "yes" ]]; then
  TRUST_BEFORE="$(live_state "${LIVE_TRUST}")"
  FABRIC_BEFORE="$(live_state "${LIVE_FABRIC}")"
  LINEAGES_BEFORE="$(count_live "${LIVE_TRUST}/lineages")"
  AUDIT_BEFORE="$(count_live "${LIVE_TRUST}/audit")"
fi

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && python3 -c "${script}" 2>&1)"; then
    if [[ "${actual}" == "OK" ]]; then
      pass "${label}"
    else
      fail "${label} -- expected OK, got: ${actual}"
    fi
  else
    fail "${label} -- raised: ${actual}"
  fi
}

# Rebuilds the production shape exactly as the pre-fix ceremony left it: five
# evidence references, one authority, one root-declaration audit event, a
# lineage identifier allocated and no lineage record. Nothing here reads the
# live store; the shape is reconstructed, not copied, so the suite proves what
# the defect is rather than that one directory currently has it.
PRELUDE=$(cat <<'PYPRELUDE'
import sys
sys.dont_write_bytecode = True
import hashlib, tempfile
from datetime import datetime, timezone
from pathlib import Path
from tools.trust.audit import AuditEventKind
from tools.trust.errors import TrustError
from tools.trust.models import (
    AuthorityType, OperatorRootAuthority, RootAuthorityLineage, TrustAuditEvent,
    TrustEvidenceReference, TrustState, TrustVerificationDetails,
    validate_root_lineage_record,
)
from tools.trust.store import TrustStore

CEREMONY = datetime(2026, 8, 3, 22, 0, 6, tzinfo=timezone.utc)
REPAIR = datetime(2026, 8, 25, 19, 4, 11, tzinfo=timezone.utc)
OPERATOR = "primary-platform-operator"
WHY = ("The root establishment lineage record was omitted by the ceremony "
       "write path and is reconstructed here from immutable authority.")

EVIDENCE_KINDS = ("out-of-band-verification-record", "fingerprint-record",
                  "offline-signature", "public-key", "checksum-manifest")


def make_store(tmp):
    return TrustStore(Path(tmp) / "trust")


def pre_fix_ceremony(store):
    """Exactly what commit 3dd5b84 wrote: no lineage record, identifier spent."""
    references = tuple(
        TrustEvidenceReference(
            evidence_id=store.allocate_id("evidence"), kind=kind,
            reference=f"/etc/kyri/trust/evidence/operator-root/{kind}",
            recorded_at=CEREMONY)
        for kind in EVIDENCE_KINDS)
    authority = OperatorRootAuthority(
        authority_id=store.allocate_id("authority"),
        authority_type=AuthorityType.OPERATOR_ROOT.value,
        display_name="Operator Root Authority",
        external_identity_reference="openpgp-fingerprint://" + "A" * 40,
        verification_method="out-of-band-fingerprint-comparison",
        verification_details=TrustVerificationDetails(
            subject_property="operator-root-key-fingerprint",
            observed_value_reference="/etc/kyri/trust/evidence/operator-root/FINGERPRINT.txt",
            comparison_source="independently-trusted-management-session",
            performed_by=OPERATOR, performed_at=CEREMONY),
        evidence_references=references,
        created_at=CEREMONY,
        provenance={"class": "declared", "source": "operator-out-of-band"},
        state=TrustState.TRUSTED.value,
        lineage_id=store.allocate_id("lineage"),
    )
    audit = TrustAuditEvent(
        audit_id=store.allocate_id("audit"),
        event_kind=AuditEventKind.ROOT_AUTHORITY_DECLARED.value,
        subject_id=authority.authority_id, lineage_id=authority.lineage_id,
        actor_authority_id=authority.authority_id,
        related_record_ids=tuple(r.evidence_id for r in references),
        occurred_at=CEREMONY,
        reason="an external operator root authority was declared out of band",
        provenance={"class": "declared", "source": "operator-out-of-band"})
    for reference in references:
        store.write("evidence", reference)
    store.write("authority", authority)
    store.write("audit", audit)
    # Deliberately no store.write("lineage", ...): that is the defect.
    return authority


def digests(store):
    return sorted((str(p.relative_to(store.root)),
                   hashlib.sha256(p.read_bytes()).hexdigest())
                  for p in store.root.rglob("*") if p.is_file())


def say(ok, detail=""):
    print("OK" if ok else f"NOT OK {detail}")
PYPRELUDE
)

py() { printf '%s\n%s\n' "${PRELUDE}" "$1"; }

# --- 1. RED: the defect reproduces, and reports exactly one finding ----------

run_case "RED: the pre-fix ceremony leaves an authority naming a lineage that has no record" "$(py '
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    authority = pre_fix_ceremony(store)
    problems = store.validate()
    expected = f"{authority.authority_id}: lineage \x27{authority.lineage_id}\x27 has no lineage record"
    say(problems == [expected], f"{problems}")
')"

run_case "RED: the ceremony spent the lineage identifier and wrote no lineage record" "$(py '
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    authority = pre_fix_ceremony(store)
    spent = (store.root / "sequences" / "lineage.seq").read_text().strip()
    say(spent == "1" and authority.lineage_id == "TLIN-000001"
        and store.all_records("lineage") == [],
        f"seq={spent} lineage_id={authority.lineage_id}")
')"

# --- 2. The backfill closes it, writing exactly two records ------------------

run_case "the backfill makes validate-store clean" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    say(store.validate() == [], f"{store.validate()}")
')"

run_case "the backfill creates exactly two new records" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    before = dict(digests(store))
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    after = dict(digests(store))
    added = sorted(set(after) - set(before))
    say(added == ["audit/TAUDIT-000002.yaml", "lineages/TLIN-000001-v0001.yaml"],
        f"{added}")
')"

run_case "the backfill rewrites no pre-existing record, byte for byte" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    before = {path: digest for path, digest in digests(store)
              if not path.startswith("sequences/")}
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    after = dict(digests(store))
    moved = [path for path, digest in before.items() if after.get(path) != digest]
    say(moved == [], f"moved={moved}")
')"

run_case "the backfill allocates no lineage identifier" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    spent = (store.root / "sequences" / "lineage.seq").read_text().strip()
    say(spent == "1" and store.peek_next_id("lineage") == "TLIN-000002", f"seq={spent}")
')"

# --- 3. Every reconstructed field comes from immutable authority -------------

run_case "every lineage field is reconstructed from the ceremony records" "$(py '
from tools.trust.models import EXTERNAL_OPERATOR_CEREMONY, LINEAGE_TYPE_ROOT_ESTABLISHMENT
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    authority = pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=True)
    lineage = plan.lineage
    say(lineage.lineage_id == authority.lineage_id
        and lineage.id == "TLIN-000001-v0001"
        and lineage.version == 1
        and lineage.lineage_type == LINEAGE_TYPE_ROOT_ESTABLISHMENT
        and lineage.authority_id == authority.authority_id
        and lineage.subject_type == AuthorityType.OPERATOR_ROOT.value
        and lineage.establishment_origin == EXTERNAL_OPERATOR_CEREMONY
        and list(lineage.evidence_reference_ids) == [r.evidence_id for r in authority.evidence_references]
        and lineage.establishment_audit_id == "TAUDIT-000001"
        and lineage.current_state == authority.state
        and lineage.established_at == authority.created_at
        and lineage.recorded_at == REPAIR
        and lineage.terminated is False,
        f"{lineage.to_dict()}")
')"

run_case "established_at is the ceremony instant and recorded_at is the repair instant" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=True)
    say(plan.lineage.established_at == CEREMONY and plan.lineage.recorded_at == REPAIR
        and plan.lineage.established_at != plan.lineage.recorded_at,
        f"{plan.lineage.established_at} {plan.lineage.recorded_at}")
')"

run_case "the written lineage satisfies the stored root establishment contract" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    stored = store.read("lineage", "TLIN-000001-v0001")
    validate_root_lineage_record(stored, "TLIN-000001-v0001")
    say(True)
')"

run_case "the backfill fabricates no decision identifier and no approver" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
forbidden = ("first_decision_id", "current_decision_id", "prior_decision_ids",
             "root_authority_id", "approved_by", "approval_source")
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    stored = store.read("lineage", "TLIN-000001-v0001")
    text = (store.root / "lineages" / "TLIN-000001-v0001.yaml").read_text()
    say(not any(key in stored for key in forbidden) and "TDEC" not in text
        and store.all_records("decision") == [], f"{sorted(stored)}")
')"

# --- 4. The backfill audit event -------------------------------------------

run_case "the backfill audit event names the operator, the reason, and both ceremonies" "$(py '
from tools.trust.root_lineage_backfill import (
    ROOT_LINEAGE_BACKFILLED, apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    event = store.read("audit", "TAUDIT-000002")
    say(event["event_kind"] == ROOT_LINEAGE_BACKFILLED
        and event["subject_id"] == "TAUTH-000001"
        and event["lineage_id"] == "TLIN-000001"
        and event["actor_authority_id"] == "TAUTH-000001"
        and event["occurred_at"] == REPAIR.isoformat()
        and event["reason"] == WHY
        and event["provenance"]["performed_by"] == OPERATOR
        and sorted(event["related_record_ids"]) == ["TAUDIT-000001", "TLIN-000001-v0001"],
        f"{event}")
')"

run_case "the ceremony audit event is not amended" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    path = store.root / "audit" / "TAUDIT-000001.yaml"
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    say(hashlib.sha256(path.read_bytes()).hexdigest() == before)
')"

run_case "a reason without substance is refused" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    try:
        plan_root_lineage_backfill(store, recorded_at=REPAIR, reason="repair",
                                   performed_by=OPERATOR, rehearse=True)
    except TrustError as error:
        say("written justification" in str(error), str(error))
    else:
        say(False, "a one-word reason was accepted")
')"

run_case "an unnamed operator is refused" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    try:
        plan_root_lineage_backfill(store, recorded_at=REPAIR, reason=WHY,
                                   performed_by="   ", rehearse=True)
    except TrustError as error:
        say("performed_by" in str(error), str(error))
    else:
        say(False, "an anonymous repair was accepted")
')"

run_case "a naive repair timestamp is refused" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    try:
        plan_root_lineage_backfill(
            store, recorded_at=datetime(2026, 8, 25, 19, 4, 11), reason=WHY,
            performed_by=OPERATOR, rehearse=True)
    except TrustError as error:
        say("recorded_at" in str(error), str(error))
    else:
        say(False, "a timestamp without a zone was accepted")
')"

# --- 5. Preconditions and refusals ------------------------------------------

run_case "an existing TLIN-000001 lineage record refuses the backfill" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    try:
        plan_root_lineage_backfill(store, recorded_at=REPAIR, reason=WHY,
                                   performed_by=OPERATOR, rehearse=True)
    except TrustError as error:
        say("already" in str(error), str(error))
    else:
        say(False, "a second backfill was planned")
')"

run_case "a conflicting TLIN-000001 record refuses the backfill rather than being repaired" "$(py '
from tools.trust.models import TrustLineage
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    authority = pre_fix_ceremony(store)
    store.write("lineage", TrustLineage(
        lineage_id=authority.lineage_id, version=1,
        subject_id=authority.authority_id, subject_type="operator-root",
        root_authority_id=authority.authority_id,
        first_decision_id="TDEC-000001", current_decision_id="TDEC-000001",
        prior_decision_ids=(), current_state=TrustState.TRUSTED.value,
        created_at=CEREMONY, last_changed_at=CEREMONY))
    try:
        plan_root_lineage_backfill(store, recorded_at=REPAIR, reason=WHY,
                                   performed_by=OPERATOR, rehearse=True)
    except TrustError as error:
        say("conflict" in str(error), str(error))
    else:
        say(False, "a conflicting lineage record was overwritten or ignored")
')"

run_case "a store with no root authority refuses the backfill" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    try:
        plan_root_lineage_backfill(store, recorded_at=REPAIR, reason=WHY,
                                   performed_by=OPERATOR, rehearse=True)
    except TrustError as error:
        say("no active operator-root authority" in str(error), str(error))
    else:
        say(False, "a root was backfilled into a store that has none")
')"

run_case "a missing root-declaration audit event refuses the backfill" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    (store.root / "audit" / "TAUDIT-000001.yaml").unlink()
    try:
        plan_root_lineage_backfill(store, recorded_at=REPAIR, reason=WHY,
                                   performed_by=OPERATOR, rehearse=True)
    except TrustError as error:
        say("root-authority-declared" in str(error), str(error))
    else:
        say(False, "an establishment audit identifier was invented")
')"

run_case "a missing ceremony evidence record refuses the backfill" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    (store.root / "evidence-references" / "TEVID-000003.yaml").unlink()
    try:
        plan_root_lineage_backfill(store, recorded_at=REPAIR, reason=WHY,
                                   performed_by=OPERATOR, rehearse=True)
    except TrustError as error:
        say("TEVID-000003" in str(error), str(error))
    else:
        say(False, "a lineage was written citing evidence that does not exist")
')"

# --- 6. Rehearsal spends nothing --------------------------------------------

run_case "rehearsal writes nothing and allocates nothing" "$(py '
from tools.trust.root_lineage_backfill import plan_root_lineage_backfill
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    before = digests(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=True)
    say(digests(store) == before and plan.audit_event.audit_id == "TAUDIT-000002"
        and store.peek_next_id("audit") == "TAUDIT-000002", f"{plan.audit_event.audit_id}")
')"

run_case "rehearsal predicts exactly what the write produces" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    rehearsed = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=True)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    say(rehearsed.lineage.to_dict() == store.read("lineage", "TLIN-000001-v0001")
        and rehearsed.audit_event.to_dict() == store.read("audit", "TAUDIT-000002"))
')"

run_case "a rehearsed plan cannot be applied" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=True)
    try:
        apply_root_lineage_backfill(store, plan)
    except TrustError as error:
        say("rehearsal" in str(error), str(error))
    else:
        say(False, "a predicted identifier was written as though it were allocated")
')"

# --- 7. Partial-failure recovery --------------------------------------------

run_case "a backfill interrupted after the lineage write is completed, not repeated" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    store.write("lineage", plan.lineage)          # the crash: lineage written, audit not
    resumed = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, resumed)
    say(resumed.writes_lineage is False and resumed.writes_audit is True
        and store.validate() == []
        and len(store.all_records("lineage")) == 1
        and len(store.all_records("audit")) == 2, f"{store.validate()}")
')"

run_case "completion reads the interrupted record rather than reconstructing its timestamp" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
LATER = datetime(2026, 9, 1, 8, 0, 0, tzinfo=timezone.utc)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    store.write("lineage", plan.lineage)
    resumed = plan_root_lineage_backfill(
        store, recorded_at=LATER, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, resumed)
    stored = store.read("lineage", "TLIN-000001-v0001")
    event = store.read("audit", resumed.audit_event.audit_id)
    say(stored["recorded_at"] == REPAIR.isoformat()
        and event["occurred_at"] == LATER.isoformat(), f"{stored} {event}")
')"

run_case "the audit identifier the interrupted attempt allocated stays spent, never reused" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    store.write("lineage", plan.lineage)          # the crash, after TAUDIT-000002 was spent
    resumed = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, resumed)
    stored_ids = sorted(e["audit_id"] for e in store.all_records("audit"))
    say(plan.audit_event.audit_id == "TAUDIT-000002"
        and resumed.audit_event.audit_id == "TAUDIT-000003"
        and stored_ids == ["TAUDIT-000001", "TAUDIT-000003"], f"{stored_ids}")
')"

# --- 8. The validator keeps every rule it has -------------------------------

run_case "a decision naming a lineage that has no record still fails" "$(py '
from tools.trust.models import TrustDecision, TrustScope
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    authority = pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    store.write("decision", TrustDecision(
        decision_id="TDEC-000001", subject_id="HOST-0009",
        lineage_id="TLIN-000404", actor_authority_id=authority.authority_id,
        previous_state="unknown", requested_state="trusted", decided_at=REPAIR,
        reason="a decision whose lineage record does not exist at all",
        evidence_references=authority.evidence_references,
        verification_method="out-of-band-fingerprint-comparison",
        verification_details=authority.verification_details,
        approval_source="named-operator", history_reference="TREC-000001",
        trust_scope=TrustScope(scope_id="TSCOPE-000001", subject_type="fabric-node")))
    problems = store.validate()
    say(problems == ["TDEC-000001: decision has no lineage"], f"{problems}")
')"

run_case "a record naming a lineage that has no record still fails" "$(py '
from tools.trust.models import TrustRecord
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    authority = pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    store.write("record", TrustRecord(
        record_id="TREC-000001", subject_id="HOST-0009", subject_type="fabric-node",
        state="trusted", lineage_id="TLIN-000404", decision_id="TDEC-000404",
        authority_id=authority.authority_id, created_at=REPAIR))
    problems = store.validate()
    say(problems == ["TREC-000001: record cites an unknown decision",
                     "TREC-000001: record has no lineage"], f"{problems}")
')"

run_case "a second authority naming a lineage that has no record still fails" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    # A declared root authority is trusted or it is not a root, so the second one
    # is trusted too and the store reports both problems. The point here is the
    # second finding: the authority-to-lineage rule is not about TAUTH-000001.
    second = OperatorRootAuthority(
        authority_id=store.allocate_id("authority"),
        authority_type=AuthorityType.OPERATOR_ROOT.value,
        display_name="A second operator root",
        external_identity_reference="openpgp-fingerprint://" + "B" * 40,
        verification_method="out-of-band-fingerprint-comparison",
        verification_details=TrustVerificationDetails(
            subject_property="operator-root-key-fingerprint",
            observed_value_reference="/etc/kyri/trust/evidence/operator-root/FINGERPRINT.txt",
            comparison_source="independently-trusted-management-session",
            performed_by=OPERATOR, performed_at=CEREMONY),
        evidence_references=(TrustEvidenceReference(
            evidence_id="TEVID-000001", kind="public-key",
            reference="/etc/kyri/trust/evidence/operator-root/operator-root-public.asc",
            recorded_at=CEREMONY),),
        created_at=CEREMONY, provenance={}, state=TrustState.TRUSTED.value,
        lineage_id="TLIN-000404")
    store.write("authority", second)
    problems = store.validate()
    say("TAUTH-000002: lineage \x27TLIN-000404\x27 has no lineage record" in problems,
        f"{problems}")
')"

run_case "the backfill teaches the validator nothing: validate still writes nothing" "$(py '
from tools.trust.root_lineage_backfill import (
    apply_root_lineage_backfill, plan_root_lineage_backfill)
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    pre_fix_ceremony(store)
    plan = plan_root_lineage_backfill(
        store, recorded_at=REPAIR, reason=WHY, performed_by=OPERATOR, rehearse=False)
    apply_root_lineage_backfill(store, plan)
    before = digests(store)
    store.validate()
    say(digests(store) == before)
')"

# --- 9. The module refuses to become a general repair tool ------------------

run_case "the backfill module defines no delete, update, or general repair entry point" "$(py '
import ast, pathlib
source = pathlib.Path("tools/trust/root_lineage_backfill.py").read_text()
names = {node.name for node in ast.walk(ast.parse(source))
         if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
public = sorted(name for name in names if not name.startswith("_"))
say(public == ["apply_root_lineage_backfill", "plan_root_lineage_backfill"], f"{public}")
')"

run_case "the backfill never writes an authority, record, decision, or evidence" "$(py '
import ast, pathlib
source = pathlib.Path("tools/trust/root_lineage_backfill.py").read_text()
written = set()
for node in ast.walk(ast.parse(source)):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "write" and node.args
            and isinstance(node.args[0], ast.Constant)):
        written.add(node.args[0].value)
say(written == {"lineage", "audit"}, f"{sorted(written)}")
')"

# --- 10. The live store is untouched ----------------------------------------

if [[ "${LIVE_PRESENT}" != "yes" ]]; then
  printf 'SKIP: no live Trust or Fabric store; there is nothing this suite could have touched\n'
else
TRUST_AFTER="$(live_state "${LIVE_TRUST}")"
FABRIC_AFTER="$(live_state "${LIVE_FABRIC}")"
if [[ "${TRUST_AFTER}" == "${TRUST_BEFORE}" ]]; then
  pass "the live Trust store is byte-identical"
else
  fail "the live Trust store changed: ${TRUST_BEFORE} -> ${TRUST_AFTER}"
fi
if [[ "${FABRIC_AFTER}" == "${FABRIC_BEFORE}" ]]; then
  pass "the live Fabric store is byte-identical"
else
  fail "the live Fabric store changed: ${FABRIC_BEFORE} -> ${FABRIC_AFTER}"
fi

# This asserted that TLIN-000001-v0001 did not exist in production, which read
# as "this suite wrote nothing" only while the backfill was still unperformed.
# The operator approved and applied it on 2026-08-25, so absence now means the
# repair has not happened rather than that this suite behaved -- and asserting
# it would report an approved ceremony as a test failure. What this suite must
# prove is that IT wrote nothing, which is the count either side of the run.
LINEAGES_AFTER="$(count_live "${LIVE_TRUST}/lineages")"
AUDIT_AFTER="$(count_live "${LIVE_TRUST}/audit")"
if [[ "${LINEAGES_AFTER}" == "${LINEAGES_BEFORE}" && "${AUDIT_AFTER}" == "${AUDIT_BEFORE}" ]]; then
  pass "this suite added no production lineage and no production audit event"
else
  fail "this suite changed production record counts: lineages ${LINEAGES_BEFORE} -> ${LINEAGES_AFTER}, audit ${AUDIT_BEFORE} -> ${AUDIT_AFTER}"
fi
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf 'FAILED: %d check(s)\n' "${FAILURES}" >&2
  exit 1
fi
printf 'All root establishment lineage backfill checks passed.\n'
