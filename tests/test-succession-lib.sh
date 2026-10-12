#!/usr/bin/env bash
set -Eeuo pipefail

# tests/lib/succession.sh -- the generation-succession primitive, proven.
#
# Six host-only suites now depend on this file to rewind a fixture built from
# the live host back to the generation they reconstruct. Before it existed each
# of them carried its own spelling of that idea, and the Generation-15
# installation broke all six at once because no spelling knew about it.
#
# So the shared thing needs its own proof, and the proof that matters is not
# "it rewinds" -- it is that it CANNOT be used to make a fixture agree with
# whatever the host happens to hold. A rewind is driven by governed matrix data
# and a named historical commit, it leaves everything else exactly as found, and
# it fails loudly rather than quietly when it cannot do what it was asked.
#
# PORTABLE. No production path is read or written; every fixture is a temporary
# directory and every ceremony is written by the test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/succession.sh
. "${SCRIPT_DIR}/lib/succession.sh"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# A ceremony is just a file with a MATRIX=( ... ) block, so the fixtures below
# are written rather than borrowed: the primitive is under test, not any real
# generation's data.
write_ceremony() {
  local path="$1"; shift
  { printf 'MATRIX=(\n'; printf '%s\n' "$@"; printf ')\n'; } > "${path}"
}

# ===========================================================================
# A. reading a matrix
# ===========================================================================

C1="${WORK}/ceremony-one.sh"
# shellcheck disable=SC2016  # the matrix carries the literal placeholder
write_ceremony "${C1}" \
  '"src/a.py|${LIBRARY_ROOT}/a.py|0444|REPLACE|aaa|bbb|G"' \
  '"src/b.py|${LIBRARY_ROOT}/b.py|0444|CREATE|ABSENT|ccc|G"' \
  '"src/c.py|/usr/libexec/c-thing|0555|CREATE|ABSENT|ddd|G"'

created="$(succession_created_by "${C1}" | sort | tr '\n' ' ')"
if [[ "${created}" == "b.py " ]]; then
  pass "created_by returns the library-root CREATE rows only"
else
  fail "created_by returned '${created}', expected 'b.py '"
fi

rows="$(succession_library_rows "${C1}" | tr '\n' ';')"
if [[ "${rows}" == "a.py REPLACE src/a.py;b.py CREATE src/b.py;" ]]; then
  pass "library_rows skips the /usr/libexec row, which was never library surface"
else
  fail "library_rows returned '${rows}'"
fi

if [[ -z "$(succession_created_by "${WORK}/not-a-ceremony.sh")" ]]; then
  pass "a ceremony that does not exist contributes nothing"
else
  fail "a missing ceremony produced rows"
fi

# ===========================================================================
# B. rewinding, against this repository's real history
# ===========================================================================
#
# The commit and paths here are real, because the point of the primitive is to
# restore BYTES from a named historical commit. Which commit does not matter --
# only that the restored object is that commit's, and not the live host's.

COMMIT="946be553ab9f25542590eb908c42ce14a81d6ec3"
SOURCE="tools/capability/execution/helpers.py"
WANT="$(git -C "${ROOT}" show "${COMMIT}:${SOURCE}" | sha256sum | cut -d' ' -f1)"

C2="${WORK}/ceremony-two.sh"
# shellcheck disable=SC2016  # the matrix carries the literal placeholder
write_ceremony "${C2}" \
  "\"${SOURCE}|\${LIBRARY_ROOT}/helpers.py|0444|REPLACE|old|new|G\"" \
  '"x/y.py|${LIBRARY_ROOT}/created.py|0444|CREATE|ABSENT|zzz|G"'

build_lib() {
  local lib="$1"
  rm -rf "${lib}"; mkdir -p "${lib}"
  printf 'SUCCESSOR BYTES, not the generation being reconstructed\n' > "${lib}/helpers.py"
  printf 'an object a later ceremony created\n' > "${lib}/created.py"
  printf 'a carried-over object no ceremony declares\n' > "${lib}/untouched.py"
  chmod 0444 "${lib}"/*.py
}

LIB="${WORK}/lib"; build_lib "${LIB}"
if succession_rewind "${LIB}" "${ROOT}" "${COMMIT}" "${C2}"; then
  pass "rewind reports success on a matrix it can satisfy"
else
  fail "rewind failed on a satisfiable matrix"
fi

if [[ "$(sha256sum "${LIB}/helpers.py" | cut -d' ' -f1)" == "${WANT}" ]]; then
  pass "rewind restores a REPLACE row to the named commit's bytes"
else
  fail "helpers.py is not the commit's bytes"
fi

if [[ ! -e "${LIB}/created.py" ]]; then
  pass "rewind removes a CREATE row's pathname"
else
  fail "created.py survived the rewind"
fi

if [[ "$(stat -c '%a' "${LIB}/helpers.py")" == "444" ]]; then
  pass "a restored object carries the mode a real host carries"
else
  fail "helpers.py is mode $(stat -c '%a' "${LIB}/helpers.py"), expected 444"
fi

# THE ANTI-WEAKENING PROPERTY. An object no listed ceremony declares must come
# through untouched, so drift in it still reaches the assertions that refuse it.
if [[ "$(cat "${LIB}/untouched.py")" == "a carried-over object no ceremony declares" ]]; then
  pass "an object no ceremony declares is left exactly as found, so drift still surfaces"
else
  fail "the rewind altered an object no ceremony declares"
fi

# ===========================================================================
# C. a bogus successor must not quietly become acceptable
# ===========================================================================

# A REPLACE row whose source does not exist at the commit cannot be restored.
# Silently leaving the successor's bytes there is the failure mode this whole
# checkpoint exists to end, so it must report.
C3="${WORK}/ceremony-bogus.sh"
# shellcheck disable=SC2016  # the matrix carries the literal placeholder
write_ceremony "${C3}" \
  '"tools/does/not/exist.py|${LIBRARY_ROOT}/helpers.py|0444|REPLACE|old|new|G"'

build_lib "${LIB}"
if succession_rewind "${LIB}" "${ROOT}" "${COMMIT}" "${C3}" 2>/dev/null; then
  fail "a REPLACE row with no source at the commit was accepted"
else
  pass "a REPLACE row whose source the commit does not carry is refused"
fi

if [[ "$(cat "${LIB}/helpers.py")" == "SUCCESSOR BYTES, not the generation being reconstructed" ]]; then
  pass "the unsatisfiable rewind left the object alone rather than half-restoring it"
else
  fail "the failed rewind still modified the object"
fi

# An operation the primitive cannot undo must report rather than be skipped.
C4="${WORK}/ceremony-remove.sh"
# shellcheck disable=SC2016  # the matrix carries the literal placeholder
write_ceremony "${C4}" \
  '"src/a.py|${LIBRARY_ROOT}/helpers.py|0444|REMOVE|old|ABSENT|G"'

build_lib "${LIB}"
if succession_rewind "${LIB}" "${ROOT}" "${COMMIT}" "${C4}" 2>/dev/null; then
  fail "an operation the rewind cannot undo was accepted"
else
  pass "an operation the rewind cannot undo is refused rather than skipped"
fi

# ===========================================================================
# D. the primitive writes nothing outside the fixture
# ===========================================================================

before="$(git -C "${ROOT}" status --porcelain | sha256sum)"
build_lib "${LIB}"
succession_rewind "${LIB}" "${ROOT}" "${COMMIT}" "${C2}" >/dev/null 2>&1 || true
after="$(git -C "${ROOT}" status --porcelain | sha256sum)"
if [[ "${before}" == "${after}" ]]; then
  pass "a rewind leaves the repository untouched -- historical evidence is read, never rewritten"
else
  fail "the repository changed during a rewind"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'succession primitive validation passed.\n'
else
  printf 'succession primitive validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
