#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for the Trust Plane runtime.
#
# v0.9.2 defined the Trust Plane and deliberately built nothing. This suite
# validates the release that makes those guarantees refusals rather than
# intentions.
#
# NOTHING HERE CONTACTS ANYTHING. Every behavioural test builds a synthetic
# trust store in a temporary directory and destroys it. No network, no SSH, no
# subprocess from library code, no Docker, no ai/.env, and no store inside the
# repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRUST="tools/trust"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_contains() {
  if [[ -f "${ROOT}/$1" ]] && grep -Eq "$2" "${ROOT}/$1"; then
    pass "$3"
  else
    fail "$3 (expected /$2/ in $1)"
  fi
}

assert_absent_in() {
  local target="$1" pattern="$2" description="$3" matches
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${target}" || true)"
  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -2 | tr '\n' ' ')"
  fi
}

# --- Required runtime modules ------------------------------------------------
for module in __init__ models errors identifiers root_authority store lineage \
              transitions scope expiry evaluator query audit cli; do
  assert_file "${TRUST}/${module}.py"
done

for document in runtime-overview root-authority-operations \
                state-transition-runtime trust-query-reference; do
  assert_file "docs/trust/${document}.md"
done
assert_file "docs/superpowers/plans/2026-08-02-trust-plane-runtime.md"

# --- The runtime reaches nothing --------------------------------------------
# A trust engine that can open a socket can be told what to trust by whatever
# answers.
assert_absent_in "${TRUST}" \
  '\b(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib|subprocess)|from[[:space:]]+(socket|requests|urllib|paramiko|subprocess)[[:space:]]+import)' \
  "the trust runtime imports no network or subprocess module"
assert_absent_in "${TRUST}" '(subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\(|\beval\(|\bexec\()' \
  "the trust runtime executes nothing"
assert_absent_in "${TRUST}" '(ssh|scp|sftp|ssh-keyscan|known_hosts)' \
  "the trust runtime performs no SSH or known_hosts operation"
assert_absent_in "${TRUST}" '(docker|podman|kubectl)' \
  "the trust runtime performs no container runtime operation"
assert_absent_in "${TRUST}" "['\"][^'\"]*ai/\\.env['\"]" \
  "the trust runtime never references ai/.env"

# --- No reasoning, no scores -------------------------------------------------
# Trust never consumes reasoning. A trust engine that asks a model what to
# trust has inverted the entire layer.
assert_absent_in "${TRUST}" \
  '(litellm|openai|anthropic|ollama|langchain|transformers|llm_|\bprompt\b)' \
  "the trust runtime consumes no model or reasoning output"
assert_absent_in "${TRUST}" \
  '(tools\.observation|tools\.experience|tools\.occurrence|tools\.integrity)' \
  "the trust runtime imports no reasoning layer"
assert_absent_in "${TRUST}" \
  '(trust_score|confidence_score|trust_level_numeric|reputation)' \
  "the trust runtime defines no trust score"

# --- No automatic trust, no recovery, no remediation ------------------------
assert_absent_in "${TRUST}" \
  '(trust_on_first_use|auto_trust|auto_enroll|auto_approve|tofu)' \
  "the trust runtime has no automatic trust path"
assert_absent_in "${TRUST}" \
  '(def[[:space:]]+(remediate|repair|restore_trust|fix)_?|auto_remediate|auto_recover)' \
  "the trust runtime has no remediation or recovery path"

# --- Identifier widths -------------------------------------------------------
for spec in "TAUTH:authority" "TREC:record" "TDEC:decision" "TSCOPE:scope" \
            "TEVID:evidence" "TAUDIT:audit"; do
  prefix="${spec%%:*}"
  assert_contains "${TRUST}/identifiers.py" "${prefix}-\[0-9\]\{6\}" \
    "identifiers define a six-digit ${prefix} pattern"
done

# --- The store is the shared one --------------------------------------------
assert_contains "${TRUST}/store.py" 'immutable_store|ImmutableStore' \
  "the trust store builds on the shared immutable store"
assert_absent_in "${TRUST}/store.py" '(os\.replace\(|shutil\.move\()' \
  "the trust store never silently replaces a record"
assert_absent_in "${TRUST}" '(def[[:space:]]+(update|delete)_[a-z_]*record|def[[:space:]]+(update|delete)\()' \
  "the trust runtime defines no update or delete method"

# --- CLI surface -------------------------------------------------------------
for forbidden in delete update restore-trust score enroll approve-all; do
  assert_absent_in "${TRUST}/cli.py" "add_parser\\([\"']${forbidden}[\"']" \
    "the CLI exposes no ${forbidden} command"
done

# --- CI and local validation wiring -----------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-trust-runtime\.sh' \
  "ci runs the trust runtime suite"
assert_contains "tools/dev/run-validation.sh" 'tests/test-trust-runtime\.sh' \
  "local validation runs the trust runtime suite"
for prefix in TAUTH TREC TDEC TSCOPE TEVID TAUDIT; do
  assert_contains "tools/dev/run-validation.sh" "${prefix}" \
    "the generated-record backstop covers ${prefix}"
done

# --- No runtime records committed -------------------------------------------
if git -C "${ROOT}" ls-files | grep -Eq '(TAUTH|TREC|TDEC|TSCOPE|TEVID|TAUDIT)-[0-9]{6}'; then
  fail "a runtime trust record is committed to the repository"
else
  pass "no runtime trust record is committed"
fi

# --- Behavioural validation --------------------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'TRUSTPY' 2>&1 || true
import json
import os
import stat
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
os.chdir(root)

failures = 0
CANARY = "CANARY-TRUST-MUST-NOT-APPEAR-4b91"


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


try:
    from tools.trust.errors import TrustError, TrustDenied, TrustStoreError
    from tools.trust.identifiers import (
        AUDIT_ID, AUTHORITY_ID, DECISION_ID, EVIDENCE_ID, RECORD_ID, SCOPE_ID,
    )
    from tools.trust.models import (
        AuthorityType, OperatorRootAuthority, TrustAuditEvent, TrustDecision,
        TrustEvidenceReference, TrustLineage, TrustRecord, TrustScope,
        TrustState, TrustVerificationDetails, VerificationMethod,
    )
    from tools.trust.store import TrustStore
    from tools.trust.root_authority import declare_root_authority, load_root_declaration
    from tools.trust import transitions as T
    from tools.trust.scope import evaluate_scope, evaluate_activity
    from tools.trust.expiry import effective_state
    from tools.trust.evaluator import create_decision
    from tools.trust import query as Q
    from tools.trust.audit import AuditEventKind
    ok("trust runtime modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"trust runtime import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

STAMP = datetime(2026, 8, 2, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
LATER = STAMP + timedelta(days=1)
YEAR = STAMP + timedelta(days=365)


def make_store(tmp):
    return TrustStore(Path(tmp) / "trust")


def evidence():
    return (TrustEvidenceReference(
        evidence_id="TEVID-000001",
        kind="fingerprint",
        reference="/approved/evidence/fingerprint.txt",
        recorded_at=STAMP,
    ),)


def details():
    return TrustVerificationDetails(
        subject_property="ssh-host-key-fingerprint",
        observed_value_reference="/approved/evidence/observed.txt",
        comparison_source="printed-console-readout",
        performed_by="operator-role-reference",
        performed_at=STAMP,
    )


def root_input():
    return {
        "display_name": "Operator Root Authority",
        "external_identity_reference": "secret-source://approved/operator-root",
        "verification_method": VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        "verification_details": {
            "subject_property": "operator-root-identity",
            "observed_value_reference": "/approved/evidence/root-observed.txt",
            "comparison_source": "in-person-verification-record",
            "performed_by": "operator-role-reference",
            "performed_at": STAMP.isoformat(),
        },
        "evidence_references": [{
            "evidence_id": "TEVID-000001",
            "kind": "attestation",
            "reference": "/approved/evidence/root-attestation.txt",
            "recorded_at": STAMP.isoformat(),
        }],
        "created_at": STAMP.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"},
    }


# --- Identifier widths -----------------------------------------------------
for pattern, prefix in ((AUTHORITY_ID, "TAUTH"), (RECORD_ID, "TREC"),
                        (DECISION_ID, "TDEC"), (SCOPE_ID, "TSCOPE"),
                        (EVIDENCE_ID, "TEVID"), (AUDIT_ID, "TAUDIT")):
    check(bool(pattern.match(f"{prefix}-000001")), f"{prefix} accepts six digits")
    check(not pattern.match(f"{prefix}-0001"), f"{prefix} refuses four digits")

# --- Model immutability and determinism ------------------------------------
scope = TrustScope(
    scope_id="TSCOPE-000001",
    subject_type="host",
    permitted_capabilities=("coding-workload",),
    permitted_operations=("linux.hostname",),
    permitted_data_classifications=("internal",),
    permitted_targets=("schmgmt.home.arpa",),
    validity_start=STAMP,
    validity_end=YEAR,
)
try:
    scope.subject_type = "model"  # type: ignore[misc]
    bad("trust models are immutable")
except Exception:
    ok("trust models are immutable")

check(scope.to_dict() == scope.to_dict(), "model serialisation is deterministic")
check(json.dumps(scope.to_dict(), sort_keys=True) ==
      json.dumps(scope.to_dict(), sort_keys=True),
      "model serialisation is stable under json encoding")

blob = json.dumps(scope.to_dict(), default=str)
for banned in ("trust_score", "score", "threshold", "reputation"):
    check(banned not in blob, f"a scope carries no {banned}")

# Timezone-naive timestamps are refused: a time without a zone is not a point
# in time, and every expiry answer depends on placing it.
try:
    TrustEvidenceReference(evidence_id="TEVID-000002", kind="fingerprint",
                           reference="/x", recorded_at=datetime(2026, 8, 2, 9, 0, 0))
    bad("a timezone-naive timestamp is refused")
except Exception:
    ok("a timezone-naive timestamp is refused")

# --- Root authority ---------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    approved = Path(tmp) / "approved"
    approved.mkdir()
    import yaml as _yaml
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()), encoding="utf-8")

    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))
    check(AUTHORITY_ID.match(authority.authority_id), "root authority gets a TAUTH identifier")
    check(authority.authority_type == AuthorityType.OPERATOR_ROOT.value,
          "root authority is of type operator-root")
    check(authority.state == TrustState.TRUSTED.value, "root authority is trusted")
    check(authority.external_identity_reference.startswith("secret-source://"),
          "root authority holds a reference, not an identity")
    check(getattr(authority, "approved_by", None) in (None, ""),
          "root authority has no approved_by pointing at itself")
    check(bool(authority.fingerprint), "root authority carries an immutable fingerprint")

    # A second active root fails closed: two roots is no root.
    try:
        declare_root_authority(store, load_root_declaration(
            "root.yaml", approved_directory=str(approved)))
        bad("a second active root authority is refused")
    except TrustError:
        ok("a second active root authority is refused")

    # Missing evidence and missing verification details are refused.
    for missing in ("evidence_references", "verification_details"):
        payload = root_input()
        payload.pop(missing)
        (approved / f"no-{missing}.yaml").write_text(_yaml.safe_dump(payload), encoding="utf-8")
        try:
            load_root_declaration(f"no-{missing}.yaml", approved_directory=str(approved))
            bad(f"a root declaration missing {missing} is refused")
        except TrustError:
            ok(f"a root declaration missing {missing} is refused")

    # Inline credential material is refused outright.
    payload = root_input()
    payload["private_key"] = CANARY
    (approved / "withkey.yaml").write_text(_yaml.safe_dump(payload), encoding="utf-8")
    try:
        load_root_declaration("withkey.yaml", approved_directory=str(approved))
        bad("a root declaration carrying credential material is refused")
    except TrustError as error:
        ok("a root declaration carrying credential material is refused")
        check(CANARY not in str(error), "the refusal never echoes the credential")

# A store inside the repository is refused by default.
try:
    TrustStore(root / "platform-model" / "trust-store")
    bad("a trust store inside the repository is refused")
except Exception:
    ok("a trust store inside the repository is refused")

# --- Store guarantees -------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    for name in ("authorities", "records", "decisions", "evidence-references",
                 "lineages", "audit", "sequences", "indexes"):
        directory = store.root / name
        check(directory.is_dir(), f"the store creates {name}/")
        check(stat.S_IMODE(directory.stat().st_mode) == 0o700,
              f"{name}/ is mode 0700")

    check(not hasattr(store, "update_record"), "the store has no update method")
    check(not hasattr(store, "delete_record"), "the store has no delete method")

    identifier = store.allocate_id("decision")
    check(DECISION_ID.match(identifier), "the store allocates six-digit decision ids")
    check(store.allocate_id("decision") != identifier, "identifiers are monotonic")

# --- State transitions ------------------------------------------------------
U, P, TR, RS, Q_, RV, EX, RJ = (
    TrustState.UNKNOWN.value, TrustState.PENDING.value, TrustState.TRUSTED.value,
    TrustState.RESTRICTED.value, TrustState.QUARANTINED.value,
    TrustState.REVOKED.value, TrustState.EXPIRED.value, TrustState.REJECTED.value)

ALLOWED_BY_DECISION = [
    (U, P), (U, TR), (U, RS), (U, Q_), (U, RJ),
    (P, TR), (P, RS), (P, Q_), (P, RJ),
    (TR, RS), (TR, Q_), (TR, RV),
    (RS, TR), (RS, Q_), (RS, RV),
    (Q_, TR), (Q_, RS), (Q_, RV), (Q_, RJ),
    # Expiry continues the lineage: renewal is a decision, not a new chain.
    (EX, TR), (EX, RS),
]
for previous, requested in ALLOWED_BY_DECISION:
    outcome = T.evaluate_transition(previous, requested, by_decision=True)
    check(outcome.allowed, f"decision transition allowed: {previous} -> {requested}")
    check(bool(outcome.governing_rule), f"{previous} -> {requested} names its governing rule")

DENIED_BY_DECISION = [(RV, TR), (RV, RS), (RJ, TR), (RJ, RS), (RV, Q_), (RJ, Q_)]
for previous, requested in DENIED_BY_DECISION:
    outcome = T.evaluate_transition(previous, requested, by_decision=True)
    check(not outcome.allowed, f"decision transition denied: {previous} -> {requested}")
    check(outcome.new_lineage_required,
          f"{previous} -> {requested} reports that a new lineage is required")

# Only expiry may be time-derived, and only from a usable state.
for previous in (TR, RS):
    outcome = T.evaluate_transition(previous, EX, by_decision=False)
    check(outcome.allowed, f"time transition allowed: {previous} -> expired")
for previous, requested in ((U, TR), (P, TR), (Q_, TR), (EX, TR), (RV, TR), (RJ, TR),
                            (TR, RS), (TR, Q_), (TR, RV)):
    outcome = T.evaluate_transition(previous, requested, by_decision=False)
    check(not outcome.allowed,
          f"automatic transition denied: {previous} -> {requested}")

# No automatic transition may ever produce a usable or judgemental state.
for requested in (TR, RS, Q_, RV, RJ):
    for previous in (U, P, TR, RS, Q_, EX):
        outcome = T.evaluate_transition(previous, requested, by_decision=False)
        check(not outcome.allowed,
              f"no automatic path to {requested} from {previous}")

check(T.is_usable(TR) and T.is_usable(RS), "trusted and restricted are usable")
for state in (U, P, Q_, RV, EX, RJ):
    check(not T.is_usable(state), f"{state} is not usable")

# --- Scope enforcement ------------------------------------------------------
def evaluation(state, scope_value=None):
    return Q.build_evaluation(subject_id="HOST-0001", stored_state=state,
                              effective_state=state, scope=scope_value,
                              lineage_id="TLIN-000001", evaluated_at=STAMP)


restricted = evaluation(RS, scope)
allowed = evaluate_scope(restricted, capability="coding-workload",
                         operation="linux.hostname", data_classification="internal",
                         target="schmgmt.home.arpa", evaluated_at=STAMP)
check(allowed.allowed, "a fully matching request inside scope is allowed")
check(allowed.effective_state == RS, "scope evaluation reports the effective state")
check(not hasattr(allowed, "score"), "scope evaluation produces no score")

for field, value in (("capability", "placement"), ("operation", "linux.uptime"),
                     ("data_classification", "restricted"), ("target", "other.invalid")):
    kwargs = dict(capability="coding-workload", operation="linux.hostname",
                  data_classification="internal", target="schmgmt.home.arpa")
    kwargs[field] = value
    denied = evaluate_scope(restricted, evaluated_at=STAMP, **kwargs)
    check(not denied.allowed, f"a request outside scope is denied: {field}={value}")
    check(bool(denied.denied_reasons), f"the {field} denial is explained")

# Deny by default: a dimension the scope does not mention is denied, not
# waved through.
for field in ("capability", "operation", "data_classification", "target"):
    kwargs = dict(capability="coding-workload", operation="linux.hostname",
                  data_classification="internal", target="schmgmt.home.arpa")
    kwargs[field] = None
    result = evaluate_scope(restricted, evaluated_at=STAMP, **kwargs)
    check(not result.allowed, f"a missing {field} is denied by default")

# Every non-usable state overrides a scope that would otherwise match.
for state in (Q_, RV, EX, RJ, U, P):
    overridden = evaluate_scope(evaluation(state, scope), capability="coding-workload",
                                operation="linux.hostname", data_classification="internal",
                                target="schmgmt.home.arpa", evaluated_at=STAMP)
    check(not overridden.allowed, f"{state} overrides a matching scope")

# Restricted with no scope dimension at all is refused.
try:
    TrustScope(scope_id="TSCOPE-000002", subject_type="host",
               permitted_capabilities=(), permitted_operations=(),
               permitted_data_classifications=(), permitted_targets=(),
               validity_start=STAMP, validity_end=YEAR).require_non_empty()
    bad("an empty restricted scope is refused")
except TrustError:
    ok("an empty restricted scope is refused")

# Wildcards are not a scope.
for wildcard in ("*", "all", "any"):
    try:
        TrustScope(scope_id="TSCOPE-000003", subject_type="host",
                   permitted_capabilities=(wildcard,), permitted_operations=(),
                   permitted_data_classifications=(), permitted_targets=(),
                   validity_start=STAMP, validity_end=YEAR)
        bad(f"a wildcard scope value is refused: {wildcard}")
    except TrustError:
        ok(f"a wildcard scope value is refused: {wildcard}")

# --- Activity and quarantine ------------------------------------------------
for state in (TR, RS):
    result = evaluate_activity(evaluation(state, scope), activity_kind="normal",
                               operation_id="linux.hostname", evaluated_at=STAMP)
    check(result.allowed, f"{state} may perform normal activity")

quarantined = evaluation(Q_, scope)
normal = evaluate_activity(quarantined, activity_kind="normal",
                           operation_id="linux.hostname", evaluated_at=STAMP)
check(not normal.allowed, "quarantined denies normal activity")
check(bool(normal.denied_reasons), "the quarantine denial is explained")

verify = evaluate_activity(quarantined, activity_kind="verification",
                           operation_id="trust.verify_identity", evaluated_at=STAMP)
check(verify.allowed, "quarantined permits an explicitly listed verification operation")
generic = evaluate_activity(quarantined, activity_kind="investigation",
                            operation_id=None, evaluated_at=STAMP)
check(not generic.allowed, "quarantined refuses a generic investigation with no operation")

for state in (U, P, RV, EX, RJ):
    for kind in ("normal", "verification", "investigation"):
        result = evaluate_activity(evaluation(state, scope), activity_kind=kind,
                                   operation_id="trust.verify_identity", evaluated_at=STAMP)
        check(not result.allowed, f"{state} denies {kind} activity")

# --- Expiry -----------------------------------------------------------------
check(effective_state(TR, expiration=YEAR, evaluated_at=STAMP) == TR,
      "before expiration the state is unchanged")
check(effective_state(TR, expiration=YEAR, evaluated_at=YEAR) == EX,
      "at expiration the effective state is expired")
check(effective_state(TR, expiration=YEAR, evaluated_at=YEAR + timedelta(days=1)) == EX,
      "after expiration the effective state is expired")
check(effective_state(TR, expiration=None, evaluated_at=YEAR) == TR,
      "with no expiration the state is unchanged")
for state in (U, P, RV, RJ):
    check(effective_state(state, expiration=YEAR, evaluated_at=YEAR) == state,
          f"expiry never rewrites {state}")

# --- Decisions, lineage, audit, and queries ---------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    approved = Path(tmp) / "approved"
    approved.mkdir()
    import yaml as _yaml
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    before = sorted(p.name for p in store.root.rglob("*") if p.is_file())

    first = create_decision(
        store,
        subject_id="HOST-0001",
        subject_type="host",
        requested_state=TR,
        actor_authority_id=authority.authority_id,
        decided_at=STAMP,
        reason="verified out of band by the operator during commissioning",
        evidence_references=evidence(),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(),
        scope=scope,
        expiration=YEAR,
    )
    check(DECISION_ID.match(first.decision.decision_id), "a decision gets a TDEC identifier")
    check(first.record.state == TR, "the decision produces a trusted record")
    check(first.lineage.current_state == TR, "the lineage records the current state")
    check(first.audit_event.event_kind == AuditEventKind.TRUST_DECISION_CREATED.value,
          "a decision emits an audit event")

    # A subject cannot approve itself.
    try:
        create_decision(store, subject_id=authority.authority_id, subject_type="user",
                        requested_state=TR, actor_authority_id=authority.authority_id,
                        decided_at=STAMP, reason="self approval attempt for testing",
                        evidence_references=evidence(),
                        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
                        verification_details=details(), scope=scope, expiration=YEAR)
        bad("a subject cannot approve itself")
    except TrustError:
        ok("a subject cannot approve itself")

    # Restricted requires a non-empty scope.
    try:
        create_decision(store, subject_id="HOST-0002", subject_type="host",
                        requested_state=RS, actor_authority_id=authority.authority_id,
                        decided_at=STAMP, reason="restricted with no scope for testing",
                        evidence_references=evidence(),
                        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
                        verification_details=details(), scope=None, expiration=YEAR)
        bad("a restricted decision with no scope is refused")
    except TrustError:
        ok("a restricted decision with no scope is refused")

    # Expiration must be in the future relative to the decision.
    try:
        create_decision(store, subject_id="HOST-0003", subject_type="host",
                        requested_state=TR, actor_authority_id=authority.authority_id,
                        decided_at=STAMP, reason="expiration already elapsed for testing",
                        evidence_references=evidence(),
                        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
                        verification_details=details(), scope=scope,
                        expiration=STAMP - timedelta(days=1))
        bad("an expiration before the decision is refused")
    except TrustError:
        ok("an expiration before the decision is refused")

    # Revoke, then prove the lineage is terminal.
    revoked = create_decision(
        store, subject_id="HOST-0001", subject_type="host", requested_state=RV,
        actor_authority_id=authority.authority_id, decided_at=LATER,
        reason="host was found compromised during a scheduled review",
        evidence_references=evidence(),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(), scope=None, expiration=None,
        revokes_record_id=first.record.record_id, lineage_id=first.lineage.lineage_id)
    check(revoked.record.state == RV, "revocation produces a revoked record")
    check(revoked.lineage.terminated, "revocation terminates the lineage")

    try:
        create_decision(store, subject_id="HOST-0001", subject_type="host",
                        requested_state=TR, actor_authority_id=authority.authority_id,
                        decided_at=LATER + timedelta(days=1),
                        reason="attempting to reactivate a revoked lineage",
                        evidence_references=evidence(),
                        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
                        verification_details=details(), scope=scope, expiration=YEAR,
                        lineage_id=first.lineage.lineage_id)
        bad("a revoked lineage cannot be reactivated")
    except TrustError:
        ok("a revoked lineage cannot be reactivated")

    # The prior record is untouched by everything that followed.
    reread = Q.get_trust_record(store, first.record.record_id)
    check(reread["state"] == TR, "the prior record remains immutable")

    # A new lineage may reference the revoked history.
    renewed = create_decision(
        store, subject_id="HOST-0001", subject_type="host", requested_state=TR,
        actor_authority_id=authority.authority_id, decided_at=LATER + timedelta(days=2),
        reason="host rebuilt and re-verified out of band after revocation",
        evidence_references=evidence(),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(), scope=scope, expiration=YEAR,
        supersedes_lineage_id=first.lineage.lineage_id)
    check(renewed.lineage.lineage_id != first.lineage.lineage_id,
          "post-revocation approval creates a new lineage")

    # Queries are read-only: no identifier consumed, no file written.
    seq_before = (store.root / "sequences" / "decision.seq").read_text()
    files_before = sorted(p.name for p in store.root.rglob("*") if p.is_file())
    current = Q.get_current_trust(store, "HOST-0001", evaluated_at=LATER + timedelta(days=3))
    history = Q.list_subject_history(store, "HOST-0001")
    files_after = sorted(p.name for p in store.root.rglob("*") if p.is_file())
    seq_after = (store.root / "sequences" / "decision.seq").read_text()
    check(files_before == files_after, "queries write nothing")
    check(seq_before == seq_after, "queries consume no identifier")
    check(current["effective_state"] == TR, "the current trust reflects the newest lineage")
    check(history == Q.list_subject_history(store, "HOST-0001"),
          "history ordering is deterministic")
    check(len(history) >= 3, "history includes every decision for the subject")

    # A missing subject fails closed rather than defaulting to anything.
    missing = Q.get_current_trust(store, "HOST-9999", evaluated_at=STAMP)
    check(missing["effective_state"] == U, "an unknown subject evaluates to unknown")
    check(not missing["usable"], "an unknown subject is not usable")

    # Store validation reports structural problems and repairs nothing.
    check(store.validate() == [], "a well-formed store validates cleanly")

    # No secret ever reaches the store, and no temp residue survives.
    store_blob = "".join(p.read_text(encoding="utf-8")
                         for p in store.root.rglob("*.yaml") if p.is_file())
    check(CANARY not in store_blob, "no canary value reaches the store")
    check(not list(store.root.rglob("*.tmp")), "no temporary residue remains")
    check(not list(store.root.rglob(".*.tmp")), "no hidden temporary residue remains")

    for path in store.root.rglob("*.yaml"):
        mode = stat.S_IMODE(path.stat().st_mode)
        check(mode == 0o600, f"{path.name} is mode 0600")
        check(not (mode & 0o077), f"{path.name} is neither group nor world readable")

# --- CLI --------------------------------------------------------------------
import subprocess  # noqa: E402 - the harness runs the CLI as a child process


def cli(*args, expect=None):
    proc = subprocess.run([sys.executable, "-m", "tools.trust.cli", *args],
                          capture_output=True, text=True, cwd=str(root),
                          env={**os.environ, "PYTHONPATH": str(root)})
    if expect is not None:
        check(proc.returncode == expect,
              f"cli {args[0] if args else ''} exits {expect} (got {proc.returncode})")
    return proc


help_proc = cli("--help")
import re as _re  # noqa: E402
choices = _re.search(r"\{([a-z,\-]+)\}", help_proc.stdout)
commands = set(choices.group(1).split(",")) if choices else set()
for command in ("init-root", "validate-store", "create-decision", "show-subject",
                "show-lineage", "evaluate", "list-history"):
    check(command in commands, f"cli exposes {command}")
for forbidden in ("delete", "update", "restore-trust", "score", "enroll"):
    check(forbidden not in commands, f"cli exposes no {forbidden} command")

# No identity may be supplied as an argument, and no store may be defaulted.
for banned in ("--identity", "--username", "--email", "--key", "--json"):
    check(banned not in help_proc.stdout, f"cli accepts no {banned} argument")

# A missing store root is an invocation error, not a default.
cli("validate-store", expect=2)

with tempfile.TemporaryDirectory() as tmp:
    store_root = Path(tmp) / "trust"
    approved = Path(tmp) / "approved"
    approved.mkdir()
    import yaml as _yaml
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()), encoding="utf-8")

    init = cli("init-root", "--store-root", str(store_root),
               "--input-file", "root.yaml",
               "--approved-directory", str(approved), expect=0)
    check(init.stdout.strip().startswith("{"), "cli emits JSON on stdout")
    check(CANARY not in init.stdout and CANARY not in init.stderr,
          "cli output carries no canary value")

    validated = cli("validate-store", "--store-root", str(store_root), expect=0)
    check(validated.stdout == cli("validate-store", "--store-root",
                                  str(store_root)).stdout,
          "cli output is deterministic")

    # An evaluation of an unknown subject denies and explains, exit 1.
    denied = cli("evaluate", "--store-root", str(store_root),
                 "--subject-id", "HOST-9999", "--activity-kind", "normal",
                 "--evaluated-at", STAMP.isoformat(), expect=1)
    check("unknown" in denied.stdout.lower(), "cli explains an unknown-subject denial")

    # A target file escaping the approved directory is refused.
    outside = Path(tmp) / "outside.yaml"
    outside.write_text(_yaml.safe_dump(root_input()), encoding="utf-8")
    (approved / "escape.yaml").symlink_to(outside)
    cli("init-root", "--store-root", str(Path(tmp) / "other"),
        "--input-file", "escape.yaml",
        "--approved-directory", str(approved), expect=2)
    ok("cli refuses an input file escaping the approved directory")

# Nothing was written inside the repository by any of the above.
check(not list((root / "tools" / "trust").glob("TAUTH-*")),
      "no runtime record was written into the source tree")

print(f"__FAILURES__={failures}")
TRUSTPY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "trust runtime behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for the trust runtime tests.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nTrust runtime validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nTrust runtime validation passed.\n'
