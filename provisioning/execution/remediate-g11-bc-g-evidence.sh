#!/usr/bin/env bash
set -Eeuo pipefail

# G11-BC-G evidence remediation: reconstruct what was overwritten, record what
# was never written. EVIDENCE ONLY.
#
# WHAT WENT WRONG. The G11-BC-E helper ceremony carried three constants over
# verbatim from the ceremony it was derived from. Its HELPER_EVIDENCE named
# `/root/kyri-g11-bb-helper-digests.txt`, so a successful run wrote BC-E's
# evidence OVER G11-BB's, and the content it wrote also self-identified as
# `ceremony g11-bb-helpers` at `runtime_generation 14`. The source was corrected
# at G11-BC-G; this repairs the artifacts that run left behind.
#
# WHAT THIS TOUCHES, AND WHAT IT MUST NOT
# =======================================
# Three files under /root, and nothing else. It installs no object, reads no
# capability record, and changes no runtime, helper, Fabric, Trust, sudoers or
# invocation state. The installed deployment was independently verified correct
# at G11-BC-G §1 WITHOUT reading any evidence file, which is exactly why
# repairing the evidence cannot affect it.
#
# THIS IS NOT A REPLICA OF THE LOST ARTIFACT
# ==========================================
# It would be easy to reproduce what G11-BB's ceremony actually wrote, bug for
# bug. That is refused. The lost artifact itself said `runtime_generation 14`
# while G11-BB required the Generation-15 readiness rule -- the same inherited
# constant, one ceremony earlier -- so a faithful replica would re-record a
# known-false field.
#
# What is written instead is TRUE, sourced, and explicitly marked as
# reconstructed after the fact. Both files carry `evidence_status`, the sources
# each field came from, and the fields that are NOT recoverable at all.
#
# THE CANONICAL G11-BB PATHNAME IS NOT RECREATED
# ==============================================
# `/root/kyri-g11-bb-helper-digests.txt` is left ABSENT. Writing a
# reconstruction there would make it indistinguishable from an original to
# anything that only checks existence, and the original is gone. The
# reconstruction gets its own name, and the defective artifact is archived under
# a name that says what it is.
#
# Nothing reads it. Every reference to a `kyri-g11-*-helper-digests` path in the
# tree is either an assignment inside the ceremony that writes it, or a FIXTURE
# path in a test root -- no installer, verifier, operator block or succession
# reader consults one in production. The generation-evidence family
# (`kyri-gen*-helper-digests.txt`) is separate and is not touched.
#
# Usage:
#   remediate-g11-bc-g-evidence.sh --verify    read-only; report what it would do
#   remediate-g11-bc-g-evidence.sh --apply     perform the remediation
#   remediate-g11-bc-g-evidence.sh --recover   resolve an interrupted run
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.

ROOT_DIR="/root"
DEFECTIVE="${ROOT_DIR}/kyri-g11-bb-helper-digests.txt"
ARCHIVE="${ROOT_DIR}/kyri-g11-bb-helper-digests.defective-bc-e.txt"
BB_RECONSTRUCTED="${ROOT_DIR}/kyri-g11-bb-helper-digests.reconstructed.txt"
BCE_EVIDENCE="${ROOT_DIR}/kyri-g11-bc-e-helper-digests.txt"
TRANSACTION_ROOT="${ROOT_DIR}/kyri-evidence-remediation-transaction"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# The reviewed authorities each reconstruction is derived from. Named so a
# reader can check the reconstruction against them rather than trust it.
BB_COMMIT="ef4f7446200b668f8dcbf34d180c5102270f19f6"
BB_REPORT="docs/development/reports/eng-0005/2026-09-06-g11-bb-r-helper-deployment-acceptance.md"
BCE_COMMIT="15a8c738f97394a4f114070c011db22562466ed6"
BCE_REPORT="docs/development/reports/eng-0005/2026-09-13-g11-bc-g-post-deployment-acceptance-and-evidence-defect.md"
REMEDIATION_REPORT="docs/development/reports/eng-0005/2026-09-13-g11-bc-h-evidence-reconstruction-preparation.md"


MODE=""
FIXTURE=""
STAMP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify|--apply|--recover)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; } ;;
    --stamp)
      # The instant recorded in the reconstruction. Supplied so a fixture run is
      # reproducible; production omits it and the ceremony reads the clock once.
      STAMP="${2:-}"; shift 2 ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---verify}"

if [[ -n "${FIXTURE}" ]]; then
  for name in DEFECTIVE ARCHIVE BB_RECONSTRUCTED BCE_EVIDENCE TRANSACTION_ROOT \
              LIBRARY_ROOT LIBEXEC_ROOT; do
    printf -v "${name}" '%s%s' "${FIXTURE}" "${!name}"
  done
fi

# THE PATH-BEARING DECLARATIONS ARE BUILT AFTER THE REBASE, ON PURPOSE.
#
# Defined above it, every `${LIBRARY_ROOT}` inside them would expand to the
# PRODUCTION path before --fixture ever took effect, and a fixture run would
# then read and judge the real host. That is not a cosmetic ordering choice: it
# is the difference between a fixture that isolates and one that quietly does
# not.
# G11-BB's accepted matrix, copied from its committed ceremony at BB_COMMIT.
# operation | installed target | predecessor | target | closure
BB_DELTA=(
"REPLACE|${LIBRARY_ROOT}/kyri_exec_transition_action.py|7703231318f7a872f80abc0b033c2462c24ec63bd8669773d6643634af1d296a|b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315|INSIDE"
"REPLACE|${LIBRARY_ROOT}/kyri_exec_quota.py|4886d5b323c9dfdf46939c83424b087bb052f3fc90b8bd4a5ba2b4346bff9e9c|54a9b15c6c6e3b785218d75c91b896f0723d3bf2051ebfca1351c84aa9855ca7|INSIDE"
"REPLACE|${LIBEXEC_ROOT}/kyri-exec-worker.py|6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd|2d320630aca559c747522bb528f87172e747f30a182db0fec70e31eca272ddf5|INSIDE"
)

# What G11-BB-R MEASURED on the host immediately after that ceremony (§1 of that
# report), not what is installed today. One of the three has since moved.
BB_INSTALLED=(
"b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315|${LIBRARY_ROOT}/kyri_exec_transition_action.py"
"54a9b15c6c6e3b785218d75c91b896f0723d3bf2051ebfca1351c84aa9855ca7|${LIBRARY_ROOT}/kyri_exec_quota.py"
"2d320630aca559c747522bb528f87172e747f30a182db0fec70e31eca272ddf5|${LIBEXEC_ROOT}/kyri-exec-worker.py"
)

# G11-BC-E's accepted matrix, from its committed ceremony at BCE_COMMIT.
BCE_DELTA=(
"REPLACE|${LIBRARY_ROOT}/kyri_exec_transition_action.py|b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315|d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de|INSIDE"
)
BCE_TARGET="d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de"
BCE_ACTION_PATH="${LIBRARY_ROOT}/kyri_exec_transition_action.py"

# The Generation-17 runtime this ceremony ran against, so the reconstruction can
# state the generation instead of inheriting a number.
GEN17_HELPERS_SHA256="78da8519db99fa06e809755808397fe36bb8c83872deab142987c98308b38a4f"
GEN17_HELPERS_PATH="${LIBRARY_ROOT}/tools/capability/execution/helpers.py"

JOURNAL="${TRANSACTION_ROOT}/journal"
FAILURES=0
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

journal_state() {
  [[ -f "${JOURNAL}" ]] || { printf 'NONE'; return; }
  sed -n 's/^state=//p' "${JOURNAL}" | tail -1
}
journal_write() {
  mkdir -p "${TRANSACTION_ROOT}"; chmod 0700 "${TRANSACTION_ROOT}"
  { printf 'state=%s\n' "$1"
    printf 'defective_sha256=%s\n' "${DEFECTIVE_SHA256:-unknown}"
    printf 'stamp=%s\n' "${STAMP}"
  } > "${JOURNAL}.writing"
  mv -f "${JOURNAL}.writing" "${JOURNAL}"
}

# --- an already-finished remediation -----------------------------------------
#
# Checked before the artifact, because a remediated host and a host that was
# never defective both lack the defective artifact. Only the journal tells them
# apart, and refusing with "there is nothing to archive" on a host that has
# already been remediated would be a true sentence that misleads the reader.
require_not_already_complete() {
  [[ "$(journal_state)" == "COMPLETE" ]] || return 0
  halt "a remediation journal already exists in state COMPLETE: this host has been remediated, ${ARCHIVE} already exists, and nothing further is to be done"
}

# --- the defective artifact, identified by CONTENT ---------------------------
#
# A digest pin would be stronger if the value were knowable in advance. It is
# not: the artifact carries a `transaction` line built from a timestamp and a
# pid, so nobody could state its digest before reading the host.
#
# So the gate is STRUCTURAL, which is a better question anyway: is this file the
# artifact the G11-BC-E run wrote? Three facts answer it together, and no other
# file in this deployment satisfies all three. The digest is then computed and
# recorded rather than assumed.
require_defective_artifact() {
  [[ -f "${DEFECTIVE}" ]] \
    || halt "${DEFECTIVE} does not exist; there is nothing to archive and this remediation does not apply"
  DEFECTIVE_SHA256="$(digest_of "${DEFECTIVE}")"

  grep -q "^ceremony g11-bb-helpers\$" "${DEFECTIVE}" \
    || halt "${DEFECTIVE} does not self-identify as g11-bb-helpers: this is not the artifact G11-BC-G described"
  grep -q "^commit ${BCE_COMMIT}\$" "${DEFECTIVE}" \
    || halt "${DEFECTIVE} does not carry the G11-BC-E reviewed commit ${BCE_COMMIT}: it may be the genuine G11-BB artifact, which must NOT be archived"
  grep -q "${BCE_TARGET}" "${DEFECTIVE}" \
    || halt "${DEFECTIVE} does not mention the G11-BC-E target ${BCE_TARGET}"

  ok "the artifact at ${DEFECTIVE} is the G11-BC-E write: g11-bb-helpers name, ${BCE_COMMIT:0:12} commit, ${BCE_TARGET:0:12} target"
  ok "its digest is ${DEFECTIVE_SHA256}"

  # The one reading that would mean the file is NOT what we think.
  grep -q "^commit ${BB_COMMIT}\$" "${DEFECTIVE}" \
    && halt "${DEFECTIVE} carries the G11-BB commit ${BB_COMMIT}: this looks like genuine historical evidence and must not be archived"
  ok "it is not the genuine G11-BB artifact"
}

# --- the sources the reconstructions are derived from ------------------------
require_source_authorities() {
  local missing=0 row target want
  for row in "${BB_DELTA[@]}" "${BCE_DELTA[@]}"; do
    [[ -n "$(field "${row}" 3)" ]] || { bad "a delta row carries no target digest"; missing=$((missing + 1)); }
  done

  # Two of G11-BB's three targets are still installed and must still match, so a
  # reconstruction cannot be written against a host that has drifted. The third
  # -- the action module -- legitimately moved at G11-BC-E and is checked
  # against ITS target instead.
  for row in "${BB_INSTALLED[@]}"; do
    target="$(field "${row}" 1)"; want="$(field "${row}" 0)"
    [[ "${target}" == "${BCE_ACTION_PATH}" ]] && continue
    [[ "$(digest_of "${target}")" == "${want}" ]] \
      || { bad "${target} is $(digest_of "${target}"), and G11-BB-R records ${want}"; missing=$((missing + 1)); }
  done
  (( missing == 0 )) \
    && ok "every G11-BB object this reconstruction can still observe matches what G11-BB-R measured"

  [[ "$(digest_of "${BCE_ACTION_PATH}")" == "${BCE_TARGET}" ]] \
    || halt "the installed action module is $(digest_of "${BCE_ACTION_PATH}"), not the G11-BC-E target ${BCE_TARGET}: the deployment this evidence would describe is not the one installed"
  ok "the installed action module is the G11-BC-E target ${BCE_TARGET}"

  [[ "$(digest_of "${GEN17_HELPERS_PATH}")" == "${GEN17_HELPERS_SHA256}" ]] \
    || halt "the installed readiness rule is not the Generation-17 ${GEN17_HELPERS_SHA256}: this evidence would name a generation the host is not at"
  ok "the installed runtime is Generation 17"
}

# --- destinations ------------------------------------------------------------
#
# None may already exist. Overwriting an evidence file is the defect this whole
# remediation exists to repair, so this refuses rather than replaces.
require_destinations_absent() {
  local destination collision=0
  for destination in "${ARCHIVE}" "${BB_RECONSTRUCTED}" "${BCE_EVIDENCE}"; do
    if [[ -e "${destination}" ]]; then
      bad "${destination} already exists; this ceremony never overwrites an evidence file"
      collision=$((collision + 1))
    fi
  done
  (( collision == 0 )) && ok "all three destinations are absent"
  (( collision == 0 ))
}

emit_bb_reconstruction() {
  local row
  printf 'evidence_status reconstructed\n'
  printf 'evidence_of ceremony g11-bb-helpers\n'
  printf 'reconstructed_at %s\n' "${STAMP}"
  printf 'reconstructed_by %s\n' "${REMEDIATION_REPORT}"
  printf 'reconstruction_reason the original artifact at %s was overwritten by the G11-BC-E helper ceremony, which named this path in error\n' "${DEFECTIVE}"
  printf 'defect_report %s\n' "${BCE_REPORT}"
  printf 'overwriting_artifact_archived_at %s\n' "${ARCHIVE}"
  printf 'overwriting_artifact_sha256 %s\n' "${DEFECTIVE_SHA256}"
  printf 'not_original_ceremony_output true\n'
  printf 'installed_state_unchanged_by_reconstruction true\n'
  printf '#\n'
  printf 'ceremony g11-bb-helpers\n'
  printf 'commit %s\n' "${BB_COMMIT}"
  printf 'runtime_commit %s\n' "${BB_COMMIT}"
  # STATED, not inherited. G11-BB required the Generation-15 readiness rule
  # (6dd93606), so it ran against Generation 15. The lost artifact said 14,
  # which was itself an inherited constant from the G11-AX ceremony -- where 14
  # was correct. A replica would have re-recorded that error.
  printf 'runtime_generation 15\n'
  printf 'runtime_generation_in_lost_artifact 14\n'
  printf 'runtime_generation_correction the lost artifact inherited 14 from install-g11-ax-helpers.sh; G11-BB required the Generation-15 rule 6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07\n'
  printf 'state COMMITTED\n'
  printf 'transaction UNRECOVERABLE\n'
  printf 'transaction_note the original carried a runtime-generated identifier; it is not derivable from any reviewed source and is not invented here\n'
  printf 'objects %s\n' "${#BB_DELTA[@]}"
  printf 'replaced %s\n' "${#BB_DELTA[@]}"
  printf 'created 0\n'
  printf 'readiness_closure %s\n' "${#BB_DELTA[@]}"
  printf 'ceremony_only 0\n'
  printf 'runtime_readiness compatible\n'
  printf 'runtime_readiness_source %s section 2, measured\n' "${BB_REPORT}"
  for row in "${BB_DELTA[@]}"; do
    printf 'delta %s %s %s %s %s\n' \
      "$(field "${row}" 0)" "$(field "${row}" 1)" \
      "$(field "${row}" 2)" "$(field "${row}" 3)" "$(field "${row}" 4)"
  done
  printf 'delta_source the committed matrix of install-g11-bb-helpers.sh at %s\n' "${BB_COMMIT}"
  for row in "${BB_INSTALLED[@]}"; do
    printf 'installed %s %s\n' "$(field "${row}" 0)" "$(field "${row}" 1)"
  done
  printf 'installed_source %s section 1, measured on the host immediately after that ceremony\n' "${BB_REPORT}"
  printf 'installed_note these are the digests as of G11-BB, NOT as of today: %s has since moved to %s at G11-BC-E\n' \
    "${BCE_ACTION_PATH}" "${BCE_TARGET}"
  printf 'mode 0444 every target\n'
  printf 'owner root:root every target\n'
}

emit_bce_evidence() {
  local row
  printf 'evidence_status reconstructed\n'
  printf 'evidence_of ceremony g11-bc-e-helpers\n'
  printf 'reconstructed_at %s\n' "${STAMP}"
  printf 'reconstructed_by %s\n' "${REMEDIATION_REPORT}"
  printf 'reconstruction_reason the ceremony wrote its evidence to the G11-BB pathname in error, so no artifact was ever written here\n'
  printf 'defect_report %s\n' "${BCE_REPORT}"
  printf 'as_written_artifact_archived_at %s\n' "${ARCHIVE}"
  printf 'as_written_artifact_sha256 %s\n' "${DEFECTIVE_SHA256}"
  printf 'not_original_ceremony_output true\n'
  printf 'installed_state_unchanged_by_reconstruction true\n'
  printf '#\n'
  printf 'ceremony g11-bc-e-helpers\n'
  printf 'commit %s\n' "${BCE_COMMIT}"
  printf 'runtime_commit %s\n' "${BCE_COMMIT}"
  printf 'runtime_generation 17\n'
  printf 'state COMMITTED\n'
  printf 'transaction UNRECOVERABLE\n'
  printf 'transaction_note the run carried a runtime-generated identifier; the artifact that recorded it was the one written to the wrong path, and its value is preserved in %s\n' "${ARCHIVE}"
  printf 'objects %s\n' "${#BCE_DELTA[@]}"
  printf 'replaced %s\n' "${#BCE_DELTA[@]}"
  printf 'created 0\n'
  printf 'readiness_closure %s\n' "${#BCE_DELTA[@]}"
  printf 'ceremony_only 0\n'
  printf 'runtime_readiness compatible\n'
  printf 'runtime_readiness_source measured on this host at remediation time\n'
  for row in "${BCE_DELTA[@]}"; do
    printf 'delta %s %s %s %s %s\n' \
      "$(field "${row}" 0)" "$(field "${row}" 1)" \
      "$(field "${row}" 2)" "$(field "${row}" 3)" "$(field "${row}" 4)"
  done
  printf 'delta_source the committed matrix of install-g11-bc-e-helpers.sh at %s\n' "${BCE_COMMIT}"
  printf 'installed %s %s\n' "$(digest_of "${BCE_ACTION_PATH}")" "${BCE_ACTION_PATH}"
  printf 'installed_source measured on this host at remediation time\n'
  printf 'mode 0444 every target\n'
  printf 'owner root:root every target\n'
}

publish() {                            # <destination> <emitter>
  local destination="$1" emitter="$2"
  "${emitter}" > "${destination}.writing"
  chmod 0400 "${destination}.writing"
  [[ -n "${FIXTURE}" ]] || chown root:root "${destination}.writing"
  mv -f "${destination}.writing" "${destination}"
  ok "wrote ${destination}"
}

manifest() {
  local path
  for path in "${DEFECTIVE}" "${ARCHIVE}" "${BB_RECONSTRUCTED}" "${BCE_EVIDENCE}"; do
    if [[ -f "${path}" ]]; then
      printf '  %s  %s  %s\n' "$(digest_of "${path}")" "$(stat -c '%U:%G %a' "${path}")" "${path}"
    else
      printf '  %-64s %s  %s\n' "absent" "" "${path}"
    fi
  done
}

# ===========================================================================
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"
[[ -n "${STAMP}" ]] || STAMP="$(date -Is)"

case "${MODE}" in
--verify)
  printf 'before:\n'; manifest; printf '\n'
  require_not_already_complete
  require_defective_artifact
  require_source_authorities
  require_destinations_absent || true
  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no remediation in progress"
  else
    note "a journal exists in state ${state}: --recover will resolve it"
  fi
  printf '\nwhat --apply would write:\n'
  printf '  %s   <- the defective artifact, bytes preserved\n' "${ARCHIVE}"
  printf '  %s   <- G11-BB, reconstructed and marked as such\n' "${BB_RECONSTRUCTED}"
  printf '  %s   <- G11-BC-E, recorded at its correct path\n' "${BCE_EVIDENCE}"
  printf '  %s   <- left ABSENT: the original is gone and this does not pretend otherwise\n' "${DEFECTIVE}"
  ;;

--apply)
  printf 'before:\n'; manifest; printf '\n'
  require_not_already_complete
  require_defective_artifact
  require_source_authorities
  # require_source_authorities REPORTS drift rather than halting, so --verify can
  # show every problem at once. --apply must not inherit that leniency: a host
  # that has drifted from what G11-BB-R measured cannot have a reconstruction
  # written against it, and the refusal has to come BEFORE anything is written.
  (( FAILURES == 0 )) \
    || halt "${FAILURES} source authority check(s) failed; nothing was written"
  require_destinations_absent || halt "a destination already exists; resolve it before applying"
  [[ "$(journal_state)" == "NONE" ]] \
    || halt "a remediation journal already exists in state $(journal_state); use --recover"

  journal_write ARCHIVING
  cp -a "${DEFECTIVE}" "${ARCHIVE}"
  [[ "$(digest_of "${ARCHIVE}")" == "${DEFECTIVE_SHA256}" ]] \
    || halt "the archived copy does not match the artifact it was copied from"
  ok "archived ${DEFECTIVE} -> ${ARCHIVE} (${DEFECTIVE_SHA256})"

  journal_write ARCHIVED
  rm -f "${DEFECTIVE}"
  ok "removed ${DEFECTIVE}; the canonical G11-BB pathname is deliberately left absent"

  journal_write BB_PUBLISHED
  publish "${BB_RECONSTRUCTED}" emit_bb_reconstruction

  journal_write BCE_PUBLISHED
  publish "${BCE_EVIDENCE}" emit_bce_evidence

  journal_write COMPLETE
  printf '\nafter:\n'; manifest
  ;;

--recover)
  state="$(journal_state)"
  [[ "${state}" == "NONE" ]] && halt "there is no remediation to recover"
  note "resuming from ${state}"
  printf 'current:\n'; manifest; printf '\n'
  case "${state}" in
    ARCHIVING)
      # The copy may or may not have completed. Either way the source still
      # exists, because it is removed only after ARCHIVED.
      [[ -f "${DEFECTIVE}" ]] || halt "state ARCHIVING but the source is gone; operator disposition required"
      rm -f "${ARCHIVE}"
      rm -f "${JOURNAL}"; rmdir "${TRANSACTION_ROOT}" 2>/dev/null || true
      ok "rolled back to the pre-remediation state; rerun --apply"
      ;;
    ARCHIVED|BB_PUBLISHED|BCE_PUBLISHED)
      note "the archive is durable; complete the remaining writes with --apply after clearing the journal"
      halt "partial remediation requires operator disposition: the archive exists and some evidence may not"
      ;;
    COMPLETE)
      ok "the remediation is complete; nothing to recover"
      ;;
    *) halt "unknown journal state ${state}" ;;
  esac
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Evidence remediation %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Evidence remediation %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
