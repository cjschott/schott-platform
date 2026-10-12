#!/usr/bin/env bash
set -Eeuo pipefail

# The G11-BC-G evidence remediation, proven in a fixture.
#
# UNPRIVILEGED AND ISOLATED. Every path the ceremony touches is rebound under
# --fixture. No production evidence file is read for state and none is written;
# no sudo, no helper, no installer, no container.
#
# WHAT THIS REMEDIATES
# ====================
# The G11-BC-E helper ceremony wrote its evidence to G11-BB's pathname, under
# G11-BB's name, claiming Generation 14. This ceremony archives that artifact,
# reconstructs G11-BB's evidence from reviewed sources, and records G11-BC-E's
# at its correct path.
#
# WHAT THE CASES ARE FOR
# ======================
# Evidence remediation is the one operation here whose whole product is a claim
# about the past, so the cases weigh heavily toward what it must REFUSE and
# toward the honesty of what it writes:
#
#   * it must not touch a file that could be genuine G11-BB evidence
#   * it must never overwrite an evidence file -- that is the defect itself
#   * the reconstruction must say it is a reconstruction, in the content
#   * fields that cannot be recovered must say so rather than be invented
#   * an interrupted run must be distinguishable from a complete one

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${ROOT}/provisioning/execution/remediate-g11-bc-g-evidence.sh"
OPERATOR="${ROOT}/provisioning/execution/g11-bc-g-evidence-remediation-ceremony.txt"

# HOST-ONLY: the fixture carries the installed helper objects, because the
# ceremony verifies the deployment its evidence would describe is the one
# actually installed. There is nothing to verify against on a machine with no
# installed runtime.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python          # prod-path-reference

# Read from the ceremony rather than restated, so the two cannot drift.
BCE_COMMIT="$(sed -n 's/^BCE_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${CEREMONY}")"
BB_COMMIT="$(sed -n 's/^BB_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${CEREMONY}")"
BCE_TARGET="$(sed -n 's/^BCE_TARGET="\([0-9a-f]\{64\}\)"$/\1/p' "${CEREMONY}")"
[[ -n "${BCE_COMMIT}" && -n "${BB_COMMIT}" && -n "${BCE_TARGET}" ]] \
  || { printf 'cannot read the ceremony authorities\n' >&2; exit 1; }

STAMP="2026-09-13T12:00:00-05:00"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

DEF="root/kyri-g11-bb-helper-digests.txt"
ARC="root/kyri-g11-bb-helper-digests.defective-bc-e.txt"
BBR="root/kyri-g11-bb-helper-digests.reconstructed.txt"
BCE="root/kyri-g11-bc-e-helper-digests.txt"

# A host carrying the installed helper surface and the defective artifact the
# G11-BC-E run left behind. The artifact is written in the shape that run
# produced -- self-identifying as g11-bb-helpers while carrying BC-E's commit
# and target, which is precisely the contradiction the ceremony detects.
build_host() {
  local root="$1"
  rm -rf "${root}"
  mkdir -p "${root}/root" "${root}/usr/libexec" \
           "${root}/usr/lib/kyri/python/tools/capability/execution"   # prod-path-reference
  install -m 0444 /usr/lib/kyri/python/kyri_exec_transition_action.py \
    "${root}/usr/lib/kyri/python/"                                    # prod-path-reference
  install -m 0444 /usr/lib/kyri/python/kyri_exec_quota.py \
    "${root}/usr/lib/kyri/python/"                                    # prod-path-reference
  install -m 0444 /usr/libexec/kyri-exec-worker.py "${root}/usr/libexec/"  # prod-path-reference
  install -m 0444 /usr/lib/kyri/python/tools/capability/execution/helpers.py \
    "${root}/usr/lib/kyri/python/tools/capability/execution/"         # prod-path-reference
  {
    printf 'ceremony g11-bb-helpers\n'
    printf 'commit %s\n' "${BCE_COMMIT}"
    printf 'runtime_commit %s\n' "${BCE_COMMIT}"
    printf 'runtime_generation 14\n'
    printf 'transaction g11-bb-20260912T170000Z-4242\n'
    printf 'state COMMITTED\n'
    printf 'objects 1\nreplaced 1\ncreated 0\n'
    printf 'delta REPLACE /usr/lib/kyri/python/kyri_exec_transition_action.py '
    printf 'b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315 %s INSIDE\n' "${BCE_TARGET}"
  } > "${root}/${DEF}"
  chmod 0400 "${root}/${DEF}"
}

run_ceremony() {
  local root="$1"; shift
  ( cd "${ROOT}" && bash "${CEREMONY}" "$@" --fixture "${root}" --stamp "${STAMP}" ) \
    > "${WORK}/last.log" 2>&1
}

# ===========================================================================
# A. clean remediation
# ===========================================================================

root="${WORK}/clean"; build_host "${root}"
before_defective="$(sha256sum "${root}/${DEF}" | cut -d' ' -f1)"

if run_ceremony "${root}" --verify; then
  pass "clean: --verify accepts the defective host and writes nothing"
else
  fail "clean: --verify refused: $(grep -m1 -E '^(STOP|FAIL)' "${WORK}/last.log")"
fi
if [[ -f "${root}/${DEF}" && ! -e "${root}/${ARC}" && ! -e "${root}/${BBR}" \
      && ! -e "${root}/${BCE}" ]]; then
  pass "clean: --verify left the tree exactly as it found it"
else
  fail "clean: --verify mutated the tree"
fi

if run_ceremony "${root}" --apply; then
  pass "clean: --apply completes"
else
  fail "clean: --apply failed: $(grep -m1 -E '^(STOP|FAIL)' "${WORK}/last.log")"
fi

# The defective bytes survive, byte for byte.
if [[ "$(sha256sum "${root}/${ARC}" | cut -d' ' -f1)" == "${before_defective}" ]]; then
  pass "clean: the defective artifact is preserved byte-for-byte in the archive"
else
  fail "clean: the archived bytes differ from the artifact"
fi

# The canonical pathname is left absent, deliberately.
if [[ ! -e "${root}/${DEF}" ]]; then
  pass "clean: the canonical G11-BB pathname is left ABSENT, not recreated"
else
  fail "clean: a file was written back to the canonical G11-BB pathname"
fi

for produced in "${BBR}" "${BCE}"; do
  if [[ -f "${root}/${produced}" ]]; then
    pass "clean: wrote ${produced##*/}"
  else
    fail "clean: ${produced##*/} was not written"
  fi
  if [[ "$(stat -c '%a' "${root}/${produced}")" == "400" ]]; then
    pass "clean: ${produced##*/} is 0400"
  else
    fail "clean: ${produced##*/} is mode $(stat -c '%a' "${root}/${produced}")"
  fi
done

# ===========================================================================
# B. the reconstruction is HONEST about being one
# ===========================================================================

bb="${root}/${BBR}"
for required in "evidence_status reconstructed" \
                "not_original_ceremony_output true" \
                "installed_state_unchanged_by_reconstruction true" \
                "reconstructed_at ${STAMP}" \
                "transaction UNRECOVERABLE"; do
  if grep -qF "${required}" "${bb}"; then
    pass "reconstruction states: ${required}"
  else
    fail "reconstruction is missing: ${required}"
  fi
done

# It records the TRUTH about the generation, and says what the lost artifact
# said -- rather than reproducing a known-false field.
if grep -q "^runtime_generation 15\$" "${bb}" \
   && grep -q "^runtime_generation_in_lost_artifact 14\$" "${bb}"; then
  pass "reconstruction records generation 15 and notes the lost artifact said 14"
else
  fail "reconstruction does not correct and disclose the generation"
fi

# Every reconstructed fact names where it came from.
for sourced in "delta_source" "installed_source" "runtime_readiness_source" \
               "reconstruction_reason" "defect_report"; do
  if grep -q "^${sourced} " "${bb}"; then
    pass "reconstruction cites its source for: ${sourced}"
  else
    fail "reconstruction gives no source for: ${sourced}"
  fi
done

# The installed digests it records are G11-BB's, NOT today's -- one of them has
# since moved, and recording today's would be a false claim about the past.
if grep -q "^installed b11a2f19" "${bb}" && ! grep -q "^installed ${BCE_TARGET}" "${bb}"; then
  pass "reconstruction records G11-BB's installed digests, not today's"
else
  fail "reconstruction recorded a digest that was not installed at G11-BB"
fi
if grep -q "^installed_note .*has since moved to ${BCE_TARGET}" "${bb}"; then
  pass "reconstruction discloses that the action module has since moved"
else
  fail "reconstruction does not disclose the later move"
fi

bce="${root}/${BCE}"
if grep -q "^ceremony g11-bc-e-helpers\$" "${bce}" \
   && grep -q "^runtime_generation 17\$" "${bce}"; then
  pass "the G11-BC-E evidence identifies its own ceremony and generation 17"
else
  fail "the G11-BC-E evidence misidentifies itself"
fi
if grep -q "^commit ${BCE_COMMIT}\$" "${bce}" && grep -q "${BCE_TARGET}" "${bce}"; then
  pass "the G11-BC-E evidence carries its reviewed commit and target"
else
  fail "the G11-BC-E evidence does not carry its authority"
fi
if grep -q "^evidence_status reconstructed\$" "${bce}"; then
  pass "the G11-BC-E evidence also says it was recorded after the fact"
else
  fail "the G11-BC-E evidence claims to be original ceremony output"
fi

# ===========================================================================
# C. refusals
# ===========================================================================

# The three destinations, as an existence-and-digest fingerprint.
destinations_of() {
  local d
  for d in "${ARC}" "${BBR}" "${BCE}"; do
    if [[ -e "$1/${d}" ]]; then
      printf '%s %s\n' "${d}" "$(sha256sum "$1/${d}" | cut -d' ' -f1)"
    else
      printf '%s ABSENT\n' "${d}"
    fi
  done
}

# The expected reason is REQUIRED, not decorative. "it exited non-zero" is a
# weak assertion: a refusal for an incidental reason -- a typo in a path, a
# missing fixture file -- would satisfy it while proving nothing about the gate
# under test. Each case names the sentence the operator must actually see.
refuses() {          # <case> <description> <mutator> <expected reason substring>
  local name="$1" description="$2" mutator="$3" reason="$4"
  local r="${WORK}/r-${name}"; build_host "${r}"
  # The installed objects are copied 0444, as a real host carries them, so a
  # mutator perturbing one needs write first.
  chmod -R u+w "${r}"
  "${mutator}" "${r}"
  local before; before="$(destinations_of "${r}")"
  if run_ceremony "${r}" --apply; then
    fail "${description} was accepted"
    return
  fi
  if grep -qF "${reason}" "${WORK}/last.log"; then
    pass "${description} is refused, naming: ${reason}"
  else
    fail "${description} was refused for the wrong reason: $(grep -m1 -E '^(STOP|FAIL)' "${WORK}/last.log")"
  fi
  # A refusal writes nothing. Compared against a snapshot taken before the run
  # rather than against "absent", because the collision cases deliberately plant
  # a destination and that planted file must survive untouched too.
  if [[ "$(destinations_of "${r}")" == "${before}" ]]; then
    pass "${description}: the refusal wrote nothing"
  else
    fail "${description}: the refusal left something behind"
  fi
}

# The single most important refusal: a file that might be GENUINE G11-BB
# evidence must never be archived or replaced.
genuine_bb() {
  { printf 'ceremony g11-bb-helpers\n'
    printf 'commit %s\n' "${BB_COMMIT}"
    printf 'runtime_generation 14\n'
    printf 'state COMMITTED\n'; } > "$1/${DEF}"
}
refuses genuine    "an artifact carrying the G11-BB commit (possibly genuine)" genuine_bb \
  "must NOT be archived"

not_bce()      { printf 'ceremony something-else\nstate COMMITTED\n' > "$1/${DEF}"; }
refuses foreign    "an artifact that does not self-identify as g11-bb-helpers" not_bce \
  "does not self-identify as g11-bb-helpers"

no_target()    { grep -v "${BCE_TARGET}" "$1/${DEF}" > "$1/x" && mv "$1/x" "$1/${DEF}"; }
refuses notarget   "an artifact that never mentions the G11-BC-E target" no_target \
  "does not mention the G11-BC-E target"

missing_def()  { rm -f "$1/${DEF}"; }
refuses absent     "no defective artifact to remediate" missing_def \
  "there is nothing to archive"

wrong_action() { printf '# not the deployed action module\n' > "$1/usr/lib/kyri/python/kyri_exec_transition_action.py"; }
refuses helper     "an installed action module that is not the G11-BC-E target" wrong_action \
  "the deployment this evidence would describe is not the one installed"

wrong_rule()   { printf '# not the Generation-17 rule\n' \
  > "$1/usr/lib/kyri/python/tools/capability/execution/helpers.py"; }
refuses runtime    "an installed runtime that is not Generation 17" wrong_rule \
  "this evidence would name a generation the host is not at"

drifted_bb()   { printf '# drift\n' >> "$1/usr/lib/kyri/python/kyri_exec_quota.py"; }
refuses drifted    "a G11-BB object that no longer matches what G11-BB-R measured" drifted_bb \
  "and G11-BB-R records"

collide_arc()  { printf 'x\n' > "$1/${ARC}"; }
refuses c-arc      "an archive destination that already exists" collide_arc \
  "kyri-g11-bb-helper-digests.defective-bc-e.txt already exists"
collide_bbr()  { printf 'x\n' > "$1/${BBR}"; }
refuses c-bbr      "a reconstruction destination that already exists" collide_bbr \
  "kyri-g11-bb-helper-digests.reconstructed.txt already exists"
collide_bce()  { printf 'x\n' > "$1/${BCE}"; }
refuses c-bce      "a G11-BC-E destination that already exists" collide_bce \
  "kyri-g11-bc-e-helper-digests.txt already exists"

# ===========================================================================
# D. rerun after completion
# ===========================================================================

if run_ceremony "${root}" --apply; then
  fail "rerun: a completed remediation was applied a second time"
else
  pass "rerun: a completed remediation refuses to run again"
fi
if grep -qE "already exists|journal already exists" "${WORK}/last.log"; then
  pass "rerun: it refuses because the destinations and journal are already there"
else
  fail "rerun: refused for an unexpected reason: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi
if [[ "$(sha256sum "${root}/${ARC}" | cut -d' ' -f1)" == "${before_defective}" ]]; then
  pass "rerun: the archive is untouched by the refused rerun"
else
  fail "rerun: the archive changed"
fi

# ===========================================================================
# E. interruption
# ===========================================================================
#
# Every boundary must leave a state that is distinguishable and either
# recoverable or explicitly operator-disposed. The archive is the hinge: before
# it, rollback is total; after it, the defective bytes are already safe and the
# run must not silently redo itself.

state_of() { sed -n 's/^state=//p' "$1/root/kyri-evidence-remediation-transaction/journal" 2>/dev/null | tail -1; }

# Interrupted mid-archive: the source still exists, so rollback is complete.
r="${WORK}/i-archiving"; build_host "${r}"
mkdir -p "${r}/root/kyri-evidence-remediation-transaction"
printf 'state=ARCHIVING\n' > "${r}/root/kyri-evidence-remediation-transaction/journal"
printf 'partial\n' > "${r}/${ARC}"
if run_ceremony "${r}" --recover; then
  pass "interrupted at ARCHIVING: --recover rolls back"
else
  fail "interrupted at ARCHIVING: --recover failed: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi
if [[ -f "${r}/${DEF}" && ! -e "${r}/${ARC}" && -z "$(state_of "${r}")" ]]; then
  pass "interrupted at ARCHIVING: the tree is back to pre-remediation and rerunnable"
else
  fail "interrupted at ARCHIVING: rollback left residue"
fi
if run_ceremony "${r}" --apply; then
  pass "interrupted at ARCHIVING: a rerun after rollback completes"
else
  fail "interrupted at ARCHIVING: the rerun failed"
fi

# Interrupted after the archive, and after the first evidence publication.
# Both are past the point where the defective bytes are durable, so neither may
# be silently resumed: the ceremony demands operator disposition.
for point in ARCHIVED BB_PUBLISHED; do
  r="${WORK}/i-${point}"; build_host "${r}"
  mkdir -p "${r}/root/kyri-evidence-remediation-transaction"
  cp -a "${r}/${DEF}" "${r}/${ARC}"; rm -f "${r}/${DEF}"
  [[ "${point}" == "BB_PUBLISHED" ]] && printf 'partial\n' > "${r}/${BBR}"
  printf 'state=%s\n' "${point}" > "${r}/root/kyri-evidence-remediation-transaction/journal"
  if run_ceremony "${r}" --recover; then
    fail "interrupted at ${point}: --recover silently resumed"
  elif grep -q "operator disposition" "${WORK}/last.log"; then
    pass "interrupted at ${point}: --recover requires operator disposition"
  else
    fail "interrupted at ${point}: refused for an unrelated reason"
  fi
  if [[ "$(sha256sum "${r}/${ARC}" | cut -d' ' -f1)" == "${before_defective}" ]]; then
    pass "interrupted at ${point}: the archived bytes are intact"
  else
    fail "interrupted at ${point}: the archive was disturbed"
  fi
done

# A completed run is recognised as complete rather than resumed.
if run_ceremony "${root}" --recover && grep -q "remediation is complete" "${WORK}/last.log"; then
  pass "a completed remediation is recognised by --recover, not redone"
else
  fail "--recover did not recognise a completed remediation"
fi

# ===========================================================================
# F. the ceremony changes nothing it must not
# ===========================================================================

r="${WORK}/isolation"; build_host "${r}"
runtime_before="$(find "${r}/usr" -type f -exec sha256sum {} \; | sort | sha256sum)"
run_ceremony "${r}" --apply || true
if [[ "$(find "${r}/usr" -type f -exec sha256sum {} \; | sort | sha256sum)" == "${runtime_before}" ]]; then
  pass "isolation: no installed runtime or helper object changed"
else
  fail "isolation: the ceremony altered an installed object"
fi
if ! grep -qE "capability-runtime|capability-handoff|/var/lib/kyri" "${CEREMONY}"; then
  pass "isolation: the ceremony names no capability store, handoff, Fabric or Trust path"
else
  fail "isolation: the ceremony reaches a store it has no business reading"
fi

# ===========================================================================
# G. the operator block
# ===========================================================================

if [[ -f "${OPERATOR}" ]]; then
  pass "the operator ceremony text is committed"
  if grep -q '^set -Eeuo pipefail$' "${OPERATOR}"; then
    pass "operator: the block sets -Eeuo pipefail"
  else
    fail "operator: the block does not set -Eeuo pipefail"
  fi
  if [[ "$(grep -n -- '--verify' "${OPERATOR}" | head -1 | cut -d: -f1)" \
        -lt "$(grep -n -- '--apply' "${OPERATOR}" | head -1 | cut -d: -f1)" ]]; then
    pass "operator: --verify precedes --apply"
  else
    fail "operator: --apply is not gated behind --verify"
  fi
  if grep -q 'remediate-g11-bc-g-evidence.sh' "${OPERATOR}"; then
    pass "operator: it drives this ceremony"
  else
    fail "operator: it does not name this ceremony"
  fi
else
  fail "the operator ceremony text is missing"
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Evidence remediation validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'Evidence remediation validation passed.\n'
