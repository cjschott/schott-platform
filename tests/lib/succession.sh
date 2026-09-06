# shellcheck shell=bash
# Generation succession for host-only fixtures. Sourced, never executed.
#
# THE PROBLEM THIS EXISTS FOR
# ===========================
# A host-only suite reconstructs some generation's host from the live runtime.
# That works exactly until the next generation is installed, and then every such
# suite is reconstructing a host that no longer exists: it reads the SUCCESSOR's
# objects and calls them the predecessor's.
#
# It has happened twice. Generation 13 broke three suites when it landed, and the
# Generation-15 installation broke six -- including the one that proves the
# helper ceremony, whose compatibility matrix came out inverted because both
# sides of it were derived from a host that had moved.
#
# Each suite that was repaired invented its own correction: one subtracts the
# successor's CREATE rows, one restores a single REPLACE target from the
# predecessor commit, one reads the successor matrix for superseded rows. Three
# spellings of one idea, each of which had to be found and fixed separately --
# which is the same duplication that let the Generation-15 post-install verifier
# keep a defect its pre-install twin had already had corrected.
#
# So the idea is written once, here.
#
# WHAT IT DOES NOT DO
# ===================
# It does not accept whatever production currently holds. A rewind is driven by
# the SUCCESSOR CEREMONY'S OWN MATRIX -- reviewed, governed data -- and restores
# bytes from a named historical commit. An object no listed ceremony declares is
# left exactly as the live host holds it, so unknown bytes still reach the
# assertions that refuse them. Historical evidence is never rewritten.
#
# WHY THE SUCCESSOR LIST IS PASSED IN
# ===================================
# It is not derived from a global chain, because "later" is not the question the
# suites ask. A suite reconstructing Generation 13 must rewind Generations 14
# and 15 but NOT the G11-AX helper ceremony, whose library-root publication it
# already accounts for. Only the suite knows which ceremonies its own
# expectations already include, so each names its successors explicitly and the
# list is reviewable at the call site.

# succession_library_rows <ceremony-path>
#
# The library-root rows of one ceremony's matrix, as
# "<relative> <operation> <source>" lines. A /usr/libexec row is not part of the
# library surface and is skipped.
succession_library_rows() {
  local ceremony="$1" line source target operation
  # shellcheck disable=SC2016  # the matrix stores the placeholder literally
  local _placeholder='${LIBRARY_ROOT}/'
  [[ -f "${ceremony}" ]] || return 0
  while IFS= read -r line; do
    line="${line#\"}"; line="${line%\"}"
    IFS='|' read -r source target _ operation _ _ _ <<<"${line}"
    [[ "${target}" == *"${_placeholder}"* ]] || continue
    printf '%s %s %s\n' "${target##*"${_placeholder}"}" "${operation}" "${source}"
  done < <(sed -n '/^MATRIX=(/,/^)$/p' "${ceremony}" | sed -n 's/^\(".*"\)$/\1/p')
}

# succession_rewind <fixture-library-root> <repository> <commit> <ceremony>...
#
# Turn a fixture library root that was copied from the live host back into the
# host as of <commit>, by undoing the named later ceremonies:
#
#   CREATE  -> remove the pathname. CREATE is the ceremony's own statement that
#              the object did not exist before it ran.
#   REPLACE -> restore the object from <commit> via the row's declared SOURCE
#              path, which is the mapping from repository file to installed
#              module and is not guessable from the pathname.
#
# Modes are preserved: a real host carries 0444 and so must the fixture, because
# the installed set is verified for mode as well as for bytes.
#
# Returns non-zero if a REPLACE row cannot be restored, rather than leaving the
# fixture silently at successor bytes -- a fixture that quietly keeps the
# successor's object is precisely the failure this file exists to end.
succession_rewind() {
  local lib="$1" repository="$2" commit="$3"; shift 3
  local ceremony relative operation source failures=0
  for ceremony in "$@"; do
    while read -r relative operation source; do
      [[ -n "${relative}" ]] || continue
      case "${operation}" in
        CREATE)
          rm -f "${lib}/${relative}"
          ;;
        REPLACE)
          if ! git -C "${repository}" cat-file -e "${commit}:${source}" 2>/dev/null; then
            printf 'succession_rewind: %s does not carry %s (for %s)\n' \
              "${commit}" "${source}" "${relative}" >&2
            failures=$((failures + 1)); continue
          fi
          rm -f "${lib}/${relative}"
          git -C "${repository}" show "${commit}:${source}" > "${lib}/${relative}" || {
            printf 'succession_rewind: could not restore %s\n' "${relative}" >&2
            failures=$((failures + 1)); continue
          }
          chmod 0444 "${lib}/${relative}"
          ;;
        *)
          printf 'succession_rewind: %s declares operation %s for %s, which this cannot undo\n' \
            "${ceremony##*/}" "${operation}" "${relative}" >&2
          failures=$((failures + 1))
          ;;
      esac
    done < <(succession_library_rows "${ceremony}")
  done
  (( failures == 0 ))
}

# succession_created_by <ceremony>...
#
# Every library-root pathname the named ceremonies CREATE, one per line. For
# suites that only need to subtract successor creations from a live path set
# rather than rewind bytes.
succession_created_by() {
  local ceremony relative operation
  for ceremony in "$@"; do
    while read -r relative operation _; do
      [[ "${operation}" == "CREATE" ]] && printf '%s\n' "${relative}"
    done < <(succession_library_rows "${ceremony}")
  done
}
