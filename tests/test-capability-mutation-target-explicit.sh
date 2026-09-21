#!/usr/bin/env bash
set -Eeuo pipefail

# Which store a mutating command actually writes through.
#
# HOST-ONLY. It drives the real CLI, which reads the provisioned backing-store
# configuration, and it reproduces the incident against the INSTALLED
# Generation-19 runtime. See tests/host-only.manifest.
#
# WHY THIS EXISTS
# ===============
# On 2026-09-20 a rehearsal substituted the runtime path through every shell
# gate of an operator ceremony and ran it. Each gate read a fixture and passed.
# Then `tools.capability.cli.command_abandon` resolved
# CAPABILITY_RUNTIME_ROOT -- a module constant, with no argument able to
# override it -- and abandoned CINV-000002 in production.
#
# The harness even asserted "the rendered block names no production path", and
# that assertion was true. The production path was never in the text. It was in
# the library the text called.
#
# THE INVARIANT
# =============
# A rehearsal must never be able to prove gates against one store while the
# mutator resolves another store implicitly.
#
# So this suite asks the only question that settles it: which object did the
# writer hold? Not which path appears in a script, not which path was passed --
# the device and inode the kernel reports for the descriptor the mutation was
# written through.
#
# Governed by docs/decisions/ADR-0016 and the G11-BC-Y report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh disable=SC1091
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /data/kyri/capability-runtime /usr/lib/kyri/python \
                   /etc/kyri/backing-store.json

INSTALLED=/usr/lib/kyri/python
PRODUCTION=/data/kyri/capability-runtime

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# On /data so the fixture satisfies the same backing-store verification the
# production root satisfies. A fixture the CLI would refuse proves nothing.
WORK="$(mktemp -d -p /data/kyri g11bcy-target.XXXXXX)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }
PRODUCTION_BEFORE="$(aggregate "${PRODUCTION}")"

fixture() {
  local path="${WORK}/$1"
  [[ -e "${path}" ]] && { chmod -R u+w "${path}"; rm -rf "${path}"; }
  cp -a "${PRODUCTION}" "${path}"
  printf '%s' "${path}"
}

# ===========================================================================
# 1. RED: the old design, reproduced without touching production
# ===========================================================================
#
# The installed Generation-19 CLI is the implementation that caused the
# incident. Its store constructor and its root anchor are replaced with
# recorders that raise, so nothing is opened, nothing is locked and nothing is
# written -- and the path it ASKED for is captured.

printf -- '--- RED: the old design resolves production from a constant ---\n'

red="$(cd "${INSTALLED}" && python3 - <<'REDPY' 2>&1
import argparse
import sys

sys.path.insert(0, ".")
from tools.capability import cli

asked = []


class Recorder:
    def __init__(self, root, **kwargs):
        asked.append(("store", str(root)))
        raise RuntimeError("stopped before opening anything")


def anchored(root):
    asked.append(("anchor", str(root)))
    raise RuntimeError("stopped before opening anything")


cli.CapabilityStore = Recorder
cli._anchored = anchored

# Every value a rehearsal controls says "fixture". There is no argument for
# the store root, because the old surface has none.
args = argparse.Namespace(
    expected_uid=1000, expected_gid=1000, cinv="CINV-000002",
    actor="a-rehearsal", request_id="rehearsal", reason="terminal-result-lifecycle-stranded",
    recorded_at="2026-09-20T18:54:33-05:00")

try:
    cli.command_abandon(args)
except RuntimeError:
    pass

verbs = next(a.choices for a in cli.build_parser()._actions
             if getattr(a, "choices", None))
flags = {o for a in verbs["abandon"]._actions for o in a.option_strings}

print("ASKED", asked[0][1] if asked else "nothing")
print("ROOT_FLAGS", sorted(f for f in flags if "root" in f) or "none")
REDPY
)"
asked="$(printf '%s\n' "${red}" | sed -n 's/^ASKED //p')"
root_flags="$(printf '%s\n' "${red}" | sed -n 's/^ROOT_FLAGS //p')"
if [[ "${asked}" == "${PRODUCTION}" ]]; then
  pass "the installed abandon asks for ${PRODUCTION} while every caller-controlled value says fixture"
else
  fail "expected the installed abandon to resolve ${PRODUCTION}, it asked for '${asked}'"
fi
if [[ "${root_flags}" == "none" ]]; then
  pass "the installed abandon surface has no root argument at all, so it cannot be aimed"
else
  fail "the installed abandon surface unexpectedly accepts ${root_flags}"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "reproducing the incident touched nothing: production is byte-identical"
else
  fail "THE RED CASE MUTATED PRODUCTION"
fi

# ===========================================================================
# 2. GREEN: the target must be stated
# ===========================================================================

printf -- '\n--- GREEN: no default, and no way back to one ---\n'

common=(--expected-uid 1000 --expected-gid 1000 --cinv CINV-000001
        --actor an-operator --request-id g11bcy-green
        --recorded-at 2026-09-20T20:00:00-05:00
        --reason historical-incomplete-execution)

out="$(cd "${ROOT}" && python3 -m tools.capability.cli abandon "${common[@]}" 2>&1)" && status=0 || status=$?
if (( status == 2 )) && [[ "${out}" == *"the following arguments are required: --store-root"* ]]; then
  pass "omitting the target is a usage error, not a quiet resolution to production"
else
  fail "omission gave status ${status}: ${out}"
fi

if (cd "${INSTALLED}" && python3 -c '
import sys; sys.path.insert(0, ".")
from tools.capability import cli
raise SystemExit(0 if hasattr(cli, "CAPABILITY_RUNTIME_ROOT") else 1)') ; then
  installed_has_constant=yes
else
  installed_has_constant=no
fi
checkout_uses="$(grep -c 'CapabilityStore(CAPABILITY_RUNTIME_ROOT' "${ROOT}/tools/capability/cli.py" || true)"
# Three, and exactly three: authorise-launch, execute and recover -- the
# allowlist section below names each and says why. `abandon` was the fourth
# until G11-BC-Y, and its removal is what this number records.
if [[ "${installed_has_constant}" == "yes" ]] && (( checkout_uses == 3 )); then
  pass "the constant survives for the three allowlisted verbs, and for no others"
else
  fail "expected exactly 3 compiled-in store roots in the checkout, found ${checkout_uses}"
fi

for bad in "relative/path" "/data/kyri/../kyri/capability-runtime" ""; do
  out="$(cd "${ROOT}" && python3 -m tools.capability.cli abandon --store-root "${bad}" \
        "${common[@]}" 2>&1)" && status=0 || status=$?
  if (( status != 0 )) && [[ "${out}" != *"Traceback"* ]]; then
    pass "a root given as '${bad}' refuses cleanly"
  else
    fail "a root given as '${bad}' gave status ${status}: ${out}"
  fi
done

out="$(cd "${ROOT}" && python3 -m tools.capability.cli abandon --store-root /data/kyri/nothing-here \
      "${common[@]}" 2>&1)" && status=0 || status=$?
if (( status != 0 )) && [[ "${out}" != *"Traceback"* ]]; then
  pass "a root that is not a capability runtime refuses cleanly"
else
  fail "a nonexistent root gave status ${status}: ${out}"
fi

# ===========================================================================
# 3. The mutator's own answer about where it wrote
# ===========================================================================

printf -- '\n--- the target the writer actually held ---\n'

FIX="$(fixture fix-abandon)"
out="$(cd "${ROOT}" && python3 -m tools.capability.cli abandon --store-root "${FIX}" \
      --expected-uid 1000 --expected-gid 1000 --cinv CINV-000001 \
      --actor an-operator --request-id g11bcy-fixture-abandon \
      --recorded-at 2026-09-20T20:00:00-05:00 \
      --reason historical-incomplete-execution 2>&1)" && status=0 || status=$?
if (( status == 0 )); then
  pass "an explicit fixture target is accepted and does the work"
else
  fail "the fixture abandon failed (${status}): ${out}"
fi

reported_dev="$(printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["st_dev"])' 2>/dev/null || echo "")"
reported_ino="$(printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["st_ino"])' 2>/dev/null || echo "")"
fixture_ino="$(stat -c '%i' "${FIX}/execution")"
production_ino="$(stat -c '%i' "${PRODUCTION}/execution")"
if [[ "${reported_ino}" == "${fixture_ino}" ]]; then
  pass "the mutator reports the fixture's execution root (inode ${reported_ino}), asked of the kernel"
else
  fail "the mutator reported inode ${reported_ino}, the fixture is ${fixture_ino}"
fi
if [[ "${reported_ino}" != "${production_ino}" ]]; then
  pass "that is not production's execution root (inode ${production_ino}), so the two are distinguishable"
else
  fail "the reported target is indistinguishable from production"
fi
if [[ -n "${reported_dev}" ]]; then
  pass "the target carries its device as well as its inode (${reported_dev})"
else
  fail "the target carries no device"
fi

# The fixture really was mutated, and production really was not. Both measured.
if [[ -e "${FIX}/execution/transitions/CINV-000001.000003" ]]; then
  pass "the fixture's CINV-000001 was closed"
else
  fail "the fixture was not mutated, so this proved nothing"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "production is byte-identical after a fixture-targeted mutation"
else
  fail "PRODUCTION CHANGED DURING A FIXTURE-TARGETED MUTATION"
fi

# What a production-targeted ceremony would report, computed read-only.
production_target="$(cd "${ROOT}" && python3 - "${PRODUCTION}" <<'PRODPY'
import os, sys
sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution.backing_store import target_fingerprint
root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    print(target_fingerprint(root)["st_ino"])
finally:
    root.close()
PRODPY
)"
if [[ "${production_target}" == "${production_ino}" ]]; then
  pass "a production-targeted call would report inode ${production_target}, which a ceremony can pin"
else
  fail "the production target does not resolve to its own inode"
fi

# ===========================================================================
# 4. The same rule for the correction verb, which is born with it
# ===========================================================================

printf -- '\n--- the correction verb takes the same target ---\n'

correct=(--subject-cadm CADM-000001 --cinv CINV-000002
         --disputed-field actor --disputed-value primary-platform-operator
         --finding attribution-not-authorised
         --actual-initiator unauthorised-rehearsal-harness
         --actor an-operator --request-id g11bcy-fixture-correct
         --recorded-at 2026-09-20T20:00:00-05:00)

out="$(cd "${ROOT}" && python3 -m tools.capability.cli correct-provenance "${correct[@]}" 2>&1)" && status=0 || status=$?
if (( status == 2 )) && [[ "${out}" == *"--store-root"* ]]; then
  pass "correct-provenance omitting its target is a usage error too"
else
  fail "correct-provenance omission gave status ${status}"
fi

FIX2="$(fixture fix-correct)"
out="$(cd "${ROOT}" && python3 -m tools.capability.cli correct-provenance \
      --store-root "${FIX2}" "${correct[@]}" 2>&1)" && status=0 || status=$?
if (( status == 0 )); then
  pass "an explicit fixture target is accepted by correct-provenance"
else
  fail "the fixture correction failed (${status}): ${out}"
fi
reported_ino="$(printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["st_ino"])' 2>/dev/null || echo "")"
if [[ "${reported_ino}" == "$(stat -c '%i' "${FIX2}/execution")" ]]; then
  pass "the correction reports the fixture it wrote through"
else
  fail "the correction reported inode ${reported_ino}"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "production is byte-identical after a fixture-targeted correction"
else
  fail "PRODUCTION CHANGED DURING A FIXTURE-TARGETED CORRECTION"
fi

# ===========================================================================
# 5. The audit: every mutating verb, and which roots it may resolve
# ===========================================================================
#
# The allowlist is the finding, written down. `authorise-launch` and `execute`
# compile their roots in BECAUSE the privileged transition on the far side
# compiles in the same ones: the ceremony and its consumer agree by
# construction, and an argument there could only produce a ceremony nothing
# reads. `recover` writes nothing to the store at all.
#
# A new command that resolves a root implicitly fails this.

printf -- '\n--- the mutating-verb audit ---\n'

audit="$(cd "${ROOT}" && python3 - <<'AUDITPY'
import inspect
import sys

sys.path.insert(0, ".")
from tools.capability import cli

# verb -> why it may resolve a root without being told
INTENTIONALLY_FIXED = {
    "authorise-launch": "the privileged transition compiles in the same roots",
    "execute": "the privileged transition compiles in the same roots",
    "recover": "writes nothing to the capability runtime store",
}
READ_ONLY = {"inspect", "validate"}

verbs = next(a.choices for a in cli.build_parser()._actions
             if getattr(a, "choices", None))

problems = []
for name, parser in sorted(verbs.items()):
    flags = {o for a in parser._actions for o in a.option_strings}
    handler = parser.get_default("handler")
    source = inspect.getsource(handler) if handler else ""
    explicit = "--store-root" in flags
    implicit = "CAPABILITY_RUNTIME_ROOT" in source
    if explicit and implicit:
        problems.append(f"{name}: takes --store-root AND resolves the constant")
    elif implicit and name not in INTENTIONALLY_FIXED:
        problems.append(f"{name}: resolves the constant implicitly and is not "
                        "on the documented allowlist")
    elif not explicit and not implicit and name not in READ_ONLY | set(INTENTIONALLY_FIXED):
        problems.append(f"{name}: resolves no root this audit can see")
    kind = ("explicit" if explicit else
            "fixed: " + INTENTIONALLY_FIXED[name] if name in INTENTIONALLY_FIXED
            else "read-only")
    print(f"  {name:<20} {kind}")

print("PROBLEMS " + ("; ".join(problems) if problems else "none"))
AUDITPY
)"
printf '%s\n' "${audit}" | grep -v '^PROBLEMS'
if printf '%s\n' "${audit}" | grep -q '^PROBLEMS none$'; then
  pass "every verb either takes an explicit target or is on the documented fixed-root allowlist"
else
  fail "the audit found: $(printf '%s\n' "${audit}" | sed -n 's/^PROBLEMS //p')"
fi

# ===========================================================================
# 6. What `actor` is, and what it is not
# ===========================================================================
#
# The incident produced a record attributed to `primary-platform-operator`
# because the harness typed that string. Nothing checked it, and nothing could
# have. These cases assert the weakness rather than papering over it, so a
# reader never mistakes the field for an authenticated identity.

printf -- '\n--- actor is asserted, not authenticated ---\n'

FIX3="$(fixture fix-actor)"
out="$(cd "${ROOT}" && python3 -m tools.capability.cli abandon --store-root "${FIX3}" \
      --expected-uid 1000 --expected-gid 1000 --cinv CINV-000001 \
      --actor 'somebody-who-does-not-exist' --request-id g11bcy-actor \
      --recorded-at 2026-09-20T20:00:00-05:00 \
      --reason historical-incomplete-execution 2>&1)" && status=0 || status=$?
if (( status == 0 )); then
  pass "an actor nobody has ever heard of is accepted: the string proves nothing"
else
  fail "the invented-actor case failed unexpectedly (${status}): ${out}"
fi
# The record this run wrote, found by the invocation it is about -- the
# fixture already carries CADM-000001, which is about a different one.
written="$(grep -l '"cinv":"CINV-000001"' "${FIX3}"/execution/admin-records/CADM-*/abandonment | head -1)"
detail="$(grep -o '"actor":"[^"]*"' "${written}" | head -1)"
if [[ "${detail}" == '"actor":"somebody-who-does-not-exist"' ]]; then
  pass "it is recorded verbatim in $(basename "$(dirname "${written}")"), exactly as an operator's would be"
else
  fail "the recorded actor was ${detail}"
fi
if ! grep -q 'authenticated\|authorised_by\|verified_actor' "${written}"; then
  pass "the record claims no authentication for it, which is the honest schema"
else
  fail "the abandonment record claims an authentication the design does not perform"
fi

if (cd "${ROOT}" && python3 -c '
import sys; sys.path.insert(0, ".")
from tools.capability.execution.provenance import FINDINGS, FINDING_NOT_AUTHORISED
raise SystemExit(0 if FINDING_NOT_AUTHORISED in FINDINGS else 1)'); then
  pass "and the correction verb can say exactly that about a past record"
else
  fail "no finding exists for an unauthorised attribution"
fi

# ===========================================================================
# 7. Production, after everything
# ===========================================================================

printf -- '\n--- production untouched ---\n'
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the production runtime is byte-identical: ${PRODUCTION_BEFORE}"
else
  fail "THE PRODUCTION RUNTIME CHANGED"
fi
if [[ "$(find "${PRODUCTION}/execution/admin-records" -mindepth 1 -maxdepth 1 | wc -l)" == "1" ]]; then
  pass "production still holds exactly the one administrative record it held"
else
  fail "the production administrative records changed"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Mutation target suite passed.\n'
else
  printf 'Mutation target suite FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
