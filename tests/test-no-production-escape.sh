#!/usr/bin/env bash
set -Eeuo pipefail

# NO TEST MAY DISPATCH A GOVERNED MUTATOR THAT CAN RESOLVE PRODUCTION.
#
# WHY THIS EXISTS. On 2026-09-24 test-capability-execution-generation20-installer.sh
# abandoned CINV-000001 in production. It launched a historical CLI as a
# SUBPROCESS to prove a point about a parser. The fixture it launched from held
# a Generation-19 cli.py, whose `command_abandon` has no --store-root and
# resolves the compiled-in /data/kyri/capability-runtime, so the call left the
# fixture entirely.
#
# THE DISTINCTION THAT MATTERS is not "fixture or not". It is HOW the root is
# resolved:
#
#   in-process, with the module constant rebound   -- safe. The rebinding holds
#                                                     for the call.
#   subprocess, with an explicit --store-root      -- safe. The root is named.
#   subprocess, with NO explicit root              -- DANGEROUS. A subprocess
#                                                     re-imports the module and
#                                                     gets the compiled-in
#                                                     production path, whatever
#                                                     the surrounding fixture
#                                                     says.
#
# The third form is the one that escaped, and it is what this suite refuses --
# statically, across every test, so the class cannot return through a different
# suite at a different generation.
#
# Static by construction: nothing here runs a CLI. Reading the tests is the test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# The governed mutators. A verb here can write to a capability runtime, so a
# dispatch of one without a named target is an escape waiting for the right
# generation. Closed on purpose: adding a verb to the CLI without adding it
# here is caught by the coverage check below.
MUTATING_VERBS=(invoke authorise-launch execute abandon correct-provenance conclude recover)

printf -- '--- the closed set is complete ---\n'

# Every subcommand the released CLI exposes is either named above or is proved
# read-only here. A verb added later is a failure until it is classified.
READ_ONLY_VERBS=(inspect validate)
cli_verbs="$(cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 - <<'VERBPY'
import sys
sys.path.insert(0, ".")
from tools.capability import cli
parser = cli.build_parser()
print(" ".join(sorted(next(a.choices for a in parser._actions
                           if getattr(a, "choices", None)))))
VERBPY
)"
unclassified=""
for verb in ${cli_verbs}; do
  known=0
  for candidate in "${MUTATING_VERBS[@]}" "${READ_ONLY_VERBS[@]}"; do
    [[ "${verb}" == "${candidate}" ]] && { known=1; break; }
  done
  (( known == 1 )) || unclassified+="${verb} "
done
if [[ -z "${unclassified}" ]]; then
  pass "every released CLI verb is classified: $(wc -w <<<"${cli_verbs}") verbs"
else
  fail "unclassified CLI verb(s): ${unclassified}-- classify before they can be dispatched anywhere"
fi

printf -- '\n--- no subprocess dispatch without a named target ---\n'

# A dispatch is `python -m tools.capability.cli <verb>` or a direct run of
# cli.py. Comment lines are excluded: several suites document the dangerous
# form precisely so a reader knows what was removed.
offenders=""
checked=0
while IFS= read -r suite; do
  checked=$((checked + 1))
  while IFS= read -r hit; do
    line_number="${hit%%:*}"
    text="${hit#*:}"
    # A named target on the same line, or continued onto the next, is safe.
    window="$(sed -n "${line_number},$((line_number + 4))p" "${suite}")"
    [[ "${window}" == *"--store-root"* ]] && continue
    # `--fixture` is the installers' own redirect and names a root explicitly.
    [[ "${window}" == *"--fixture"* ]] && continue
    # A dispatch quoted INSIDE a matcher is text being inspected, not a command
    # being run: several suites assert what a ceremony file says.
    [[ "${text}" == *"grep "* || "${text}" == *"awk "* || "${text}" == *"sed "* ]] && continue
    offenders+="$(basename "${suite}"):${line_number}: ${text}"$'\n'
  done < <(grep -nE '(-m[[:space:]]+tools\.capability\.cli|capability/cli\.py)[[:space:]]+('"$(IFS='|'; echo "${MUTATING_VERBS[*]}")"')\b' \
             "${suite}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done < <(find "${ROOT}/tests" -maxdepth 1 -name 'test-*.sh' | sort)

if [[ -z "${offenders}" ]]; then
  pass "none of the ${checked} test suites dispatches a governed mutator without naming its target"
else
  fail "subprocess dispatch with no named target:"$'\n'"${offenders}"
fi

printf -- '\n--- the incident, as a standing regression ---\n'

# The exact shape that escaped, refused by name so it cannot return quietly.
if grep -rqE '\-m[[:space:]]+tools\.capability\.cli[[:space:]]+abandon[^|]*--cinv[[:space:]]+CINV-000001' \
     "${ROOT}/tests" --include='test-*.sh' 2>/dev/null \
   && ! grep -rqE '^[[:space:]]*#.*-m[[:space:]]+tools\.capability\.cli[[:space:]]+abandon' \
        "${ROOT}/tests" --include='test-*.sh' 2>/dev/null; then
  fail "a test dispatches abandon against CINV-000001: that is the 2026-09-24 escape"
else
  pass "the 2026-09-24 shape -- dispatching abandon at CINV-000001 -- is absent"
fi

# An installer suite that publishes a fixture AND THEN DISPATCHES A CLI inside
# it must treat publication failure as fatal -- otherwise an unpublished
# fixture's historical CLI is what runs next, which is the 2026-09-24 chain.
#
# Narrow on purpose. Suites that only IMPORT a module inside the fixture cannot
# resolve a runtime root at all, and demanding `fatal` of them would be a rule
# about tidiness rather than about escape. The condition is the dispatch.
missing=""
considered=0
while IFS= read -r installer_suite; do
  grep -qE 'run_installer[^\n]*--install' "${installer_suite}" || continue
  grep -qE '(-m[[:space:]]+tools\.capability\.cli|capability/cli\.py)[[:space:]]+[a-z]' \
    "${installer_suite}" || continue
  considered=$((considered + 1))
  grep -q 'fatal ' "${installer_suite}" || missing+="$(basename "${installer_suite}") "
done < <(find "${ROOT}/tests" -maxdepth 1 -name 'test-capability-execution-generation*-installer.sh' | sort)
if [[ -z "${missing}" ]]; then
  pass "every installer suite that publishes a fixture and dispatches a CLI inside it treats publication failure as fatal (${considered} considered)"
else
  fail "installer suite(s) that dispatch inside a fixture without a fatal publication failure: ${missing}"
fi

printf -- '\n'
if (( FAILURES == 0 )); then
  printf 'No-production-escape validation passed.\n'
else
  printf 'No-production-escape validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
