#!/usr/bin/env bash
set -Eeuo pipefail

# The committed Fabric freeze artifacts, rendered and checked.
#
# UNPRIVILEGED AND HOST-INDEPENDENT. Reads committed files and writes only
# inside a temporary directory. No production store, no Fabric, no Trust, no
# sudo, no network.
#
# WHY THIS EXISTS
# ===============
# G11-BC-M reviewed and accepted the CINST-000005 body and shipped only its
# DIGEST, in a prose table. The bytes the digest names existed nowhere in the
# repository, so nobody could re-render them and the freeze block's own
# `test "${ACTUAL}" = "${REVIEWED}"` had nothing to check against. A digest
# without its bytes is not a reviewable artifact.
#
# So the bytes are committed, and this renders them out of each committed
# heredoc and asserts the digest and the byte count. "The committed block
# produces the accepted body" stops being a claim in a report.
#
# ONE SUITE, A TABLE OF ARTIFACTS, ON PURPOSE. Each record in the chain gets its
# own freeze artifact, and the obvious thing is to copy this file per record.
# That is how the succession library's own history went -- "three spellings of
# one idea, each of which had to be found and fixed separately" -- so a new
# artifact is a ROW below, not a new file. The per-record facts that genuinely
# differ (digest, byte count, predecessor, refusals, baseline pin) are data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# name | artifact | reviewed sha256 | bytes | request digest | subcommand |
#   record id | destination | required predecessor input | superseded BC-J |
#   accepted predecessor body | fabric baseline pin | selected instance
#
# The last field is the instance the route must resolve to, or "-" where the
# operation does not resolve one. A selection is the only record whose
# correctness is not settled by its own identity: it can accept, match its
# request digest, and still have chosen the wrong instance. Where it is set,
# the block must pin it and must name the Trust store the judgement reads.
ARTIFACTS=(
"CINST-000005|provisioning/fabric/g11-bc-m-cinst-000005-freeze.txt|850af1361812ee04212c6c525a276868ae5ab81883291367ebc18cee91fda8da|1269|sha256:be0daf493301139aabb7ef6224b93203d744545665ef6f470a8d6236713ede8b|admit-instance|CINST-000005|/etc/kyri/fabric/cinst-000005.json|/etc/kyri/fabric/cadv-000006.json|a242a4b3c7bef26fc8fcdcfcf1d3f9fad7a7b0d6671bfe17e949036013a52f5b|5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c|e542651a4c6f2afd27b6c1141f75b6433f6f348267477608b24658710758c56b|-"
"CROUTE-0005|provisioning/fabric/g11-bc-m-croute-0005-freeze.txt|6d8311e51560081a765bdb2bce5aacb1b0f296138198c272f26d3200de3f713a|678|sha256:c2ded2c50ee8cee42d9a18faaef85a03d697b136c160f2f25ab9589ff9169bfb|create-route|CROUTE-0005|/etc/kyri/fabric/croute-0005.json|/etc/kyri/fabric/cinst-000005.json|77aac8c8e8aa2e40a2bc9c9888ead1b9ecbb5444f41d8d1a1b41c7e2c483e1e3|bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda|712730063d90f83d86b097aefc7fca5df36a443c8c84a3ab67396611db70d38c|-"
"CSEL-000004|provisioning/fabric/g11-bc-m-csel-000004-freeze.txt|60857d684434657e6b26207308ba630d7007bf1564910d6fadcd91ba3f80dffd|605|sha256:86bd92d17cc06271b904be6db2355baa0434bfae7484f1afe10842430df2e479|select|CSEL-000004|/etc/kyri/fabric/csel-000004.json|/etc/kyri/fabric/croute-0005.json|0f2b38d360adc17bec48d8b4c6558eb0d4daf461ebcfad518c078025b2fdef93|700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e|8f1df4b739ca5dd416fc90fba97401eda7996da22f7b145d0be4d69c46258add|CINST-000005"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

for row in "${ARTIFACTS[@]}"; do
  name="$(field "${row}" 0)"
  artifact="${ROOT}/$(field "${row}" 1)"
  reviewed="$(field "${row}" 2)"
  bytes="$(field "${row}" 3)"
  request_digest="$(field "${row}" 4)"
  subcommand="$(field "${row}" 5)"
  record_id="$(field "${row}" 6)"
  destination="$(field "${row}" 7)"
  predecessor="$(field "${row}" 8)"
  superseded="$(field "${row}" 9)"
  accepted_prev="$(field "${row}" 10)"
  baseline="$(field "${row}" 11)"
  selected="$(field "${row}" 12)"

  printf '\n--- %s ---\n' "${name}"

  if [[ ! -f "${artifact}" ]]; then
    fail "${name}: the freeze artifact is missing"
    continue
  fi

  # ---- the body is committed, and it is the reviewed body -----------------
  #
  # Extracted the way the operator's shell would see it: the literal text
  # between the BODY heredoc markers, with no substitution.
  rendered="${WORK}/${name}.json"
  sed -n "/^cat > \"\${TMP}\" <<'BODY'\$/,/^BODY\$/p" "${artifact}" \
    | sed '1d;$d' > "${rendered}"

  rendered_sha="$(sha256sum "${rendered}" | cut -d' ' -f1)"
  rendered_bytes="$(wc -c < "${rendered}")"

  if [[ "${rendered_sha}" == "${reviewed}" ]]; then
    pass "${name}: the committed block renders the reviewed body ${reviewed}"
  else
    fail "${name}: renders ${rendered_sha}, reviewed ${reviewed}"
  fi
  if [[ "${rendered_bytes}" == "${bytes}" ]]; then
    pass "${name}: the rendered body is exactly ${bytes} bytes"
  else
    fail "${name}: the rendered body is ${rendered_bytes} bytes, reviewed ${bytes}"
  fi
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${rendered}" 2>/dev/null; then
    pass "${name}: the rendered body is one JSON document"
  else
    fail "${name}: the rendered body is not valid JSON"
  fi

  # ---- the pins, and what they refuse -------------------------------------
  for pin in "the reviewed digest|${reviewed}" \
             "the reviewed byte count|${bytes}" \
             "the reviewed request digest|${request_digest}" \
             "the superseded G11-BC-J body|${superseded}" \
             "the accepted predecessor body|${accepted_prev}" \
             "the production Fabric baseline|${baseline}"; do
    label="${pin%%|*}"; value="${pin##*|}"
    if grep -qF -- "${value}" "${artifact}"; then
      pass "${name}: pins ${label}"
    else
      fail "${name}: does not pin ${label} (${value})"
    fi
  done

  # A refusal naming the reviewed body would refuse the ceremony itself. This
  # is the check that catches a copy-paste that left a digest in place.
  if [[ "${superseded}" != "${reviewed}" && "${accepted_prev}" != "${reviewed}" ]]; then
    pass "${name}: both refused digests are distinct from the reviewed body"
  else
    fail "${name}: a refused digest equals the reviewed body; the block would refuse itself"
  fi

  # ---- the block's required shape -----------------------------------------
  for needle in "set -Eeuo pipefail" \
                "DEST=${destination}" \
                "sudo test ! -e \"\${DEST}\"" \
                "sudo test -f ${predecessor}" \
                "install -o root -g cschott -m 0640" \
                "python3 -m tools.fabric.cli ${subcommand}" \
                "--store-root /var/lib/kyri/fabric" \
                "--expected-uid 1000 --expected-gid 1000" \
                "--evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0" \
                "--approved-directory /etc/kyri/fabric --preflight" \
                "${record_id}"; do
    if grep -qF -- "${needle}" "${artifact}"; then
      pass "${name}: carries ${needle}"
    else
      fail "${name}: is missing ${needle}"
    fi
  done

  # It is a FREEZE, not a write. A call without --preflight creates the record,
  # which no freeze artifact is authorised to do.
  if [[ "$(grep -c -- "tools.fabric.cli ${subcommand}" "${artifact}")" == "1" ]] \
     && grep -q -- "--approved-directory /etc/kyri/fabric --preflight" "${artifact}"; then
    pass "${name}: runs ${subcommand} exactly once, and only with --preflight"
  else
    fail "${name}: runs ${subcommand} more than once, or without --preflight"
  fi

  # The destination refusal must come before the file is written.
  # shellcheck disable=SC2016  # the pattern is literal text in the artifact
  dest_line="$(grep -n 'sudo test ! -e "${DEST}"' "${artifact}" | head -1 | cut -d: -f1)"
  install_line="$(grep -n 'install -o root -g cschott' "${artifact}" | head -1 | cut -d: -f1)"
  if [[ -n "${dest_line}" && -n "${install_line}" ]] && (( dest_line < install_line )); then
    pass "${name}: the destination refusal precedes the install"
  else
    fail "${name}: the destination refusal does not precede the install"
  fi

  # The digest check must read the rendered file. A block comparing the pin to
  # itself passes its own check and proves nothing.
  # shellcheck disable=SC2016  # both patterns are literal text in the artifact
  if grep -q 'ACTUAL="$(sha256sum "${TMP}" | cut -d'"'"' '"'"' -f1)"' "${artifact}" \
     && grep -q 'test "${ACTUAL}" = "${REVIEWED}"' "${artifact}"; then
    pass "${name}: the digest check reads the rendered file"
  else
    fail "${name}: the digest check does not read the rendered file"
  fi

  # The predicted record id and the request digest are pinned SEPARATELY.
  # `would_accept` alone does not say which record the engine resolved to.
  if grep -q "test \"\${PREDICTED}\" = \"${record_id}\"" "${artifact}" \
     && grep -q "test \"\${DIGEST}\" = \"${request_digest}\"" "${artifact}"; then
    pass "${name}: predicted_record_id and request_digest are pinned separately"
  else
    fail "${name}: the two preflight facts are not pinned separately"
  fi

  # A selection resolves an instance, and that is a THIRD fact: a block can
  # predict the right record and match the reviewed request digest while the
  # route resolved to something else entirely. Where the table names an
  # instance, the block must pin it, and must name the Trust store whose
  # judgement decided it -- an exclusion the selection cannot see is an
  # exclusion it cannot honour.
  if [[ "${selected}" != "-" ]]; then
    if grep -q "test \"\${SELECTED}\" = \"${selected}\"" "${artifact}"; then
      pass "${name}: pins selected_instance_id ${selected} independently"
    else
      fail "${name}: does not pin selected_instance_id ${selected}"
    fi
    if grep -qF -- "--trust-store-root /var/lib/kyri/trust" "${artifact}"; then
      pass "${name}: carries --trust-store-root /var/lib/kyri/trust"
    else
      fail "${name}: is missing --trust-store-root /var/lib/kyri/trust"
    fi
  fi

  # And the store is proved unchanged against the pinned baseline.
  # shellcheck disable=SC2016  # the pattern is literal text in the artifact
  if grep -q 'test "${AFTER}" = "${FABRIC_BEFORE}"' "${artifact}"; then
    pass "${name}: proves /var/lib/kyri/fabric unchanged against the pinned baseline"
  else
    fail "${name}: does not prove the store unchanged"
  fi
done

# ---- across the table ------------------------------------------------------
#
# Each step pins the store as it stands when that step runs, so two artifacts
# sharing a baseline would mean one of them is pinning a state that no longer
# exists by the time it is used.
baselines="$(for row in "${ARTIFACTS[@]}"; do field "${row}" 11; printf '\n'; done | sort)"
if [[ "$(printf '%s' "${baselines}" | sort -u | grep -c .)" \
      == "$(printf '%s' "${baselines}" | grep -c .)" ]]; then
  pass "every artifact pins a distinct Fabric baseline, as the write order requires"
else
  fail "two artifacts pin the same Fabric baseline; one of them is stale"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Fabric freeze artifact validation passed.\n'
else
  printf 'Fabric freeze artifact validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
