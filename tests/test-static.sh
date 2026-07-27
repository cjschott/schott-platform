#!/usr/bin/env bash
set -Eeuo pipefail

# Static repository assertions for the Schott Platform AI baseline.
#
# This test is extended task-by-task. It must be runnable from anywhere and
# must not require the schai VM, Docker daemon access, or any secret.
#
# Scope currently implemented: Task 1 (repository foundation).

# Resolve repository root relative to this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
}

# assert_file <relative-path>
assert_file() {
  local rel="$1"
  if [[ -f "${ROOT}/${rel}" ]]; then
    pass "file exists: ${rel}"
  else
    fail "required file missing: ${rel}"
  fi
}

# assert_dir <relative-path>
assert_dir() {
  local rel="$1"
  if [[ -d "${ROOT}/${rel}" ]]; then
    pass "directory exists: ${rel}"
  else
    fail "required directory missing: ${rel}"
  fi
}

# assert_ignored <relative-path>  — path must be excluded by .gitignore
assert_ignored() {
  local rel="$1"
  if git -C "${ROOT}" check-ignore -q "${rel}"; then
    pass "git-ignored: ${rel}"
  else
    fail "path should be git-ignored but is not: ${rel}"
  fi
}

# assert_not_ignored <relative-path>  — path must NOT be excluded by .gitignore
assert_not_ignored() {
  local rel="$1"
  if git -C "${ROOT}" check-ignore -q "${rel}"; then
    fail "path should NOT be git-ignored but is: ${rel}"
  else
    pass "not git-ignored: ${rel}"
  fi
}

# ---------------------------------------------------------------------------
# Task 1: Repository foundation
# ---------------------------------------------------------------------------

# Required top-level foundation files.
assert_file "README.md"
assert_file "CHANGELOG.md"
assert_file ".gitignore"
assert_file ".editorconfig"
assert_file "ai/README.md"
assert_file "tests/test-static.sh"

# Required foundation directories.
assert_dir "ai"
assert_dir "docs"
assert_dir "tests"

# Every shell script must declare the bash shebang and strict mode.
while IFS= read -r script; do
  first_line="$(head -n 1 "${script}")"
  if [[ "${first_line}" != "#!/usr/bin/env bash" ]]; then
    fail "shell script missing '#!/usr/bin/env bash' shebang: ${script#"${ROOT}/"}"
  elif ! grep -qE '^set -Eeuo pipefail$' "${script}"; then
    fail "shell script missing 'set -Eeuo pipefail': ${script#"${ROOT}/"}"
  else
    pass "shell script conforms to standards: ${script#"${ROOT}/"}"
  fi
done < <(find "${ROOT}" -type f -name '*.sh' -not -path '*/.git/*')

# Local environment files must be ignored.
assert_ignored ".env"
assert_ignored "ai/.env"
assert_ignored "ai/litellm/.env"
assert_ignored "ai/ollama/.env"

# Sanitized example env files must remain tracked.
assert_not_ignored "ai/.env.example"
assert_not_ignored "ai/litellm/.env.example"

# Secret, runtime, and model/data directories must be ignored.
assert_ignored "secrets/key"
assert_ignored "backups/backup.tar.gz"
assert_ignored "logs/litellm.log"
assert_ignored "models/blob"
assert_ignored "data/ollama/blob"
assert_ignored ".superpowers/state"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if (( FAILURES > 0 )); then
  printf '\n%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nAll static assertions passed.\n'
