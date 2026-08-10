#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the v0.9.4 trust mechanism migration.
#
# The platform had trust decisions scattered across the layers that happened to
# need them. This suite validates the release that gives them one decision
# point: tools/trust/gateway.py.
#
# Two things are asserted throughout, and they pull in opposite directions:
#
#   1. There is now exactly ONE place any authorization decision is made.
#   2. Every allow and every deny is the SAME as before the migration.
#
# The second is what makes the first safe. A migration that centralises
# decisions and changes any of them is not a migration, it is a rewrite.
#
# Nothing here contacts a host, reads a credential, or writes into the
# repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
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

# --- Required artefacts ------------------------------------------------------
assert_file "tools/trust/gateway.py"
assert_file "tools/trust/policy.py"
assert_file "docs/trust/trust-migration.md"
assert_file "docs/superpowers/plans/2026-08-03-trust-mechanism-migration.md"

# --- Exactly one decision point ---------------------------------------------
# Every migrated call site asks the gateway. If a second module starts deciding
# on its own, this is what catches it.
for site in tools/collectors/remote/plugin.py tools/collectors/registry.py \
            tools/collectors/models.py tools/collectors/remote/command_catalog.py; do
  assert_contains "${site}" '(trust\.gateway|from[[:space:]]+\.\.trust|from[[:space:]]+\.trust|trust_gateway|gateway\.)' \
    "$(basename "${site}" .py) routes its decision through the trust gateway"
done

# The gateway is the only module that returns an authorization verdict.
assert_contains "tools/trust/gateway.py" 'class TrustVerdict' \
  "the gateway defines the single verdict type"
assert_absent_in "tools/collectors" 'class .*Verdict' \
  "no collector module defines its own verdict type"

# --- No bypass, no second authority ------------------------------------------
# A fallback that silently allows is the failure this whole sprint exists to
# prevent. Both policy sources must deny by default.
assert_contains "tools/trust/gateway.py" '(fail(s)? closed|deny by default|denies by default)' \
  "the gateway documents that it fails closed"
assert_absent_in "tools/trust/gateway.py" '(return[[:space:]]+True[[:space:]]*$|allowed=True[[:space:]]*#[[:space:]]*default)' \
  "the gateway has no default-allow path"

# The source of every verdict is recorded, so a decision made without a
# root-terminated chain is visible rather than indistinguishable.
assert_contains "tools/trust/gateway.py" '(trust-plane-runtime|VerdictSource|source)' \
  "the gateway records which source decided"

# --- Nothing automatic, still ------------------------------------------------
assert_absent_in "tools/trust" \
  '((trust_on_first_use|auto_trust|auto_enroll|auto_approve)[[:space:]]*=[^=]|def[[:space:]]+(auto_trust|auto_enroll|auto_approve))' \
  "the migration introduces no automatic trust path"
assert_absent_in "tools/trust" \
  '((trust_score|confidence_score|reputation)[[:space:]]*=[^=]|\.(trust_score|reputation)\b)' \
  "the migration introduces no trust score"
assert_absent_in "tools/trust" \
  '(litellm|openai|anthropic|ollama|langchain|llm_client|system_prompt|prompt_template)' \
  "the gateway consumes no model or reasoning output"
assert_absent_in "tools/trust" \
  '(tools\.observation|tools\.experience|tools\.occurrence|tools\.integrity)' \
  "the gateway imports no reasoning layer"
assert_absent_in "tools/trust" \
  '(def[[:space:]]+(remediate|repair|restore_trust)_?|auto_remediate|auto_recover)' \
  "the migration introduces no remediation or recovery path"

# --- Placement stays out -----------------------------------------------------
# That sprint unified trust. `tools/fabric` arrives with ENG-0004; capability
# execution, clustering, and scheduling still may not.
for forbidden in tools/clustering tools/scheduler; do
  if [[ -e "${ROOT}/${forbidden}" ]]; then
    fail "v0.9.4 migrates trust only: ${forbidden} must not exist"
  else
    pass "no premature implementation: ${forbidden}"
  fi
done

# --- CI and local validation wiring -----------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-trust-migration\.sh' \
  "ci runs the trust migration suite"
assert_contains "tools/dev/run-validation.sh" 'tests/test-trust-migration\.sh' \
  "local validation runs the trust migration suite"

# --- Behavioural validation --------------------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'MIGPY' 2>&1 || true
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
os.chdir(root)

failures = 0


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


try:
    from tools.trust.gateway import (
        TrustGateway, TrustVerdict, VerdictSource, query,
    )
    from tools.trust.policy import (
        DOMAIN_FOR_MECHANISM, evaluate_policy,
    )
    from tools.trust.models import TrustState, TrustScope
    from tools.trust.store import TrustStore
    from tools.collectors.models import CollectorManifest
    from tools.collectors.remote.models import AuthenticationReference, RemoteTarget
    from tools.collectors.remote.command_catalog import CatalogError, operation_for, operation_ids
    ok("trust migration modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"trust migration import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

STAMP = datetime(2026, 8, 3, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))

# --- Every migrated mechanism names an ADR-0011 domain ---------------------
ADR_DOMAINS = {
    "host", "ssh-host-key", "certificate", "user", "collector-plugin",
    "capability-package", "model", "model-adapter", "prompt-bundle",
    "embedding-model", "index", "policy", "configuration-snapshot",
    "remote-transport", "fabric-node",
}
check(bool(DOMAIN_FOR_MECHANISM), "the migration declares a mechanism-to-domain map")
for mechanism, domain in sorted(DOMAIN_FOR_MECHANISM.items()):
    check(domain in ADR_DOMAINS,
          f"mechanism '{mechanism}' maps to an ADR-0011 domain ('{domain}')")

# No new domain was invented: the fifteen are the fifteen.
check(set(DOMAIN_FOR_MECHANISM.values()) <= ADR_DOMAINS,
      "the migration invents no new trust domain")

# --- The gateway fails closed on an unknown subject -----------------------
verdict = query(domain="host", subject_id="HOST-NOBODY", action="linux.hostname",
                evaluated_at=STAMP)
check(isinstance(verdict, TrustVerdict), "the gateway returns a verdict")
check(not verdict.allowed, "an unrecognised subject is denied")
check(bool(verdict.reasons), "the denial is explained")
check(verdict.domain == "host", "the verdict names its domain")

# --- Behaviour preservation: plugin manifest authorization ----------------
# Byte-for-byte: the migrated policy must produce the same problems the
# released manifest validation produced.
LOCAL = CollectorManifest(
    id="git-repository", name="Git", version="0.1.0", source_type="git-repository",
    description="local", permissions=("read-repository-files",),
    network_access=False, subprocess_access=True, filesystem_access="read-only")
check(LOCAL.validation_errors() == [], "an approved local manifest still validates")

REMOTE = CollectorManifest(
    id="linux-host", name="Linux Host", version="0.1.0", source_type="ssh-command",
    description="remote", permissions=("read-remote-host",),
    network_access=True, subprocess_access=True, filesystem_access=False)
check(REMOTE.validation_errors() == [], "an approved remote manifest still validates")

# Every previously refused shape is still refused, with a reason.
REFUSALS = (
    ("network without the permission",
     CollectorManifest(id="x", name="x", version="1", source_type="ssh-command",
                       description="d", permissions=(), network_access=True)),
    ("the permission without network",
     CollectorManifest(id="x", name="x", version="1", source_type="ssh-command",
                       description="d", permissions=("read-remote-host",),
                       network_access=False)),
    ("a forbidden permission",
     CollectorManifest(id="x", name="x", version="1", source_type="manual-attestation",
                       description="d", permissions=("execute-remediation",))),
    ("an unapproved permission",
     CollectorManifest(id="x", name="x", version="1", source_type="manual-attestation",
                       description="d", permissions=("invent-something",))),
    ("an unapproved source type",
     CollectorManifest(id="x", name="x", version="1", source_type="made-up",
                       description="d", permissions=())),
    ("a write filesystem claim",
     CollectorManifest(id="x", name="x", version="1", source_type="manual-attestation",
                       description="d", permissions=(), filesystem_access=True)),
    ("a non-kebab-case identifier",
     CollectorManifest(id="Not_Kebab", name="x", version="1",
                       source_type="manual-attestation", description="d", permissions=())),
)
for label, manifest in REFUSALS:
    problems = manifest.validation_errors()
    check(bool(problems), f"still refused after migration: {label}")

# --- Behaviour preservation: host operation authorization -----------------
def target(**overrides):
    defaults = dict(
        target_id="RTGT-0001", hostname="synthetic.invalid", port=22,
        username="observer", host_key_policy="strict",
        known_hosts_reference="/approved/known_hosts",
        authentication_reference=AuthenticationReference(
            kind="ssh-key-path", reference="/approved/key"),
        platform="linux", trust_classification="internal",
        allowed_operation_ids=("linux.hostname",),
        connect_timeout_seconds=5, command_timeout_seconds=15,
        max_stdout_bytes=65536, max_stderr_bytes=4096, allowed_units=())
    defaults.update(overrides)
    return RemoteTarget(**defaults)

permitted = query(domain="host", subject_id="RTGT-0001", action="linux.hostname",
                  evaluated_at=STAMP, context={"target": target()})
check(permitted.allowed, "an authorised operation is still permitted")
check(permitted.source == VerdictSource.CODE_OWNED_POLICY.value,
      "with no store configured the verdict comes from code-owned policy")

refused = query(domain="host", subject_id="RTGT-0001", action="linux.uptime",
                evaluated_at=STAMP, context={"target": target()})
check(not refused.allowed, "an unauthorised operation is still refused")
check(any("authoriz" in reason.lower() for reason in refused.reasons),
      "the refusal still names missing authorization")

# --- Behaviour preservation: operation catalog ----------------------------
check(len(operation_ids()) == 9, "the catalog still defines nine operations")
try:
    operation_for("linux.definitely_not_real")
    bad("an unknown operation identifier is still rejected")
except CatalogError:
    ok("an unknown operation identifier is still rejected")
for evil in ("nginx.service; rm -rf /", "../../etc/passwd", "*"):
    try:
        operation_for("linux.service_state", evil)
        bad(f"an invalid unit name is still rejected: {evil!r}")
    except CatalogError:
        ok(f"an invalid unit name is still rejected: {evil!r}")

# --- The runtime takes precedence when a store is configured --------------
with tempfile.TemporaryDirectory() as tmp:
    store = TrustStore(Path(tmp) / "trust")
    gateway = TrustGateway(store=store)
    result = gateway.query(domain="host", subject_id="RTGT-0001",
                           action="linux.hostname", evaluated_at=STAMP,
                           context={"target": target()})
    check(result.source == VerdictSource.TRUST_PLANE_RUNTIME.value,
          "a configured store makes the trust plane runtime authoritative")
    check(not result.allowed,
          "an unseeded store denies, because unknown fails closed")
    check(any("unknown" in reason.lower() or "lineage" in reason.lower()
              for reason in result.reasons),
          "the store-backed denial explains that nothing is recorded")

# --- The gateway never mutates anything -----------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = TrustStore(Path(tmp) / "trust")
    gateway = TrustGateway(store=store)
    before = sorted(p.name for p in store.root.rglob("*") if p.is_file())
    for _ in range(3):
        gateway.query(domain="host", subject_id="RTGT-0001", action="linux.hostname",
                      evaluated_at=STAMP, context={"target": target()})
    after = sorted(p.name for p in store.root.rglob("*") if p.is_file())
    check(before == after, "querying the gateway writes nothing")

# Deterministic: the same question gives the same answer.
first = query(domain="host", subject_id="RTGT-0001", action="linux.hostname",
              evaluated_at=STAMP, context={"target": target()})
second = query(domain="host", subject_id="RTGT-0001", action="linux.hostname",
               evaluated_at=STAMP, context={"target": target()})
check(first.to_dict() == second.to_dict(), "gateway verdicts are deterministic")

# --- An unknown domain fails closed ---------------------------------------
unknown_domain = query(domain="not-a-domain", subject_id="X", action="y",
                       evaluated_at=STAMP)
check(not unknown_domain.allowed, "an unrecognised domain is denied")

print(f"__FAILURES__={failures}")
MIGPY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "trust migration behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for the trust migration tests.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nTrust migration validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nTrust migration validation passed.\n'
