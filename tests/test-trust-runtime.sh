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
# Matched against SSH *operations and configuration*, not the vocabulary:
# from v0.9.4 the package names ADR-0011's 'ssh-host-key' domain, and a pattern
# that flagged the domain name would punish the model for using the ADR's own
# words.
assert_absent_in "${TRUST}" \
  '(ssh-keyscan|ssh-copy-id|StrictHostKeyChecking|known_hosts|["'"'"']ssh["'"'"']|subprocess[^\n]*ssh)' \
  "the trust runtime performs no SSH or known_hosts operation"
assert_absent_in "${TRUST}" '(docker|podman|kubectl)' \
  "the trust runtime performs no container runtime operation"
assert_absent_in "${TRUST}" "['\"][^'\"]*ai/\\.env['\"]" \
  "the trust runtime never references ai/.env"

# --- No reasoning, no scores -------------------------------------------------
# Trust never consumes reasoning. A trust engine that asks a model what to
# trust has inverted the entire layer.
# Matched against model *clients and calls*, not the word: these modules
# describe what they refuse, and a pattern that flagged the description would
# punish the documentation for being explicit.
assert_absent_in "${TRUST}" \
  '(litellm|openai|anthropic|ollama|langchain|transformers|llm_client|system_prompt|prompt_template|chat\.completions)' \
  "the trust runtime consumes no model or reasoning output"
assert_absent_in "${TRUST}" \
  '(tools\.observation|tools\.experience|tools\.occurrence|tools\.integrity)' \
  "the trust runtime imports no reasoning layer"
# Naming these in a deny-list is the mechanism, not a violation. What must
# not exist is a score being assigned, read, or returned.
assert_absent_in "${TRUST}" \
  '((trust_score|confidence_score|trust_level_numeric|reputation)[[:space:]]*=[^=]|\.(trust_score|confidence_score|reputation)\b|return[[:space:]]+.*trust_score)' \
  "the trust runtime computes no trust score"

# --- No automatic trust, no recovery, no remediation ------------------------
assert_absent_in "${TRUST}" \
  '((trust_on_first_use|auto_trust|auto_enroll|auto_approve)[[:space:]]*=[^=]|def[[:space:]]+(auto_trust|auto_enroll|auto_approve))' \
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

# --- ENG-0001: the root establishment lineage is a separate record type ------
# ADR-0014. Asserted statically as well as behaviourally because the decision
# that matters is structural: the decision fields must be absent from the model,
# not merely unset on it.
assert_contains "${TRUST}/models.py" 'class RootAuthorityLineage' \
  "models define a dedicated root establishment lineage"
for discriminator in 'LINEAGE_TYPE_SUBJECT_DECISION' 'LINEAGE_TYPE_ROOT_ESTABLISHMENT' \
                     'EXTERNAL_OPERATOR_CEREMONY'; do
  assert_contains "${TRUST}/models.py" "${discriminator}" \
    "models define ${discriminator}"
done
assert_contains "${TRUST}/models.py" 'def lineage_type_of' \
  "models discriminate lineage records on a recorded kind"
assert_contains "${TRUST}/models.py" 'def validate_root_lineage_record' \
  "models validate a stored root establishment lineage"
assert_contains "${TRUST}/root_authority.py" 'RootAuthorityLineage' \
  "root declaration persists a root establishment lineage"
assert_contains "${TRUST}/root_authority.py" 'store.write\("lineage", lineage\)' \
  "root declaration writes the lineage through the immutable write path"
assert_absent_in "${TRUST}/root_authority.py" 'allocate_id\("decision"\)' \
  "root declaration allocates no decision identifier"
assert_contains "${TRUST}/lineage.py" 'lineage_type_of' \
  "lineage readers discriminate on the recorded lineage type"
assert_contains "${TRUST}/store.py" 'validate_root_lineage_record' \
  "store validation checks the authority lineage reference"
# Reporting is not repairing: the validator must not gain a write path.
assert_absent_in "${TRUST}/store.py" 'def (repair|backfill|fix)' \
  "store validation defines no repair or backfill method"

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
import hashlib
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


def evidence(store):
    # The next free identity, which is what an operator cites now that a
    # supplied evidence identity is carried rather than re-labelled by the
    # store. A fixed id would be a citation of evidence that already means
    # something else the moment a second decision is made.
    return (TrustEvidenceReference(
        evidence_id=store.peek_next_id("evidence"),
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

# --- ENG-0001: the root establishment lineage -------------------------------
# ADR-0014. A root is established outside the platform by a ceremony; nothing
# decided it. TrustLineage records a chain of decisions and requires two TDEC
# identifiers, so it cannot describe a root without fabricating an approval
# that never happened. A dedicated record type carries no decision fields at
# all.
#
# Imported here rather than at the top so a missing model reports as one
# precise failure instead of collapsing every suite above it.
try:
    from tools.trust.models import (
        EXTERNAL_OPERATOR_CEREMONY,
        LINEAGE_TYPE_ROOT_ESTABLISHMENT,
        LINEAGE_TYPE_SUBJECT_DECISION,
        RootAuthorityLineage,
        lineage_type_of,
        validate_root_lineage_record,
    )
    ROOT_LINEAGE_MODEL = True
    ok("ENG-0001: the root establishment lineage model is importable")
except Exception as error:  # noqa: BLE001
    ROOT_LINEAGE_MODEL = False
    bad(f"ENG-0001: the root establishment lineage model is importable "
        f"({type(error).__name__}: {error})")


def root_lineage(**overrides):
    payload = dict(
        lineage_id="TLIN-000001",
        version=1,
        authority_id="TAUTH-000001",
        subject_type="operator-root",
        establishment_origin=EXTERNAL_OPERATOR_CEREMONY,
        evidence_reference_ids=("TEVID-000001",),
        establishment_audit_id="TAUDIT-000001",
        current_state=TrustState.TRUSTED.value,
        established_at=STAMP,
        recorded_at=STAMP,
    )
    payload.update(overrides)
    return RootAuthorityLineage(**payload)


if ROOT_LINEAGE_MODEL:
    # 1. A specification-compliant record is accepted.
    try:
        lineage = root_lineage()
        ok("ENG-0001: RootAuthorityLineage accepts a specification-compliant record")
        check(lineage.lineage_type == LINEAGE_TYPE_ROOT_ESTABLISHMENT,
              "ENG-0001: its discriminator is root-establishment")
        check(lineage.id == "TLIN-000001-v0001",
              "ENG-0001: it is stored as the versioned lineage identifier")
        stored = lineage.to_dict()
        check(stored.get("lineage_type") == LINEAGE_TYPE_ROOT_ESTABLISHMENT,
              "ENG-0001: the stored record carries its discriminator")
        check(stored.get("establishment_origin") == EXTERNAL_OPERATOR_CEREMONY,
              "ENG-0001: the stored record names an external ceremony origin")
    except Exception as error:  # noqa: BLE001
        bad(f"ENG-0001: RootAuthorityLineage accepts a specification-compliant "
            f"record ({type(error).__name__}: {error})")

    # 2. Every forbidden decision or approval field is absent from the model,
    #    not merely nullable on it, so no code path can populate one.
    for forbidden in ("first_decision_id", "current_decision_id",
                      "prior_decision_ids", "root_authority_id",
                      "approved_by", "approval_source"):
        try:
            root_lineage(**{forbidden: "TDEC-000001"})
            bad(f"ENG-0001: RootAuthorityLineage rejects the forbidden field {forbidden}")
        except TypeError:
            ok(f"ENG-0001: RootAuthorityLineage rejects the forbidden field {forbidden}")
        except Exception as error:  # noqa: BLE001
            bad(f"ENG-0001: RootAuthorityLineage rejects the forbidden field "
                f"{forbidden} ({type(error).__name__}: {error})")
        check(forbidden not in root_lineage().to_dict(),
              f"ENG-0001: the stored root lineage omits {forbidden}")

    # A stored record carrying a forbidden or unknown field is refused on read.
    for bogus in ("first_decision_id", "current_decision_id", "prior_decision_ids",
                  "root_authority_id", "approved_by", "approval_source",
                  "trust_score", "unknown_field"):
        payload = root_lineage().to_dict()
        payload[bogus] = "TDEC-000001"
        try:
            validate_root_lineage_record(payload, "stored root lineage")
            bad(f"ENG-0001: a stored root lineage carrying {bogus} is refused")
        except TrustError:
            ok(f"ENG-0001: a stored root lineage carrying {bogus} is refused")

    # Stored values are validated, not just stored field names. A record whose
    # keys are all correct and whose values are all nonsense must not satisfy
    # the authority-to-lineage rule: TrustStore.validate() relies on this
    # function, so a name-only check lets malformed data prove a root was
    # established.
    def stored_root_lineage(**overrides):
        payload = root_lineage().to_dict()
        payload.update(overrides)
        return payload

    reviewer_record = {
        "id": "whatever",
        "lineage_type": LINEAGE_TYPE_ROOT_ESTABLISHMENT,
        "lineage_id": "NOT-A-TLIN",
        "version": 0,
        "authority_id": "NOT-A-TAUTH",
        "subject_type": "anything",
        "establishment_origin": "invented",
        "evidence_reference_ids": ["garbage"],
        "establishment_audit_id": "garbage",
        "current_state": "revoked",
        "established_at": "not-a-time",
        "recorded_at": "not-a-time",
        "terminated": "not-a-bool",
    }

    for label, payload in (
        ("every value malformed", reviewer_record),
        ("a malformed lineage_id", stored_root_lineage(lineage_id="NOT-A-TLIN")),
        ("an id inconsistent with its version",
         stored_root_lineage(id="TLIN-000001-v0009")),
        ("a malformed versioned id", stored_root_lineage(id="garbage")),
        ("version 0", stored_root_lineage(version=0, id="TLIN-000001-v0000")),
        ("version above 1", stored_root_lineage(version=2, id="TLIN-000001-v0002")),
        ("a non-integer version", stored_root_lineage(version="1")),
        ("a boolean version", stored_root_lineage(version=True)),
        ("a malformed authority_id", stored_root_lineage(authority_id="NOT-A-TAUTH")),
        ("a subject_type other than operator-root",
         stored_root_lineage(subject_type="host")),
        ("an unknown establishment_origin",
         stored_root_lineage(establishment_origin="invented")),
        ("empty evidence_reference_ids", stored_root_lineage(evidence_reference_ids=[])),
        ("malformed evidence_reference_ids",
         stored_root_lineage(evidence_reference_ids=["garbage"])),
        ("evidence_reference_ids that is not a list",
         stored_root_lineage(evidence_reference_ids="TEVID-000001")),
        # A stored record comes from YAML, where a sequence loads as a list. A
        # tuple is a non-list, so accepting one would mean the stored-record
        # boundary was not actually checking the stored shape.
        ("evidence_reference_ids stored as a tuple",
         stored_root_lineage(evidence_reference_ids=("TEVID-000001",))),
        ("evidence_reference_ids stored as a mapping",
         stored_root_lineage(evidence_reference_ids={"0": "TEVID-000001"})),
        ("a malformed establishment_audit_id",
         stored_root_lineage(establishment_audit_id="garbage")),
        ("a state other than trusted", stored_root_lineage(current_state="revoked")),
        ("a state of unknown", stored_root_lineage(current_state="unknown")),
        ("an unparseable established_at", stored_root_lineage(established_at="not-a-time")),
        ("a timezone-naive established_at",
         stored_root_lineage(established_at="2026-08-03T22:00:06")),
        ("a timezone-naive recorded_at",
         stored_root_lineage(recorded_at="2026-08-03T22:00:06")),
        ("a non-string established_at", stored_root_lineage(established_at=12345)),
        ("a null recorded_at", stored_root_lineage(recorded_at=None)),
        ("a non-boolean terminated", stored_root_lineage(terminated="not-a-bool")),
        ("terminated true, because advancement is undefined",
         stored_root_lineage(terminated=True)),
    ):
        try:
            validate_root_lineage_record(payload, "stored root lineage")
            bad(f"ENG-0001: a stored root lineage with {label} is refused")
        except TrustError:
            ok(f"ENG-0001: a stored root lineage with {label} is refused")
        except Exception as error:  # noqa: BLE001
            bad(f"ENG-0001: a stored root lineage with {label} is refused as a "
                f"TrustError, not {type(error).__name__}: {error}")

    # A record that is not a mapping at all must refuse rather than raise.
    for label, payload in (("a list", []), ("a string", "root"), ("null", None)):
        try:
            validate_root_lineage_record(payload, "stored root lineage")
            bad(f"ENG-0001: a stored root lineage that is {label} is refused")
        except TrustError:
            ok(f"ENG-0001: a stored root lineage that is {label} is refused")
        except Exception as error:  # noqa: BLE001
            bad(f"ENG-0001: a stored root lineage that is {label} is refused as a "
                f"TrustError, not {type(error).__name__}: {error}")

    # The valid record still passes, and validation returns the reconstructed
    # record so callers compare parsed values rather than raw strings.
    try:
        parsed = validate_root_lineage_record(root_lineage().to_dict(), "stored")
        ok("ENG-0001: a specification-compliant stored record still validates")
        check(getattr(parsed, "authority_id", None) == "TAUTH-000001",
              "ENG-0001: validation returns the reconstructed root lineage")
    except Exception as error:  # noqa: BLE001
        bad(f"ENG-0001: a specification-compliant stored record still validates "
            f"({type(error).__name__}: {error})")

    # 2b. The model itself enforces the contract, so no caller can build one.
    for label, overrides in (
        ("version 0", {"version": 0}),
        ("version above 1, because advancement is undefined", {"version": 2}),
        ("a subject_type other than operator-root", {"subject_type": "host"}),
        ("terminated true", {"terminated": True}),
        ("a non-boolean terminated", {"terminated": "yes"}),
    ):
        try:
            root_lineage(**overrides)
            bad(f"ENG-0001: RootAuthorityLineage refuses {label}")
        except TrustError:
            ok(f"ENG-0001: RootAuthorityLineage refuses {label}")
        except Exception as error:  # noqa: BLE001
            bad(f"ENG-0001: RootAuthorityLineage refuses {label} as a TrustError, "
                f"not {type(error).__name__}: {error}")

    # 3. Missing or unknown discriminator values fail closed.
    for label, payload in (
        ("missing", {k: v for k, v in root_lineage().to_dict().items()
                     if k != "lineage_type"}),
        ("empty", {**root_lineage().to_dict(), "lineage_type": ""}),
        ("unknown", {**root_lineage().to_dict(), "lineage_type": "invented"}),
    ):
        try:
            lineage_type_of(payload, "lineage record")
            bad(f"ENG-0001: a {label} lineage_type fails closed")
        except TrustError:
            ok(f"ENG-0001: a {label} lineage_type fails closed")

    # An origin the platform could assert about itself is not an external one.
    for rejected in ("", "platform-generated", "self-established"):
        try:
            root_lineage(establishment_origin=rejected)
            bad(f"ENG-0001: establishment_origin '{rejected}' is refused")
        except TrustError:
            ok(f"ENG-0001: establishment_origin '{rejected}' is refused")

    # 4. TrustLineage is unchanged: it still demands both decision identifiers.
    def subject_lineage(**overrides):
        payload = dict(
            lineage_id="TLIN-000002", version=1, subject_id="HOST-0001",
            subject_type="host", root_authority_id="TAUTH-000001",
            first_decision_id="TDEC-000001", current_decision_id="TDEC-000001",
            prior_decision_ids=(), current_state=TrustState.TRUSTED.value,
            created_at=STAMP, last_changed_at=STAMP,
        )
        payload.update(overrides)
        return TrustLineage(**payload)

    check(subject_lineage().lineage_type == LINEAGE_TYPE_SUBJECT_DECISION,
          "ENG-0001: TrustLineage still discriminates as subject-decision")
    check(subject_lineage().to_dict().get("lineage_type") == LINEAGE_TYPE_SUBJECT_DECISION,
          "ENG-0001: a stored subject lineage carries its discriminator")
    for field_name in ("first_decision_id", "current_decision_id"):
        for invalid in ("", "TAUTH-000001", "TLIN-000001"):
            try:
                subject_lineage(**{field_name: invalid})
                bad(f"ENG-0001: TrustLineage still refuses {field_name}='{invalid}'")
            except TrustError:
                ok(f"ENG-0001: TrustLineage still refuses {field_name}='{invalid}'")

# 5-9. A successful root declaration persists exactly one root-establishment
#      lineage, reusing the identifier it already allocated.
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    approved = Path(tmp) / "approved"
    approved.mkdir()
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    lineages = store.all_records("lineage")
    check(len(lineages) == 1,
          f"ENG-0001: root declaration persists exactly one lineage record (got {len(lineages)})")
    stored = lineages[0] if lineages else {}
    check(stored.get("lineage_type") == "root-establishment",
          "ENG-0001: the persisted lineage is a root-establishment lineage")
    check(stored.get("lineage_id") == authority.lineage_id,
          "ENG-0001: the persisted lineage reuses the allocated TLIN identifier")
    check(stored.get("id") == f"{authority.lineage_id}-v0001",
          "ENG-0001: the persisted lineage is version 1")
    check(stored.get("authority_id") == authority.authority_id,
          "ENG-0001: the persisted lineage names the established authority")
    check(stored.get("establishment_origin") == "external-operator-ceremony",
          "ENG-0001: the persisted lineage records an external ceremony origin")
    check(stored.get("current_state") == TrustState.TRUSTED.value,
          "ENG-0001: the persisted lineage is trusted")
    check(stored.get("subject_type") == AuthorityType.OPERATOR_ROOT.value,
          "ENG-0001: the persisted lineage names the operator-root subject type")

    # 7. No synthetic decision is created, read, or implied.
    check(store.all_records("decision") == [],
          "ENG-0001: root establishment creates no TDEC")
    check(not (store.root / "sequences" / "decision.seq").exists(),
          "ENG-0001: root establishment allocates no decision identifier")
    for forbidden in ("first_decision_id", "current_decision_id",
                      "prior_decision_ids", "root_authority_id",
                      "approved_by", "approval_source"):
        check(forbidden not in stored,
              f"ENG-0001: the persisted root lineage omits {forbidden}")

    # 8. Exactly one TLIN identifier is allocated for the declaration.
    sequence = (store.root / "sequences" / "lineage.seq").read_text(encoding="utf-8").strip()
    check(sequence == "1",
          f"ENG-0001: exactly one TLIN identifier is allocated (sequence={sequence})")

    # 9. Authority, lineage, evidence, and audit all agree.
    evidence_ids = {record.get("evidence_id") for record in store.all_records("evidence")}
    check(set(stored.get("evidence_reference_ids") or ()) == evidence_ids,
          "ENG-0001: the lineage cites exactly the ceremony evidence records")
    audits = store.all_records("audit")
    check(len(audits) == 1, "ENG-0001: root declaration writes one audit event")
    if audits:
        check(stored.get("establishment_audit_id") == audits[0].get("audit_id"),
              "ENG-0001: the lineage names the root-establishment audit event")
        check(audits[0].get("lineage_id") == authority.lineage_id,
              "ENG-0001: the audit event and the lineage agree on the lineage identifier")

    # 12. A valid authority/root-lineage relationship validates clean.
    problems = store.validate()
    check(problems == [],
          f"ENG-0001: validate-store accepts a valid authority/root-lineage pair ({problems})")

# 10. A refused declaration leaves no misleading record behind.
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    rejected = dict(root_input())
    rejected["verification_method"] = "invented-method"
    try:
        declare_root_authority(store, rejected)
        bad("ENG-0001: a declaration with an unrecognised verification method is refused")
    except TrustError:
        ok("ENG-0001: a declaration with an unrecognised verification method is refused")
    check(store.all_records("lineage") == [],
          "ENG-0001: a refused declaration leaves no lineage record")
    check(store.all_records("authority") == [],
          "ENG-0001: a refused declaration leaves no authority record")
    check(store.all_records("audit") == [],
          "ENG-0001: a refused declaration leaves no audit event")

# 11, 13, 14. The validator reports authority/lineage disagreement and writes
#             nothing while doing it.
def orphan_authority(store):
    return OperatorRootAuthority(
        authority_id=store.allocate_id("authority"),
        authority_type=AuthorityType.OPERATOR_ROOT.value,
        display_name="Operator Root Authority",
        external_identity_reference="secret-source://approved/operator-root",
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(),
        evidence_references=evidence(store),
        created_at=STAMP,
        provenance={"class": "declared", "source": "operator-out-of-band"},
        state=TrustState.TRUSTED.value,
        lineage_id=store.allocate_id("lineage"),
    )


with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    store.write("authority", orphan_authority(store))
    problems = store.validate()
    check(any("lineage" in problem for problem in problems),
          f"ENG-0001: validate-store reports an authority whose lineage is missing ({problems})")

    # 14. Reporting is not repairing.
    before = sorted((p, p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
                    for p in store.root.rglob("*") if p.is_file())
    store.validate()
    after = sorted((p, p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
                   for p in store.root.rglob("*") if p.is_file())
    check(before == after, "ENG-0001: validate-store repairs, writes, and allocates nothing")
    check(store.all_records("lineage") == [],
          "ENG-0001: validate-store does not backfill the missing lineage")

with tempfile.TemporaryDirectory() as tmp:
    # A subject-decision lineage cannot stand in for a root establishment.
    store = make_store(tmp)
    authority = orphan_authority(store)
    store.write("authority", authority)
    store.write("lineage", TrustLineage(
        lineage_id=authority.lineage_id, version=1,
        subject_id=authority.authority_id, subject_type="operator-root",
        root_authority_id=authority.authority_id,
        first_decision_id="TDEC-000001", current_decision_id="TDEC-000001",
        prior_decision_ids=(), current_state=TrustState.TRUSTED.value,
        created_at=STAMP, last_changed_at=STAMP,
    ))
    problems = store.validate()
    check(any("lineage" in problem for problem in problems),
          f"ENG-0001: validate-store refuses a subject-decision lineage for an authority ({problems})")

with tempfile.TemporaryDirectory() as tmp:
    # A root lineage naming a different authority is a mismatch, not a match.
    store = make_store(tmp)
    authority = orphan_authority(store)
    store.write("authority", authority)
    if ROOT_LINEAGE_MODEL:
        store.write("lineage", root_lineage(
            lineage_id=authority.lineage_id,
            authority_id="TAUTH-999999",
        ))
        problems = store.validate()
        check(any("TAUTH-999999" in problem for problem in problems),
              f"ENG-0001: validate-store refuses a root lineage naming another authority ({problems})")

with tempfile.TemporaryDirectory() as tmp:
    # A stored record whose field names are right and whose values are all
    # nonsense must produce a finding, not satisfy the rule and not crash the
    # validator. This is the path a name-only check left open.
    store = make_store(tmp)
    authority = orphan_authority(store)
    store.write("authority", authority)
    malformed = {
        "id": "whatever",
        "lineage_type": "root-establishment",
        "lineage_id": "NOT-A-TLIN",
        "version": 0,
        "authority_id": "NOT-A-TAUTH",
        "subject_type": "anything",
        "establishment_origin": "invented",
        "evidence_reference_ids": ["garbage"],
        "establishment_audit_id": "garbage",
        "current_state": "revoked",
        "established_at": "not-a-time",
        "recorded_at": "not-a-time",
        "terminated": "not-a-bool",
    }
    store.write_atomic(
        store.path_for("lineage", f"{authority.lineage_id}-v0001"), malformed)
    before = sorted((p, hashlib.sha256(p.read_bytes()).hexdigest())
                    for p in store.root.rglob("*") if p.is_file())
    try:
        problems = store.validate()
        ok("ENG-0001: validate-store reports a malformed root lineage rather than crashing")
        check(any("lineage" in problem for problem in problems),
              f"ENG-0001: a malformed stored root lineage produces a finding ({problems})")
    except Exception as error:  # noqa: BLE001
        bad(f"ENG-0001: validate-store reports a malformed root lineage rather than "
            f"crashing ({type(error).__name__}: {error})")
    after = sorted((p, hashlib.sha256(p.read_bytes()).hexdigest())
                   for p in store.root.rglob("*") if p.is_file())
    check(before == after,
          "ENG-0001: reporting a malformed root lineage mutates and repairs nothing")

    # Deterministic: the same malformed record reports the same finding.
    check(store.validate() == store.validate(),
          "ENG-0001: malformed-record findings are deterministic")

if ROOT_LINEAGE_MODEL:
    with tempfile.TemporaryDirectory() as tmp:
        # Assert the complete TrustStore.validate() finding, not just that the
        # helper raised. The helper already prefixes its message with the record
        # identifier, so a store that prefixes it again names the same record
        # twice in one line.
        store = make_store(tmp)
        authority = orphan_authority(store)
        store.write("authority", authority)
        record_id = f"{authority.lineage_id}-v0001"
        malformed = root_lineage(
            lineage_id=authority.lineage_id,
            authority_id=authority.authority_id,
        ).to_dict()
        malformed["established_at"] = "not-a-time"
        store.write_atomic(store.path_for("lineage", record_id), malformed)

        problems = store.validate()
        check(len(problems) == 1,
              f"ENG-0001: a malformed root lineage produces exactly one finding ({problems})")
        finding = problems[0] if problems else ""
        check(finding.count(record_id) == 1,
              f"ENG-0001: the finding names the lineage record exactly once ({finding})")
        check(finding.count(authority.authority_id) == 1,
              f"ENG-0001: the finding names the authority exactly once ({finding})")
        check("established_at" in finding,
              f"ENG-0001: the finding names the malformed field ({finding})")
        check(finding.startswith(f"{authority.authority_id}: {record_id}: "),
              f"ENG-0001: the finding reads authority, record, reason ({finding})")

    with tempfile.TemporaryDirectory() as tmp:
        # The same single-occurrence rule for the mismatched-authority finding.
        store = make_store(tmp)
        authority = orphan_authority(store)
        store.write("authority", authority)
        record_id = f"{authority.lineage_id}-v0001"
        store.write("lineage", root_lineage(
            lineage_id=authority.lineage_id, authority_id="TAUTH-999999"))
        problems = store.validate()
        finding = problems[0] if problems else ""
        check(len(problems) == 1,
              f"ENG-0001: a mismatched authority produces exactly one finding ({problems})")
        check(finding.count(record_id) == 1,
              f"ENG-0001: the mismatch finding names the lineage record exactly once ({finding})")
        check("TAUTH-999999" in finding,
              f"ENG-0001: the mismatch finding names the authority it points at ({finding})")

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
    # An expired grant was granted. It must still be withdrawable and still be
    # quarantinable: a lapsed subject that turns out to be compromised cannot
    # be made to require renewal-into-trust before it can be revoked.
    (EX, RV), (EX, Q_),
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
# Rejected means trust was never granted. An expired grant was granted, so
# rejecting it would blur the one distinction the ADR is emphatic about.
rejected_after_expiry = T.evaluate_transition(EX, RJ, by_decision=True)
check(not rejected_after_expiry.allowed,
      "an expired grant cannot be rejected; rejection means trust was never granted")
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

# --- Renewal after expiry, through create_decision --------------------------
# Regression: the pure expiry function is not enough. A decision derives its
# previous state from the lineage, and if it reads the *stored* state rather
# than the effective one, `expired` can never be a previous state and renewal
# is unreachable -- even though the transition table permits it.
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    approved = Path(tmp) / "approved"
    approved.mkdir()
    import yaml as _yaml
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    SHORT = STAMP + timedelta(days=2)
    AFTER = STAMP + timedelta(days=3)
    granted = create_decision(
        store, subject_id="HOST-EXP", subject_type="host", requested_state=TR,
        actor_authority_id=authority.authority_id, decided_at=STAMP,
        reason="granted with a short expiration for the renewal regression",
        evidence_references=evidence(store),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(), scope=scope, expiration=SHORT)

    lapsed = Q.get_current_trust(store, "HOST-EXP", evaluated_at=AFTER)
    check(lapsed["stored_state"] == TR and lapsed["effective_state"] == EX,
          "after the boundary the stored state is trusted and the effective state expired")
    check(not lapsed["usable"], "an effectively expired subject is not usable")

    renewed = create_decision(
        store, subject_id="HOST-EXP", subject_type="host", requested_state=TR,
        actor_authority_id=authority.authority_id, decided_at=AFTER,
        reason="renewed by explicit decision after the grant elapsed",
        evidence_references=evidence(store),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(), scope=scope,
        expiration=AFTER + timedelta(days=365),
        lineage_id=granted.lineage.lineage_id)
    check(renewed.lineage.lineage_id == granted.lineage.lineage_id,
          "renewal after expiry continues the same lineage")
    check(renewed.decision.previous_state == EX,
          "the renewal decision records the effective previous state, not the stored one")
    check(renewed.lineage.version == granted.lineage.version + 1,
          "the lineage advanced by a new version rather than an edit")
    check(Q.get_trust_record(store, granted.record.record_id)["state"] == TR,
          "the elapsed record is untouched by the renewal")

# --- Revoking a grant that has already lapsed -------------------------------
# Regression: before the previous-state fix this worked only because expiry was
# invisible to the evaluator. It must keep working now that expiry is visible.
with tempfile.TemporaryDirectory() as tmp:
    store = make_store(tmp)
    approved = Path(tmp) / "approved"
    approved.mkdir()
    import yaml as _yaml
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    SHORT = STAMP + timedelta(days=1)
    LATE = STAMP + timedelta(days=400)
    lapsed_grant = create_decision(
        store, subject_id="HOST-LAPSE", subject_type="host", requested_state=TR,
        actor_authority_id=authority.authority_id, decided_at=STAMP,
        reason="granted with a short expiration for the revocation regression",
        evidence_references=evidence(store),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(), scope=scope, expiration=SHORT)

    withdrawn = create_decision(
        store, subject_id="HOST-LAPSE", subject_type="host", requested_state=RV,
        actor_authority_id=authority.authority_id, decided_at=LATE,
        reason="the lapsed grant was found compromised and is withdrawn",
        evidence_references=evidence(store),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=details(), scope=None, expiration=None,
        revokes_record_id=lapsed_grant.record.record_id,
        lineage_id=lapsed_grant.lineage.lineage_id)
    check(withdrawn.record.state == RV,
          "a grant that already lapsed can still be revoked")
    check(withdrawn.decision.previous_state == EX,
          "the revocation records that the previous state was effectively expired")
    check(withdrawn.lineage.terminated, "revoking a lapsed grant terminates the lineage")

    # And the lineage stays terminal however much time passes afterwards.
    try:
        create_decision(
            store, subject_id="HOST-LAPSE", subject_type="host", requested_state=TR,
            actor_authority_id=authority.authority_id, decided_at=LATE + timedelta(days=10),
            reason="attempting to revive a long-revoked lapsed lineage",
            evidence_references=evidence(store),
            verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
            verification_details=details(), scope=scope, expiration=LATE + timedelta(days=800),
            lineage_id=lapsed_grant.lineage.lineage_id)
        bad("a revoked lineage stays terminal however much time passes")
    except TrustError:
        ok("a revoked lineage stays terminal however much time passes")

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
        evidence_references=evidence(store),
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
                        evidence_references=evidence(store),
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
                        evidence_references=evidence(store),
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
                        evidence_references=evidence(store),
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
        evidence_references=evidence(store),
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
                        evidence_references=evidence(store),
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
        evidence_references=evidence(store),
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

# --- ENG-0002: validate-store performs no filesystem mutation ---------------
# The command's entire job is to report what is on disk. A validator that
# creates the store root, its record directories, or a sequence file has
# changed the thing it was asked to describe, and its "valid" verdict is then
# partly a description of its own side effects.


def snapshot(path):
    """Every path beneath `path`, with the metadata a mutation would disturb."""
    entries = []
    if not path.exists():
        return entries
    for item in sorted(path.rglob("*")):
        info = item.lstat()
        digest = ""
        if item.is_file() and not item.is_symlink():
            digest = hashlib.sha256(item.read_bytes()).hexdigest()
        entries.append((str(item.relative_to(path)), info.st_mode, info.st_size,
                        info.st_mtime_ns, digest))
    return entries


# An absent store root must stay absent. Validation reports; it does not
# provision.
with tempfile.TemporaryDirectory() as tmp:
    parent = Path(tmp) / "parent"
    parent.mkdir()
    absent = parent / "no-store-here"

    before = snapshot(parent)
    cli("validate-store", "--store-root", str(absent))
    after = snapshot(parent)

    check(not absent.exists(),
          "ENG-0002: validate-store does not create an absent store root")
    check(before == after,
          "ENG-0002: validate-store leaves an absent root's parent untouched")


def unchanged_by_validation(label, store_root, expect):
    """Validate twice; require identical filesystem state and identical output."""
    before = snapshot(store_root)
    first = cli("validate-store", "--store-root", str(store_root), expect=expect)
    between = snapshot(store_root)
    second = cli("validate-store", "--store-root", str(store_root), expect=expect)
    after = snapshot(store_root)

    check(before == between,
          f"ENG-0002: validate-store mutates nothing in a {label} store")
    check(between == after,
          f"ENG-0002: revalidating a {label} store mutates nothing")
    check(first.stdout == second.stdout,
          f"ENG-0002: repeated validation of a {label} store is identical")


# An empty directory is a store with nothing in it, not an invitation to build
# one. No record directories, no sequences, no indexes.
with tempfile.TemporaryDirectory() as tmp:
    empty = Path(tmp) / "empty"
    empty.mkdir()
    unchanged_by_validation("empty", empty, 0)
    check(snapshot(empty) == [],
          "ENG-0002: validate-store creates no directory inside an empty store")

# A populated, valid store: exit 0 preserved, every byte and mode preserved.
with tempfile.TemporaryDirectory() as tmp:
    store_root = Path(tmp) / "trust"
    approved = Path(tmp) / "approved"
    approved.mkdir()
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()), encoding="utf-8")
    cli("init-root", "--store-root", str(store_root), "--input-file", "root.yaml",
        "--approved-directory", str(approved), expect=0)
    unchanged_by_validation("valid", store_root, 0)

# A malformed store still reports exit 1, and is not tidied up on the way past.
with tempfile.TemporaryDirectory() as tmp:
    malformed = Path(tmp) / "malformed"
    (malformed / "authorities").mkdir(parents=True)
    (malformed / "authorities" / "TAUTH-000009.yaml").write_text(
        "this file is not a record mapping\n", encoding="utf-8")
    unchanged_by_validation("malformed", malformed, 1)
    check(not (malformed / "sequences").exists(),
          "ENG-0002: validate-store creates no sequence directory in a malformed store")
    check(sorted(p.name for p in malformed.iterdir()) == ["authorities"],
          "ENG-0002: validate-store adds no record directory to a malformed store")

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
