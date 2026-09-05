#!/usr/bin/env bash
set -Eeuo pipefail

# What the generation declaration may call development, and what it must refuse.
#
# UNPRIVILEGED AND ISOLATED. No sudo, no helper, no Podman, no production path.
# The functions under test are extracted from the real preflight by name, so
# this proves the shipped bytes rather than a copy of them; a rename breaks the
# extraction loudly instead of silently testing nothing.
#
# WHAT THIS EXISTS FOR
# ====================
# The declaration models a TRANSITION: an installed object may hold the declared
# baseline (pending) or the declared new bytes (applied). Until G11-BB the
# CHECKOUT side was a single value, deliberately -- widening it looked like
# letting unreviewed bytes in.
#
# That left a reviewed correction inexpressible. When the checkout moves past
# the declared target -- which is exactly what a reviewed, not-yet-installed
# correction is -- a single-valued row has no verdict for it but drift. The
# artefact reported reviewed source as corruption, and the only way to quiet it
# would have been to rewrite the historical digest it had already accepted,
# which is the one thing a declaration must never do.
#
# So both sides widen, and both ONLY by explicit declaration. The three cases:
#
#   A  installed is an accepted predecessor, checkout is a declared successor
#      -> accepted-installed-predecessor. PASS. NOT drift.
#   B  installed is itself a declared successor
#      -> known-successor-applied. PASS. Keeps the artefact useful after the
#         successor is installed.
#   C  installed or checkout is neither
#      -> unknown-drift. REFUSE.
#
# The refusals below are the point. A list is not a wildcard: there is no
# "anything newer", no "any commit after the baseline", and nothing derived
# from git. Every admissible digest on either side is written down and reviewed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFLIGHT="${ROOT}/provisioning/execution/g5-preflight.sh"

FAILURES=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- the real functions, by name -------------------------------------------
extract() {
  local name="$1" body
  body="$(sed -n "/^${name}() {\$/,/^}\$/p" "${PREFLIGHT}")"
  if [[ -z "${body}" ]]; then
    fail "could not extract ${name} from the preflight -- was it renamed?"
    exit 1
  fi
  printf '%s\n' "${body}"
}

# Both are called only from the functions extracted below, which shellcheck
# cannot follow through `eval`.
# shellcheck disable=SC2317
field() { printf '%s' "$1" | cut -d'|' -f"$(( $2 + 1 ))"; }
# shellcheck disable=SC2317
digest_of() {
  [[ -e "$1" ]] || { printf ''; return; }
  sha256sum "$1" | cut -d' ' -f1
}

eval "$(extract generation_declares)"
eval "$(extract generation_row_coherent)"
pass "the real generation_declares and generation_row_coherent were extracted"

# --- a fixture declaration, in the shipped format ---------------------------
#   source_path|operation|installed_baselines|declared_successors
BASE_A="aaaa000000000000000000000000000000000000000000000000000000000000"
BASE_B="bbbb000000000000000000000000000000000000000000000000000000000000"
SUCC_1="1111000000000000000000000000000000000000000000000000000000000000"
SUCC_2="2222000000000000000000000000000000000000000000000000000000000000"
STRANGER="ffff000000000000000000000000000000000000000000000000000000000000"

# shellcheck disable=SC2034  # read by the functions extracted above
GENERATION_DELTA=(
"lib/replaced.py|REPLACE|${BASE_A},${BASE_B}|${SUCC_1},${SUCC_2}"
"lib/created.py|CREATE|ABSENT|${SUCC_1},${SUCC_2}"
"lib/single.py|REPLACE|${BASE_A}|${SUCC_1}"
)

declares() {
  if generation_declares "$1" "$2" "$3"; then echo yes; else echo no; fi
}

# --- CASE A: accepted installed predecessor, reviewed successor source ------
if [[ "$(declares lib/replaced.py "${BASE_A}" "${SUCC_2}")" == yes ]]; then
  pass "A: accepted predecessor + declared successor source is development"
else
  fail "A: accepted predecessor + declared successor source was refused"
fi

if [[ "$(declares lib/replaced.py "${BASE_B}" "${SUCC_2}")" == yes ]]; then
  pass "A: a second accepted predecessor is equally admissible"
else
  fail "A: the second declared baseline was refused"
fi

# The hop that existed before the correction must keep working.
if [[ "$(declares lib/replaced.py "${BASE_A}" "${SUCC_1}")" == yes ]]; then
  pass "A: the original single-hop transition still classifies"
else
  fail "A: widening broke the original transition"
fi

# --- CASE C: unknown bytes, either side -------------------------------------
if [[ "$(declares lib/replaced.py "${STRANGER}" "${SUCC_2}")" == no ]]; then
  pass "C: an installed digest in neither list is refused"
else
  fail "C: unknown installed bytes were accepted"
fi

if [[ "$(declares lib/replaced.py "${BASE_A}" "${STRANGER}")" == no ]]; then
  pass "C: a checkout digest that is not a declared successor is refused"
else
  fail "C: unreviewed checkout bytes were accepted as development"
fi

if [[ "$(declares lib/undeclared.py "${BASE_A}" "${SUCC_1}")" == no ]]; then
  pass "C: an object with no row at all is refused"
else
  fail "C: an undeclared object was accepted"
fi

# A single-successor row must not gain a second by accident.
if [[ "$(declares lib/single.py "${BASE_A}" "${SUCC_2}")" == no ]]; then
  pass "C: a successor not named on THIS row is refused"
else
  fail "C: a successor declared elsewhere leaked into another row"
fi

# Requirement 10: a later successor does not retroactively bless unrelated
# historical bytes. SUCC_2 is declared for replaced.py; it must not make
# STRANGER admissible anywhere, nor make itself an admissible BASELINE.
if [[ "$(declares lib/replaced.py "${SUCC_2}" "${STRANGER}")" == no ]]; then
  pass "10: a declared successor does not make unrelated bytes admissible"
else
  fail "10: a successor retroactively accepted unrelated bytes"
fi

# --- CREATE is handled distinctly ------------------------------------------
if [[ "$(declares lib/created.py "${SUCC_1}" "${SUCC_2}")" == yes ]]; then
  pass "9: an applied CREATE advancing along its chain is development"
else
  fail "9: an applied CREATE could not advance"
fi

if [[ "$(declares lib/created.py "${SUCC_2}" "${SUCC_1}")" == no ]]; then
  pass "9: a CREATE chain will not run backwards"
else
  fail "9: a downgrade was accepted as development"
fi

if [[ "$(declares lib/created.py "${BASE_A}" "${SUCC_2}")" == no ]]; then
  pass "9: a CREATE whose installed bytes are undeclared is refused"
else
  fail "9: undeclared bytes under a CREATE row were accepted"
fi

# --- CASE B: already applied, via generation_row_coherent -------------------
LIBRARY_ROOT="${WORK}/lib-root"
mkdir -p "${LIBRARY_ROOT}/lib"

applied_at() {
  local digest="$1" target="${LIBRARY_ROOT}/lib/replaced.py" candidate
  # Manufacture a file with the wanted digest by search is impossible, so the
  # coherence check is driven through a stub digest_of instead -- the function
  # reads bytes only through it.
  # shellcheck disable=SC2317  # called from the extracted coherence function
  digest_of() { printf '%s' "${digest}"; }
  : "${target}" "${candidate:-}"
  if generation_row_coherent lib/replaced.py REPLACE "${SUCC_1},${SUCC_2}" \
       "${BASE_A},${BASE_B}"; then echo yes; else echo no; fi
}

touch "${LIBRARY_ROOT}/lib/replaced.py"
if [[ "$(applied_at "${SUCC_2}")" == yes ]]; then
  pass "B: an installed newest successor is applied, not a failure"
else
  fail "B: the applied newest successor was rejected"
fi

if [[ "$(applied_at "${SUCC_1}")" == yes ]]; then
  pass "B: an installed earlier successor is applied at that hop"
else
  fail "B: an earlier declared hop was rejected"
fi

if [[ "$(applied_at "${STRANGER}")" == no ]]; then
  pass "B: installed bytes in neither list are still refused"
else
  fail "B: unknown installed bytes passed the coherence check"
fi

# --- verification mutates nothing ------------------------------------------
before="$(find "${WORK}" -printf '%p %s\n' | sort | sha256sum)"
declares lib/replaced.py "${BASE_A}" "${SUCC_2}" >/dev/null
applied_at "${SUCC_2}" >/dev/null
after="$(find "${WORK}" -printf '%p %s\n' | sort | sha256sum)"
if [[ "${before}" == "${after}" ]]; then
  pass "12: classification mutates nothing"
else
  fail "12: classification changed the tree"
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Generation succession validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'Generation succession validation passed.\n'
