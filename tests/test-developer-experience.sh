#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for the developer experience tooling.
#
# This suite is about the workflow, not the platform. It asserts that a
# developer running one command locally exercises the same checks CI does, that
# nothing skips silently, and that no tool modifies the host without being told
# to.
#
# It contacts no host, installs nothing, starts no container, and writes
# nothing into the repository. Missing-PyYAML behaviour is exercised with a
# PYTHONPATH shim rather than by uninstalling anything.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEV="tools/dev"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

# check <exit-status> <pass-message> <fail-message>
# An explicit if rather than `condition && pass || fail`: in that idiom the
# fail branch also runs when pass itself fails, which is how a green suite
# starts reporting phantom failures.
check() {
  if [[ "$1" -eq 0 ]]; then pass "$2"; else fail "$3"; fi
}

assert_executable() {
  if [[ -x "${ROOT}/$1" ]]; then pass "executable: $1"; else fail "script is not executable: $1"; fi
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

# --- Required files --------------------------------------------------------
for script in bootstrap check-toolchain run-validation run-shellcheck run-local-ci; do
  assert_file "${DEV}/${script}.sh"
  assert_executable "${DEV}/${script}.sh"
done
assert_file "${DEV}/versions.env"

for document in getting-started toolchain local-validation; do
  assert_file "docs/development/${document}.md"
done

# --- Shell standards -------------------------------------------------------
# Every repository shell script must fail fast. A dev tool that continues after
# an error is worse than no tool, because it reports success it did not earn.
for script in "${ROOT}/${DEV}"/*.sh; do
  [[ -f "${script}" ]] || continue
  name="$(basename "${script}")"
  if head -5 "${script}" | grep -q 'set -Eeuo pipefail\|set -euo pipefail'; then
    pass "uses strict mode: ${name}"
  else
    fail "script must use set -euo pipefail: ${name}"
  fi
  if head -1 "${script}" | grep -q '^#!/usr/bin/env bash'; then
    pass "declares bash shebang: ${name}"
  else
    fail "script must declare #!/usr/bin/env bash: ${name}"
  fi
done

# --- Toolchain manifest ----------------------------------------------------
MANIFEST="${DEV}/versions.env"
for variable in SHELLCHECK_VERSION PYTHON_MIN_VERSION PYYAML_VERSION \
                DOCKER_COMPOSE_MIN_VERSION GIT_MIN_VERSION; do
  assert_contains "${MANIFEST}" "^${variable}=" "manifest pins ${variable}"
done

# Every pin must declare what kind of constraint it is, so a reader knows
# whether a newer version is a problem or not.
for kind in exact minimum "CI-aligned" "host-observed"; do
  assert_contains "${MANIFEST}" "${kind}" "manifest documents '${kind}' pins"
done

# The ShellCheck pin must match what CI actually runs.
assert_contains "${MANIFEST}" '^SHELLCHECK_VERSION=0\.9\.0$' \
  "pinned ShellCheck version matches the version CI runs"

# The PyYAML pin must match the hash-pinned requirement CI installs.
if [[ -f "${ROOT}/requirements-ci.txt" ]] && [[ -f "${ROOT}/${MANIFEST}" ]]; then
  req_version="$(grep -oE '^pyyaml==[0-9.]+' "${ROOT}/requirements-ci.txt" | cut -d= -f3)"
  man_version="$(grep -oE '^PYYAML_VERSION=[0-9.]+' "${ROOT}/${MANIFEST}" | cut -d= -f2)"
  if [[ -n "${req_version}" && "${req_version}" == "${man_version}" ]]; then
    pass "manifest PyYAML version matches requirements-ci.txt (${req_version})"
  else
    fail "manifest PyYAML '${man_version}' does not match requirements-ci.txt '${req_version}'"
  fi
else
  fail "cannot compare PyYAML versions; a required file is missing"
fi

# --- Safety: no host mutation, no remote access ----------------------------
# Installation may only happen behind an explicit flag. These patterns catch a
# package manager invoked anywhere outside the guarded apply path.
assert_absent_in "${DEV}" \
  '(curl|wget|nc|ssh|scp|sftp|rsync)[[:space:]]+[^|]*(http|://|@)' \
  "no dev script downloads from or connects to a remote host"
assert_absent_in "${DEV}" \
  '(ufw|iptables|nft|systemctl (start|stop|restart|enable|disable))' \
  "no dev script alters firewall or system services"
# Platform runtime is off limits. The pinned ShellCheck image is the single
# approved container: it is ephemeral, network-isolated, mounts the repository
# read-only, and touches no platform service. Anything else is a finding.
assert_absent_in "${DEV}" \
  '(docker (start|stop|rm|exec|kill|volume|network)|docker compose (up|down|start|stop|restart))' \
  "no dev script touches a platform container, volume, or network"
# The invocation spans several lines, so the file is judged rather than the
# line: any script running a container must be the ShellCheck runner, and it
# must use the pinned image variable rather than a literal tag.
unapproved_run=""
while read -r runner; do
  [[ -z "${runner}" ]] && continue
  if [[ "$(basename "${runner}")" != "run-shellcheck.sh" ]]; then
    unapproved_run+="${runner} "
  elif ! grep -q 'SHELLCHECK_IMAGE' "${runner}"; then
    unapproved_run+="${runner}(unpinned) "
  fi
done < <(grep -rIlE 'docker run' "${ROOT}/${DEV}" || true)
if [[ -z "${unapproved_run}" ]]; then
  pass "the only container a dev script runs is the pinned ShellCheck image"
else
  fail "dev script runs an unapproved container: ${unapproved_run}"
fi
assert_absent_in "${DEV}" "['\"][^'\"]*ai/\\.env['\"]" \
  "no dev script references ai/.env"
assert_absent_in "${DEV}" '(gh (api|pr|run|release)|api\.github\.com)' \
  "no dev script calls a GitHub API"
assert_absent_in "${DEV}" '(git (push|commit|checkout -b|branch)[[:space:]])' \
  "no dev script pushes, commits, or creates branches"

# A package manager may be *named* anywhere: remediation text has to tell the
# reader what to run. What matters is whether it is *executed*.
#
# Distinguishing the two needs more than a line-position regex, because a
# here-doc body is indented exactly like a command. This strips here-doc bodies
# first, so text a script prints is never mistaken for a command it runs.
strip_heredocs() {
  awk '
    /<<-?[A-Z'"'"'"]*[A-Za-z_]+/ && !inheredoc {
      line = $0
      if (match(line, /<<-?[ ]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
        tag = substr(line, RSTART, RLENGTH)
        gsub(/<<-?[ ]*['"'"'"]?/, "", tag); gsub(/['"'"'"]/, "", tag)
        inheredoc = 1; heretag = tag
      }
      print; next
    }
    inheredoc {
      stripped = $0; gsub(/^[ \t]+/, "", stripped)
      if (stripped == heretag) { inheredoc = 0 }
      next
    }
    { print }
  ' "$1"
}

executed_pm=""
for dev_script in "${ROOT}/${DEV}"/*.sh; do
  [[ -f "${dev_script}" ]] || continue
  [[ "$(basename "${dev_script}")" == "bootstrap.sh" ]] && continue
  if strip_heredocs "${dev_script}" \
      | grep -qE '^[[:space:]]*(sudo[[:space:]]+)?(apt-get|apt|dnf|yum)[[:space:]]+(install|update|upgrade)'; then
    executed_pm+="$(basename "${dev_script}") "
  fi
done
if [[ -z "${executed_pm}" ]]; then
  pass "only bootstrap.sh executes a package manager"
else
  fail "package manager executed outside bootstrap.sh: ${executed_pm}"
fi

# bootstrap.sh must genuinely execute one, or --apply does nothing.
if strip_heredocs "${ROOT}/${DEV}/bootstrap.sh" \
    | grep -qE '^[[:space:]]*sudo[[:space:]]+apt-get[[:space:]]+install'; then
  pass "bootstrap.sh executes the install it advertises"
else
  fail "bootstrap.sh --apply must actually run the install command"
fi

# --- Validation wrapper wiring ---------------------------------------------
VALIDATION="${DEV}/run-validation.sh"
for suite in test-static test-docs-static test-platform-model test-evidence-validator \
             test-collector-framework test-initial-collectors test-knowledge-orchestrator; do
  assert_contains "${VALIDATION}" "tests/${suite}\.sh" \
    "validation runs ${suite}.sh"
done
assert_contains "${VALIDATION}" 'validate_evidence\.py' "validation runs the evidence validator"
assert_contains "${VALIDATION}" 'validate_plugins\.py' "validation runs the plugin validator"
assert_contains "${VALIDATION}" 'tools\.collectors\.cli' "validation runs the collector CLI"
assert_contains "${VALIDATION}" 'tools\.observation\.cli' "validation runs the observation CLI"
assert_contains "${VALIDATION}" 'ai/compose\.yaml' "validation renders the ai compose file"
assert_contains "${VALIDATION}" 'ai/ollama/compose\.yaml' "validation renders the ollama compose file"
assert_contains "${VALIDATION}" 'ai/litellm/compose\.yaml' "validation renders the litellm compose file"
assert_contains "${VALIDATION}" 'git diff --check' "validation checks whitespace"
assert_contains "${VALIDATION}" '__pycache__' "validation checks for tracked bytecode"
assert_contains "${VALIDATION}" 'run-shellcheck\.sh' "validation runs ShellCheck"
assert_contains "${VALIDATION}" 'check-toolchain\.sh' "validation runs the toolchain check"
assert_contains "${VALIDATION}" 'bash -n' "validation syntax-checks the shell suites"
assert_contains "${VALIDATION}" '\-\-quick' "validation supports quick mode"
assert_contains "${VALIDATION}" 'EVID-\*|platform-model' "validation includes a runtime-evidence backstop"

# --- No suite may skip silently --------------------------------------------
# The whole point of this increment: a green run must mean the checks ran.
# This suite is excluded: it necessarily contains the pattern it searches for.
skipping="$(grep -lE "printf 'SKIP: PyYAML" \
  --exclude="test-developer-experience.sh" "${ROOT}"/tests/*.sh 2>/dev/null || true)"
if [[ -z "${skipping}" ]]; then
  pass "no test suite retains a silent PyYAML skip path"
else
  fail "suite still skips silently when PyYAML is missing: $(basename "${skipping}" | tr '\n' ' ')"
fi

for suite in test-platform-model test-evidence-validator test-collector-framework \
             test-initial-collectors test-knowledge-orchestrator; do
  assert_contains "tests/${suite}.sh" 'requirements-ci\.txt' \
    "${suite}.sh names the pinned install command when PyYAML is missing"
done

# --- Behavioural: missing PyYAML fails closed ------------------------------
# A shim directory whose yaml module raises on import. This makes `import yaml`
# fail for a child process without uninstalling anything from the host.
SHIM="$(mktemp -d)"
trap 'rm -rf "${SHIM}"' EXIT
printf 'raise ImportError("simulated missing PyYAML")\n' >"${SHIM}/yaml.py"

for suite in test-platform-model test-evidence-validator test-collector-framework \
             test-initial-collectors test-knowledge-orchestrator; do
  if [[ ! -f "${ROOT}/tests/${suite}.sh" ]]; then
    fail "cannot exercise missing-PyYAML behaviour; tests/${suite}.sh is absent"
    continue
  fi
  set +e
  output="$(PYTHONPATH="${SHIM}" bash "${ROOT}/tests/${suite}.sh" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 0 ]]; then
    pass "${suite}.sh fails closed when PyYAML is unavailable"
  else
    fail "${suite}.sh exited 0 with PyYAML unavailable; a skipped suite must never look green"
  fi
  if grep -q 'requirements-ci.txt' <<<"${output}"; then
    pass "${suite}.sh names the pinned install command in its failure"
  else
    fail "${suite}.sh must name 'python3 -m pip install --require-hashes -r requirements-ci.txt'"
  fi
done

# --- Behavioural: bootstrap is safe by default -----------------------------
if [[ -x "${ROOT}/${DEV}/bootstrap.sh" ]]; then
  before="$(find "${ROOT}" -path "${ROOT}/.git" -prune -o -type f -print | sort | md5sum)"
  set +e
  dry_output="$(bash "${ROOT}/${DEV}/bootstrap.sh" 2>&1)"
  dry_status=$?
  set -e
  after="$(find "${ROOT}" -path "${ROOT}/.git" -prune -o -type f -print | sort | md5sum)"

  check "$([[ "${dry_status}" -eq 0 ]] && echo 0 || echo 1)" \
    "bootstrap dry-run succeeds" "bootstrap dry-run must succeed (exit ${dry_status})"
  check "$([[ "${before}" == "${after}" ]] && echo 0 || echo 1)" \
    "bootstrap dry-run creates no files" "bootstrap dry-run modified the repository"
  check "$(grep -qiE 'dry.run' <<<"${dry_output}" && echo 0 || echo 1)" \
    "bootstrap announces dry-run mode" "bootstrap must state that it is running in dry-run mode"
  # The apt-get form is asserted against the script, not the output: on a fully
  # provisioned host nothing is missing, so a correct bootstrap prints no
  # install command at all. What the output must always carry is an actionable
  # next step or an explicit statement that there is nothing to do.
  assert_contains "${DEV}/bootstrap.sh" 'apt-get install --yes' \
    "bootstrap defines the exact Ubuntu install command"
  check "$(grep -qE '(apt-get install|pip install|docker pull|Nothing to do)' <<<"${dry_output}" && echo 0 || echo 1)" \
    "bootstrap dry-run prints an actionable step or reports nothing to do" \
    "bootstrap must print an actionable command or state that nothing is missing"
  check "$(grep -qE '\-\-apply' <<<"${dry_output}" && echo 0 || echo 1)" \
    "bootstrap documents the explicit apply flag" "bootstrap must name --apply as the way to install"

  # Idempotent: a second dry-run produces identical output.
  set +e
  second="$(bash "${ROOT}/${DEV}/bootstrap.sh" 2>&1)"
  set -e
  check "$([[ "${dry_output}" == "${second}" ]] && echo 0 || echo 1)" \
    "bootstrap dry-run is idempotent" "repeated bootstrap dry-runs must produce identical output"

  assert_contains "${DEV}/bootstrap.sh" 'DRY_RUN|dry_run' "bootstrap defaults to dry-run"
else
  fail "cannot exercise bootstrap; tools/dev/bootstrap.sh is absent or not executable"
fi

# --- Behavioural: toolchain check ------------------------------------------
if [[ -x "${ROOT}/${DEV}/check-toolchain.sh" ]]; then
  set +e
  tc_output="$(bash "${ROOT}/${DEV}/check-toolchain.sh" 2>&1)"
  tc_status=$?
  set -e
  check "${tc_status}" "toolchain check passes on this host" \
    "toolchain check failed on this host: $(head -3 <<<"${tc_output}" | tr '\n' ' ')"
  for tool in python3 pyyaml shellcheck compose git; do
    check "$(grep -qiE "${tool}" <<<"${tc_output}" && echo 0 || echo 1)" \
      "toolchain check reports ${tool}" "toolchain check must report ${tool}"
  done

  # A missing tool must produce an actionable error, not a bare non-zero exit.
  # A PATH with nothing in it cannot start bash, which would test the shell
  # rather than the script. This keeps a working shell and removes the tools.
  MINIMAL_BIN="$(mktemp -d)/bin"
  mkdir -p "${MINIMAL_BIN}"
  for essential in bash dirname basename awk sed cat env; do
    essential_path="$(command -v "${essential}" || true)"
    [[ -n "${essential_path}" ]] && ln -sf "${essential_path}" "${MINIMAL_BIN}/${essential}"
  done
  set +e
  missing_output="$(PATH="${MINIMAL_BIN}" bash "${ROOT}/${DEV}/check-toolchain.sh" 2>&1)"
  missing_status=$?
  set -e
  rm -rf "$(dirname "${MINIMAL_BIN}")"
  check "$([[ "${missing_status}" -ne 0 ]] && echo 0 || echo 1)" \
    "toolchain check fails when tools are absent" \
    "toolchain check must fail when required tools are absent"
  check "$(grep -qiE '(install|apt-get|bootstrap)' <<<"${missing_output}" && echo 0 || echo 1)" \
    "missing-tool error is actionable" "missing-tool error must name a remediation"
else
  fail "cannot exercise the toolchain check; the script is absent or not executable"
fi

# --- Behavioural: ShellCheck runner ----------------------------------------
if [[ -x "${ROOT}/${DEV}/run-shellcheck.sh" ]]; then
  assert_contains "${DEV}/run-shellcheck.sh" 'SHELLCHECK_VERSION' \
    "shellcheck runner reads the pinned version"
  assert_contains "${DEV}/run-shellcheck.sh" 'scripts/\*\.sh|scripts' \
    "shellcheck runner covers scripts/"
  assert_contains "${DEV}/run-shellcheck.sh" 'tests' \
    "shellcheck runner covers tests/"
  # Never silently skip: absence must be an error with a remediation.
  assert_contains "${DEV}/run-shellcheck.sh" '(ERROR|error:|not available|could not)' \
    "shellcheck runner reports absence as an error"
  if strip_heredocs "${ROOT}/${DEV}/run-shellcheck.sh" \
      | grep -qE '^[[:space:]]*(sudo[[:space:]]+)?apt-get[[:space:]]+install'; then
    fail "shellcheck runner must never execute an install"
  else
    pass "shellcheck runner never executes an install"
  fi
  assert_absent_in "${DEV}/run-shellcheck.sh" 'SKIP:' \
    "shellcheck runner never skips"
else
  fail "cannot exercise the shellcheck runner; the script is absent or not executable"
fi

# --- Behavioural: local CI wrapper -----------------------------------------
if [[ -x "${ROOT}/${DEV}/run-local-ci.sh" ]]; then
  assert_contains "${DEV}/run-local-ci.sh" 'run-validation\.sh' \
    "local ci wrapper delegates to the validation command"
  assert_contains "${DEV}/run-local-ci.sh" '(parity|PARITY)' \
    "local ci wrapper prints a parity summary"
  assert_contains "${DEV}/run-local-ci.sh" 'ci\.yml' \
    "local ci wrapper references the workflow it mirrors"
else
  fail "cannot exercise the local ci wrapper; the script is absent or not executable"
fi

# --- CI parity -------------------------------------------------------------
# Every suite CI runs must also run locally. A suite that exists in one place
# and not the other is exactly the divergence this increment removes.
if [[ -f "${ROOT}/.github/workflows/ci.yml" && -f "${ROOT}/${VALIDATION}" ]]; then
  missing_locally=""
  while read -r suite; do
    [[ -z "${suite}" ]] && continue
    grep -q "${suite}" "${ROOT}/${VALIDATION}" || missing_locally+="${suite} "
  done < <(grep -oE 'tests/test-[a-z0-9-]+\.sh' "${ROOT}/.github/workflows/ci.yml" | sort -u)
  if [[ -z "${missing_locally}" ]]; then
    pass "every CI test suite also runs in local validation"
  else
    fail "CI runs suites that local validation omits: ${missing_locally}"
  fi

  missing_in_ci=""
  while read -r suite; do
    [[ -z "${suite}" ]] && continue
    grep -q "${suite}" "${ROOT}/.github/workflows/ci.yml" || missing_in_ci+="${suite} "
  done < <(grep -oE 'tests/test-[a-z0-9-]+\.sh' "${ROOT}/${VALIDATION}" | sort -u)
  if [[ -z "${missing_in_ci}" ]]; then
    pass "every locally validated suite also runs in CI"
  else
    fail "local validation runs suites CI omits: ${missing_in_ci}"
  fi
else
  fail "cannot compare CI and local validation; a required file is missing"
fi

# --- Documentation ---------------------------------------------------------
assert_contains "docs/development/toolchain.md" 'SHELLCHECK_VERSION' \
  "toolchain doc documents the ShellCheck pin"
assert_contains "docs/development/toolchain.md" '(exact|minimum|CI-aligned|host-observed)' \
  "toolchain doc explains pin kinds"
assert_contains "docs/development/getting-started.md" '\-\-apply' \
  "getting started documents the explicit apply flag"
assert_contains "docs/development/getting-started.md" '(dry.run|dry run)' \
  "getting started documents dry-run bootstrap"
assert_contains "docs/development/local-validation.md" '\-\-quick' \
  "local validation doc documents quick mode"
assert_contains "docs/development/local-validation.md" '(omit|skip|does not run)' \
  "local validation doc states what quick mode omits"
assert_contains "docs/development/local-validation.md" 'requirements-ci\.txt' \
  "local validation doc documents PyYAML fail-closed behaviour"

# --- CI parity: commands, not just suites ----------------------------------
# A suite list that matches is not enough; the validators and renders CI runs
# must run locally too, or "local validation passed" means less than it sounds.
CI_WORKFLOW=".github/workflows/ci.yml"
for command in 'validate_evidence\.py' 'validate_plugins\.py' \
               'ai/compose\.yaml' 'ai/ollama/compose\.yaml' 'ai/litellm/compose\.yaml'; do
  if grep -Eq "${command}" "${ROOT}/${CI_WORKFLOW}" 2>/dev/null; then
    assert_contains "${VALIDATION}" "${command}" \
      "local validation runs the CI command matching /${command}/"
  fi
done

# ShellCheck must lint the same files in both places.
SHELLCHECK_WORKFLOW=".github/workflows/shellcheck.yml"
if [[ -f "${ROOT}/${SHELLCHECK_WORKFLOW}" ]]; then
  if grep -q 'tools/dev/\*\.sh' "${ROOT}/${SHELLCHECK_WORKFLOW}"; then
    pass "CI lints tools/dev/*.sh, matching the local runner"
  else
    fail "CI must lint tools/dev/*.sh or its file list diverges from the local runner"
  fi
else
  fail "cannot compare ShellCheck file lists; ${SHELLCHECK_WORKFLOW} is missing"
fi

# The validation script must not be able to drop a suite silently: every suite
# file in tests/ is either wired in or is the wrapper's own dependency.
unwired=""
for suite_path in "${ROOT}"/tests/test-*.sh; do
  suite_name="$(basename "${suite_path}")"
  grep -q "${suite_name}" "${ROOT}/${VALIDATION}" || unwired+="${suite_name} "
done
if [[ -z "${unwired}" ]]; then
  pass "every test suite in tests/ is wired into local validation"
else
  fail "test suites exist that local validation never runs: ${unwired}"
fi

# Quick mode must document what it omits rather than silently dropping steps.
assert_contains "${VALIDATION}" 'omit' "validation documents what quick mode omits"

# --- Step counter must be self-verifying -----------------------------------
# The declared total drifted from the executed count twice during integration,
# because a suite added to full mode was skipped in quick mode. A hardcoded
# total cannot notice that. The script must check its own arithmetic at the end
# of a run, so a miscount becomes a validation failure rather than a cosmetic
# label nobody trusts.
#
# Asserted statically rather than by invoking run-validation.sh, which runs
# this suite and would recurse.
assert_contains "${VALIDATION}" 'STEP" -ne "\$\{TOTAL_STEPS|STEP != TOTAL_STEPS|STEP" != "\$\{TOTAL_STEPS' \
  "validation verifies its executed step count against its declared total"
assert_contains "${VALIDATION}" 'declared|miscount|step count' \
  "validation explains a step-count mismatch when it finds one"

# --- v0.9.0 remote suite wiring ---------------------------------------------
# Three previous sprints wired a new suite into CI but not into local
# validation. Assert both, and assert they agree.
assert_contains "${VALIDATION}" 'tests/test-remote-collectors\.sh' \
  "local validation runs the remote collector suite"
assert_contains ".github/workflows/ci.yml" 'tests/test-remote-collectors\.sh' \
  "ci runs the remote collector suite"

# Validation itself must not become a way to reach a host. Matched at command
# position only: bootstrap.sh's own comment says it never touches SSH, and a
# pattern that flags prose would punish the documentation for being explicit.
assert_absent_in "${DEV}" '(^|[;&|(]|\$\()[[:space:]]*(ssh|scp|sftp|ssh-keyscan|ssh-copy-id)[[:space:]]' \
  "developer tooling invokes no ssh client"
assert_absent_in "${DEV}" '(nmap|masscan|StrictHostKeyChecking)' \
  "developer tooling performs no scanning or host-key configuration"

# --- v0.9.2 trust plane suite wiring ----------------------------------------
assert_contains "${VALIDATION}" 'tests/test-trust-plane\.sh' \
  "local validation runs the trust plane suite"
assert_contains ".github/workflows/ci.yml" 'tests/test-trust-plane\.sh' \
  "ci runs the trust plane suite"

# --- v0.9.3 trust runtime suite wiring --------------------------------------
assert_contains "${VALIDATION}" 'tests/test-trust-runtime\.sh' \
  "local validation runs the trust runtime suite"
assert_contains ".github/workflows/ci.yml" 'tests/test-trust-runtime\.sh' \
  "ci runs the trust runtime suite"
for trust_prefix in TAUTH TREC TDEC TSCOPE TEVID TAUDIT; do
  assert_contains "${VALIDATION}" "${trust_prefix}" \
    "the runtime-record backstop covers ${trust_prefix}"
done

# --- v0.9.4 trust migration suite wiring ------------------------------------
assert_contains "${VALIDATION}" 'tests/test-trust-migration\.sh' \
  "local validation runs the trust migration suite"
assert_contains ".github/workflows/ci.yml" 'tests/test-trust-migration\.sh' \
  "ci runs the trust migration suite"

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nDeveloper experience validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nDeveloper experience validation passed.\n'
