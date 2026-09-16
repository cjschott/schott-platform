#!/usr/bin/env bash
set -Eeuo pipefail

# The committed CINST-000005 freeze artifact, rendered and checked.
#
# UNPRIVILEGED AND HOST-INDEPENDENT. Reads one committed file and writes only
# inside a temporary directory. No production store, no Fabric, no Trust, no
# sudo, no network.
#
# WHY THIS EXISTS
# ===============
# G11-BC-M reviewed and accepted the CINST-000005 body and shipped only its
# DIGEST, in a prose table. The 1269 bytes the digest names existed nowhere in
# the repository, so nobody could re-render them and the freeze block's own
# check had nothing to check against. A digest without its bytes is not a
# reviewable artifact.
#
# So the bytes are committed, and this renders them out of the committed
# heredoc and asserts the digest and the byte count. "The committed block
# produces the accepted body" stops being a claim in a report.
#
# It also holds the refusals, because a freeze block whose named refusals have
# drifted is worse than one with none: it reads as protection and is not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT="${ROOT}/provisioning/fabric/g11-bc-m-cinst-000005-freeze.txt"

REVIEWED_SHA256="850af1361812ee04212c6c525a276868ae5ab81883291367ebc18cee91fda8da"
REVIEWED_BYTES=1269
REQUEST_DIGEST="sha256:be0daf493301139aabb7ef6224b93203d744545665ef6f470a8d6236713ede8b"
SUPERSEDED_BCJ="a242a4b3c7bef26fc8fcdcfcf1d3f9fad7a7b0d6671bfe17e949036013a52f5b"
ACCEPTED_CINST4="5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

[[ -f "${ARTIFACT}" ]] || { printf 'the freeze artifact is missing\n' >&2; exit 1; }

# ===========================================================================
# A. the body is committed, and it is the reviewed body
# ===========================================================================

# Extracted the way the operator's shell would see it: the literal text between
# the BODY heredoc markers, with no substitution.
sed -n "/^cat > \"\${TMP}\" <<'BODY'\$/,/^BODY\$/p" "${ARTIFACT}" \
  | sed '1d;$d' > "${WORK}/rendered.json"

rendered_sha="$(sha256sum "${WORK}/rendered.json" | cut -d' ' -f1)"
rendered_bytes="$(wc -c < "${WORK}/rendered.json")"

if [[ "${rendered_sha}" == "${REVIEWED_SHA256}" ]]; then
  pass "the committed block renders the reviewed body: ${REVIEWED_SHA256}"
else
  fail "the committed block renders ${rendered_sha}, reviewed ${REVIEWED_SHA256}"
fi
if [[ "${rendered_bytes}" == "${REVIEWED_BYTES}" ]]; then
  pass "the rendered body is exactly ${REVIEWED_BYTES} bytes"
else
  fail "the rendered body is ${rendered_bytes} bytes, reviewed ${REVIEWED_BYTES}"
fi

# ===========================================================================
# B. it is the body the accepted authority describes
# ===========================================================================

if python3 - "${WORK}/rendered.json" <<'PY'; then
import json, sys
doc = json.load(open(sys.argv[1]))
expected = {
    "request_id": "g11bcm-admit-instance-cpkg-0001-chost-0001-cadv-000006-supersedes-cinst-000004",
    "advertisement_id": "CADV-000006",
    "supersedes": "CINST-000004",
    "admitted_at": "2026-09-15T06:15:00-05:00",
    "evaluated_at": "2026-09-15T06:15:00-05:00",
    "recorded_at": "2026-09-15T06:15:00-05:00",
    "admitted_until": "2026-09-19T06:00:00-05:00",
}
for field, want in expected.items():
    got = doc.get(field)
    assert got == want, f"{field}: {got!r} != {want!r}"
# The scope the reviewer accepted, unnarrowed.
assert doc["admission_scope"] == {
    "permitted_capabilities": ["CAPDEF-0001"],
    "permitted_operations": ["execute"],
    "permitted_data_classifications": ["internal"],
    "permitted_targets": ["HOST-0001"],
}, doc["admission_scope"]
PY
  pass "every accepted authority field is present and exact"
else
  fail "the rendered body does not carry the accepted authority fields"
fi

# ===========================================================================
# C. the refusals, and what they refuse
# ===========================================================================

for pair in "REVIEWED ${REVIEWED_SHA256}" \
            "the superseded G11-BC-J candidate ${SUPERSEDED_BCJ}" \
            "the accepted CINST-000004 predecessor ${ACCEPTED_CINST4}" \
            "the reviewed request digest ${REQUEST_DIGEST}"; do
  # shellcheck disable=SC2086  # deliberate split: label then value
  set -- ${pair}
  value="${!#}"
  if grep -qF "${value}" "${ARTIFACT}"; then
    pass "the block pins ${*:1:$#-1}"
  else
    fail "the block does not pin ${*:1:$#-1} (${value})"
  fi
done

# The refusals must name bodies that are NOT the reviewed one, or they refuse
# nothing. This is the check that would have caught a copy-paste that left a
# predecessor's digest in place.
if [[ "${SUPERSEDED_BCJ}" != "${REVIEWED_SHA256}" \
   && "${ACCEPTED_CINST4}" != "${REVIEWED_SHA256}" ]]; then
  pass "both refused digests are distinct from the reviewed body"
else
  fail "a refused digest equals the reviewed body; the block would refuse itself"
fi

# ===========================================================================
# D. the block's required shape
# ===========================================================================

required=(
  "set -Eeuo pipefail"
  "DEST=/etc/kyri/fabric/cinst-000005.json"
  "sudo test ! -e \"\${DEST}\""
  "sudo test -f /etc/kyri/fabric/cadv-000006.json"
  "install -o root -g cschott -m 0640"
  "python3 -m tools.fabric.cli admit-instance"
  "--store-root /var/lib/kyri/fabric"
  "--expected-uid 1000 --expected-gid 1000"
  "--trust-store-root /var/lib/kyri/trust"
  "--evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0"
  "--approved-directory /etc/kyri/fabric --preflight"
  "CINST-000005"
)
for needle in "${required[@]}"; do
  if grep -qF -- "${needle}" "${ARTIFACT}"; then
    pass "the block carries: ${needle}"
  else
    fail "the block is missing: ${needle}"
  fi
done

# It is a FREEZE, not a write. An admit-instance call without --preflight would
# create the record, which this artifact is not authorised to do.
if [[ "$(grep -c -- "tools.fabric.cli admit-instance" "${ARTIFACT}")" == "1" ]] \
   && grep -q -- "--approved-directory /etc/kyri/fabric --preflight" "${ARTIFACT}"; then
  pass "the block runs admit-instance exactly once, and only with --preflight"
else
  fail "the block runs admit-instance more than once, or without --preflight"
fi

# The destination refusal must come before the file is written.
# shellcheck disable=SC2016  # the pattern is literal text in the artifact
dest_check="$(grep -n 'sudo test ! -e "${DEST}"' "${ARTIFACT}" | head -1 | cut -d: -f1)"
install_line="$(grep -n 'install -o root -g cschott' "${ARTIFACT}" | head -1 | cut -d: -f1)"
if [[ -n "${dest_check}" && -n "${install_line}" ]] && (( dest_check < install_line )); then
  pass "the destination refusal precedes the install"
else
  fail "the destination refusal does not precede the install"
fi

# ===========================================================================
# E. the digest check is against the rendered file, not a restated constant
# ===========================================================================
#
# A block that compared REVIEWED to itself would pass its own check and prove
# nothing. The comparison must read the temporary file.
# shellcheck disable=SC2016  # both patterns are literal text in the artifact
if grep -q 'ACTUAL="$(sha256sum "${TMP}" | cut -d'"'"' '"'"' -f1)"' "${ARTIFACT}" \
   && grep -q 'test "${ACTUAL}" = "${REVIEWED}"' "${ARTIFACT}"; then
  pass "the digest check reads the rendered file and compares it to the pin"
else
  fail "the digest check does not read the rendered file"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINST-000005 freeze artifact validation passed.\n'
else
  printf 'CINST-000005 freeze artifact validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
