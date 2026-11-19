# shellcheck shell=bash
# Locating the reviewed operator package in history. Sourced, never executed.
#
# THE PROBLEM THIS EXISTS FOR
# ===========================
# The G5 suites build their fixtures from the reviewed commit: the commit whose
# packaged tree the ceremony's pinned MANIFEST_DIGEST describes, which is the
# generation actually installed. Source may lead it, so it is not HEAD; it was
# found by walking the 40 newest commits that touched the packaged paths.
#
# That bound made the answer depend on how many commits had landed since the
# review rather than on history. Every unrelated commit to tools/common or
# tools/capability moved the reviewed commit one position further back, and at
# position 41 the suites would have failed with nothing wrong.
#
# WHAT IT DOES
# ============
# The walk has no bound. `ancestor_with_package equal <digest>` names the
# newest ancestor of HEAD that touched the packaged paths and whose manifest is
# <digest>; `differ` names the newest whose manifest is not. The answer is a
# function of the commit graph alone. The only way to find nothing is for no
# ancestor to carry the package, which is the invariant itself failing.
#
# The manifest is exactly the suites' own `manifest_at`: the sha256 of
# "<sha256>  <path>" lines for every packaged .py file, sorted bytewise by
# path. It is computed faster, not differently: each blob is hashed once and
# remembered by object id, so a walk costs one ls-tree per commit plus one hash
# per file version, rather than one hash per file per commit. Callers confirm
# the commit found with their own `manifest_at` before using it.
#
# The caller sets REPOSITORY and MANIFEST_PATHS before calling.

declare -gA _RC_BLOB_SHA256=()

# _rc_manifest <commit>: sets _RC_MANIFEST to the packaged manifest of <commit>. Runs
# in the caller's shell, not a subshell, so the blob cache persists.
_RC_MANIFEST=""
_rc_manifest() {
  local _rc_meta _rc_file _rc_oid _rc_lines=""
  while IFS=$'\t' read -r _rc_meta _rc_file; do
    [[ "${_rc_file}" == *.py && "${_rc_file}" != *__pycache__* ]] || continue
    _rc_oid="${_rc_meta##* }"
    if [[ -z "${_RC_BLOB_SHA256[${_rc_oid}]+set}" ]]; then
      _RC_BLOB_SHA256[${_rc_oid}]="$(git -C "${REPOSITORY}" cat-file blob "${_rc_oid}" \
        | sha256sum | cut -d' ' -f1)"
    fi
    _rc_lines+="${_RC_BLOB_SHA256[${_rc_oid}]}  ${_rc_file}"$'\n'
  done < <(git -C "${REPOSITORY}" ls-tree -r "$1" -- "${MANIFEST_PATHS[@]}" \
             | LC_ALL=C sort -t $'\t' -k2)
  _RC_MANIFEST="$(printf '%s' "${_rc_lines}" | sha256sum | cut -d' ' -f1)"
}

# ancestor_with_package <equal|differ> <digest>: sets ANCESTOR to the newest
# matching ancestor of HEAD, or to the empty string if there is none.
ANCESTOR=""
ancestor_with_package() {
  local _rc_relation="$1" _rc_digest="$2" _rc_candidate
  ANCESTOR=""
  while IFS= read -r _rc_candidate; do
    _rc_manifest "${_rc_candidate}"
    if [[ "${_rc_relation}" == equal && "${_RC_MANIFEST}" == "${_rc_digest}" ]] \
        || [[ "${_rc_relation}" == differ && "${_RC_MANIFEST}" != "${_rc_digest}" ]]; then
      ANCESTOR="${_rc_candidate}"
      return 0
    fi
  done < <(git -C "${REPOSITORY}" rev-list HEAD -- "${MANIFEST_PATHS[@]}")
}
