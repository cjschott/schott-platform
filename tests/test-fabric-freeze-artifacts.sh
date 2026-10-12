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
#   record id | destination | required predecessor input | superseded body |
#   accepted predecessor body | fabric baseline pin | selected instance |
#   current-time gate valid_until | current-eligibility instance |
#   committed inert body, or "-" for a body rendered from the block's heredoc
#
# Field 16 is where the reviewed bytes LIVE. A block may carry them in its own
# BODY heredoc, which is how every G11-BC-M and early G11-BC-N artifact does
# it, or it may copy a committed inert input. The second shape exists because
# the reviewed CROUTE-0006 and CSEL-000004 bodies were pinned by digest in
# G11-BC-N and never committed, and a digest whose bytes are gone is not a
# reviewable artifact -- the same defect that lost the Option-B CINV payload.
# Where field 16 names a file, that file is the single source of the bytes: the
# block copies it rather than restating it, so the two cannot drift apart.
#
# Field 12 is the instance the route must resolve to, or "-". A selection is
# the only record whose correctness is not settled by its own identity: it can
# accept, match its request digest, and still have chosen the wrong instance.
#
# Fields 13 and 14 are the CURRENT-TIME gate. The Fabric engine judges every
# request at the instant the request names and never at a clock -- correct for
# an append-only store, and the reason the withdrawn G11-BC-M CSEL artifact
# still accepted after its authority expired. Nothing inside the engine will
# tell an operator that the window they are about to act in has closed, so a
# time-bound artifact carries that check itself, ahead of its install. Field 13
# is the valid_until/admitted_until the block must gate on; field 14 is the
# instance whose eligibility it must recompute at the current clock, where one
# exists to compute.
ARTIFACTS=(
"CINST-000005|provisioning/fabric/g11-bc-m-cinst-000005-freeze.txt|850af1361812ee04212c6c525a276868ae5ab81883291367ebc18cee91fda8da|1269|sha256:be0daf493301139aabb7ef6224b93203d744545665ef6f470a8d6236713ede8b|admit-instance|CINST-000005|/etc/kyri/fabric/cinst-000005.json|/etc/kyri/fabric/cadv-000006.json|a242a4b3c7bef26fc8fcdcfcf1d3f9fad7a7b0d6671bfe17e949036013a52f5b|5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c|e542651a4c6f2afd27b6c1141f75b6433f6f348267477608b24658710758c56b|-|-|-|-"
"CROUTE-0005|provisioning/fabric/g11-bc-m-croute-0005-freeze.txt|6d8311e51560081a765bdb2bce5aacb1b0f296138198c272f26d3200de3f713a|678|sha256:c2ded2c50ee8cee42d9a18faaef85a03d697b136c160f2f25ab9589ff9169bfb|create-route|CROUTE-0005|/etc/kyri/fabric/croute-0005.json|/etc/kyri/fabric/cinst-000005.json|77aac8c8e8aa2e40a2bc9c9888ead1b9ecbb5444f41d8d1a1b41c7e2c483e1e3|bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda|712730063d90f83d86b097aefc7fca5df36a443c8c84a3ab67396611db70d38c|-|-|-|-"
"CADV-000007|provisioning/fabric/g11-bc-n-cadv-000007-freeze.txt|962555b33e62918f2fbd8dde9d6c26068de0c100436f125b0ba0072cbb6eb81d|673|sha256:f3fe5fa5960f0a623e7da2cd2be860136b039676f1536a4805fec38f2328de62|register-advertisement|CADV-000007|/etc/kyri/fabric/cadv-000007.json|/etc/kyri/fabric/cadv-000006.json|ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad|223d6ec3dbcfa686d32be07d4b6d5b01613de04a14b6bb563f845442ab7348ec|8f1df4b739ca5dd416fc90fba97401eda7996da22f7b145d0be4d69c46258add|-|2026-09-23T06:00:00-05:00|-|-"
"CINST-000006|provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt|6746234a2b1293052c223ff4a3e253286129ddf58b9d8397d1ecf4d04175e162|1269|sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372|admit-instance|CINST-000006|/etc/kyri/fabric/cinst-000006.json|/etc/kyri/fabric/cadv-000007.json|5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c|850af1361812ee04212c6c525a276868ae5ab81883291367ebc18cee91fda8da|3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28|-|2026-09-23T06:00:00-05:00|CINST-000006|-"
"CROUTE-0006|provisioning/fabric/g11-bc-n-croute-0006-freeze.txt|cd7a1f9a8cd5f982d3f62b7d02ff253bc6c33b006a9aa0717aff162a1e40a78c|678|sha256:4a81d1c7fc7c023de601ea004a8bbd3ee9d4bb150b9867e52e1c7075447035a9|create-route|CROUTE-0006|/etc/kyri/fabric/croute-0006.json|/etc/kyri/fabric/cinst-000006.json|bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda|6d8311e51560081a765bdb2bce5aacb1b0f296138198c272f26d3200de3f713a|1549986cf2119f9da4af805cf5cbb5733f9c0fa1d28b76e25dc3e78be7f2cb78|-|2026-09-23T06:00:00-05:00|CINST-000006|provisioning/fabric/g11-bc-n-croute-0006-input.json"
"CSEL-000004|provisioning/fabric/g11-bc-n-csel-000004-freeze.txt|d04171c50397be2d41f8d066b526f237d982ac1df113840eb81afa6ec44c2f29|605|sha256:2856ff77601e24e80f9414abf93a6eb4719d0514b386ceaca9472e712f1fd437|select|CSEL-000004|/etc/kyri/fabric/csel-000004.json|/etc/kyri/fabric/croute-0006.json|60857d684434657e6b26207308ba630d7007bf1564910d6fadcd91ba3f80dffd|700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e|f122e53034eeca45ce7b1d8ac5afdc9562a16a086757e203291a8ce1b018cefb|CINST-000006|2026-09-23T06:00:00-05:00|CINST-000006|provisioning/fabric/g11-bc-n-csel-000004-input.json"
)

# The withdrawn G11-BC-M CSEL-000004 artifact is deliberately NOT a row here.
# It is a tombstone, asserted separately below. Its reviewed bytes remain
# recoverable at the commit named in WITHDRAWN_HISTORICAL_COMMIT.
WITHDRAWN_CSEL_ARTIFACT="provisioning/fabric/g11-bc-m-csel-000004-freeze.txt"
WITHDRAWN_CSEL_DIGEST=60857d684434657e6b26207308ba630d7007bf1564910d6fadcd91ba3f80dffd
WITHDRAWN_HISTORICAL_COMMIT=77670b71749cd051cb1a0825ca93163dda04b982

# The CINV-000003 payload, committed as bytes rather than as a digest in prose.
# The lost Option-B payload is why: its digests were recorded and its body was
# not, and it could not be re-rendered from anything in the repository.
PAYLOAD_ARTIFACT="provisioning/execution/g11-bc-n-cinv-000003-payload.json"
PAYLOAD_RAW_SHA256=d01faccc67b83c60051348422861c121211a4079f7748572bad0a4882575a569
PAYLOAD_RAW_BYTES=300
PAYLOAD_CANONICAL_DIGEST=591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
PAYLOAD_CANONICAL_BYTES=271
PAYLOAD_OPERATION=verify-execution-boundary

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
  gate_until="$(field "${row}" 13)"
  gate_instance="$(field "${row}" 14)"
  inert_input="$(field "${row}" 15)"

  printf '\n--- %s ---\n' "${name}"

  if [[ ! -f "${artifact}" ]]; then
    fail "${name}: the freeze artifact is missing"
    continue
  fi

  # ---- the body is committed, and it is the reviewed body -----------------
  #
  # Two shapes, judged identically once the bytes are in hand.
  #
  # A heredoc block: extracted the way the operator's shell would see it, the
  # literal text between the BODY heredoc markers, with no substitution.
  #
  # An inert-input block: the committed file IS the body. The block must copy
  # that exact path and must not carry a BODY heredoc of its own, because two
  # copies of reviewed bytes are two things that can disagree.
  rendered="${WORK}/${name}.json"
  if [[ "${inert_input}" == "-" ]]; then
    sed -n "/^cat > \"\${TMP}\" <<'BODY'\$/,/^BODY\$/p" "${artifact}" \
      | sed '1d;$d' > "${rendered}"
  else
    if [[ -f "${ROOT}/${inert_input}" ]]; then
      pass "${name}: the reviewed body is committed at ${inert_input}"
    else
      fail "${name}: the committed body ${inert_input} is missing"
    fi
    cp "${ROOT}/${inert_input}" "${rendered}" 2>/dev/null || : > "${rendered}"
    if grep -qF -- "${inert_input}" "${artifact}"; then
      pass "${name}: the block sources its body from ${inert_input}"
    else
      fail "${name}: the block does not reference ${inert_input}"
    fi
    if grep -q "^cat > \"\${TMP}\" <<'BODY'\$" "${artifact}"; then
      fail "${name}: the block restates the body in a heredoc as well as sourcing it"
    else
      pass "${name}: the block carries no second copy of the reviewed bytes"
    fi
  fi

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
             "the superseded body|${superseded}" \
             "the accepted predecessor body|${accepted_prev}" \
             "the production Fabric baseline|${baseline}"; do
    label="${pin%%|*}"; value="${pin##*|}"
    if grep -qF -- "${value}" "${artifact}"; then
      pass "${name}: pins ${label}"
    else
      fail "${name}: does not pin ${label} (${value})"
    fi
  done

  # THE EXECUTABLE PIN, not merely a mention. Every block explains which
  # baseline it replaces and why, so an earlier aggregate legitimately appears
  # in the prose; what must be current is the value the block actually compares
  # against. A ceremony prepared before its predecessor was written carries the
  # wrong FABRIC_BEFORE and is caught here rather than by an operator.
  pinned_baseline="$(sed -n 's/^FABRIC_BEFORE=\(.*\)$/\1/p' "${artifact}" | head -1)"
  if [[ "${pinned_baseline}" == "${baseline}" ]]; then
    pass "${name}: FABRIC_BEFORE is the step's own baseline"
  else
    fail "${name}: FABRIC_BEFORE is ${pinned_baseline:-unset}, expected ${baseline}"
  fi

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

  # It is a FREEZE, not a write. Scoped to PRODUCTION: a block may run the
  # subcommand against a scratch copy -- the current-eligibility gate has to,
  # because the candidate does not exist anywhere else to be judged -- but it
  # may reach the live store exactly once, and only with --preflight.
  # Continuation lines are joined first, so each invocation is judged whole:
  # a call is only production if its OWN --store-root names the live store.
  # Read-only subcommands such as `inspect` are not record-creating and are not
  # counted; what is counted is the one subcommand that can create this record.
  joined="${WORK}/${name}.joined"
  sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "${artifact}" > "${joined}"
  prod_calls=0
  prod_unguarded=0
  while IFS= read -r call; do
    [[ "${call}" == *"--store-root /var/lib/kyri/fabric"* ]] || continue
    prod_calls=$((prod_calls + 1))
    [[ "${call}" == *"--preflight"* ]] || prod_unguarded=$((prod_unguarded + 1))
  done < <(grep -- "tools.fabric.cli ${subcommand}" "${joined}" || true)
  if (( prod_calls == 1 && prod_unguarded == 0 )); then
    pass "${name}: runs ${subcommand} against production exactly once, and only with --preflight"
  else
    fail "${name}: runs ${subcommand} against production ${prod_calls} times, ${prod_unguarded} without --preflight"
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

  # ---- the current-time gate ----------------------------------------------
  #
  # The engine cannot do this. It judges at the instant the request names, so
  # an artifact whose authority lapsed yesterday still preflights clean today.
  # The gate is the operator's only warning, and it must come BEFORE the
  # install -- a refusal after the file is in /etc/kyri/fabric has already left
  # a stale frozen input occupying the destination.
  if [[ "${gate_until}" != "-" ]]; then
    if grep -qF -- "${gate_until}" "${artifact}"; then
      pass "${name}: pins the gated window end ${gate_until}"
    else
      fail "${name}: does not pin the gated window end ${gate_until}"
    fi
    gate_ok=1
    # shellcheck disable=SC2016  # these are literal text in the artifact
    grep -q 'now = datetime.now().astimezone()' "${artifact}" || gate_ok=0
    grep -q 'if now < observed:' "${artifact}" || gate_ok=0
    grep -q 'if now >= expires:' "${artifact}" || gate_ok=0
    if (( gate_ok )); then
      pass "${name}: gates observed_at <= now < valid_until against the operator clock"
    else
      fail "${name}: has no current-time freshness gate"
    fi

    # Read out of the rendered body and the live store, never restated: a gate
    # carrying its own copy of the window can drift from the authority it
    # guards. So: it must parse instants, none of them off a date literal, and
    # it must name at least two window fields it read out of data.
    #
    # This used to count `fromisoformat(` call sites and demand two. That is a
    # proxy for the property, not the property, and it punished the correct
    # refactor -- one parse helper called four times reads MORE windows from
    # authority than two open-coded calls, and scored worse. The fields are
    # counted instead, because the fields are what has to come from authority.
    #
    # Scoped to the gate program, so a field named in a comment elsewhere in
    # the artifact cannot stand in for one the gate actually reads.
    gate_program="${WORK}/gate-program.py"
    sed -n "/<<'GATE_PY'\$/,/^GATE_PY\$/p" "${artifact}" | sed '1d;$d' > "${gate_program}"
    fields=0
    for window_field in observed_at valid_until admitted_at admitted_until; do
      grep -q "\"${window_field}\"" "${gate_program}" && fields=$((fields + 1))
    done
    if (( fields >= 2 )) \
       && grep -q 'datetime.fromisoformat(' "${gate_program}" \
       && ! grep -qE 'fromisoformat\("[0-9]{4}-' "${gate_program}"; then
      pass "${name}: the gate reads its windows from authority, not from date literals (${fields} fields)"
    else
      fail "${name}: the gate restates a window as a constant (${fields} window fields read)"
    fi

    gate_line="$(grep -n 'current-time freshness gate' "${artifact}" | tail -1 | cut -d: -f1)"
    inst_line="$(grep -n 'install -o root -g cschott' "${artifact}" | head -1 | cut -d: -f1)"
    if [[ -n "${gate_line}" && -n "${inst_line}" ]] && (( gate_line < inst_line )); then
      pass "${name}: the current-time gate precedes the install"
    else
      fail "${name}: the current-time gate does not precede the install"
    fi
  fi

  # Where an instance exists to judge, the block must recompute its eligibility
  # at the current clock too -- the window being open does not mean the
  # instance is still admitted.
  if [[ "${gate_instance}" != "-" ]]; then
    if grep -qF -- "compute-eligibility" "${artifact}" \
       && grep -qF -- "${gate_instance}" "${artifact}"; then
      pass "${name}: recomputes current eligibility for ${gate_instance}"
    else
      fail "${name}: does not recompute current eligibility for ${gate_instance}"
    fi
    # And it must be evaluated at the clock, not at a pinned instant.
    # shellcheck disable=SC2016  # the pattern is literal text in the artifact
    if grep -q -- '--evaluated-at "$(date -Is)"' "${artifact}"; then
      pass "${name}: evaluates eligibility at the current clock"
    else
      fail "${name}: does not evaluate eligibility at the current clock"
    fi
    elig_line="$(grep -n 'compute-eligibility' "${artifact}" | head -1 | cut -d: -f1)"
    inst_line2="$(grep -n 'install -o root -g cschott' "${artifact}" | head -1 | cut -d: -f1)"
    if [[ -n "${elig_line}" && -n "${inst_line2}" ]] && (( elig_line < inst_line2 )); then
      pass "${name}: the eligibility gate precedes the install"
    else
      fail "${name}: the eligibility gate does not precede the install"
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

# ---- the withdrawn G11-BC-M CSEL artifact ----------------------------------
#
# It is a tombstone, and the point of a tombstone is that running it does
# nothing. The original block accepted cleanly after its authority expired, so
# "it will refuse on its own" was exactly the assumption that failed.

printf '\n--- withdrawn G11-BC-M CSEL-000004 ---\n'
withdrawn="${ROOT}/${WITHDRAWN_CSEL_ARTIFACT}"
if [[ -f "${withdrawn}" ]]; then
  pass "withdrawn: the tombstone is present at ${WITHDRAWN_CSEL_ARTIFACT}"
else
  fail "withdrawn: ${WITHDRAWN_CSEL_ARTIFACT} is missing"
fi

# Executing it must refuse, nonzero, and say so on stderr.
if tomb_out="$(bash "${withdrawn}" 2>&1)"; then
  fail "withdrawn: executing the tombstone succeeded; it must refuse"
else
  pass "withdrawn: executing the tombstone exits nonzero"
fi
for phrase in "REFUSE" "expired" "MUST NOT be used" "${WITHDRAWN_HISTORICAL_COMMIT}"; do
  if printf '%s' "${tomb_out}" | grep -qF -- "${phrase}"; then
    pass "withdrawn: the refusal states '${phrase}'"
  else
    fail "withdrawn: the refusal does not state '${phrase}'"
  fi
done

# No renderable body may remain in it. This is the whole reason it was
# replaced: a stale body that still renders is a stale body someone can paste.
tomb_body="${WORK}/withdrawn.json"
sed -n "/^cat > \"\${TMP}\" <<'BODY'\$/,/^BODY\$/p" "${withdrawn}" | sed '1d;$d' > "${tomb_body}"
if [[ ! -s "${tomb_body}" ]]; then
  pass "withdrawn: the tombstone carries no renderable body"
else
  fail "withdrawn: the tombstone still renders a body"
fi

# The reviewed bytes stay attributable, and the tombstone says where.
if grep -qF -- "${WITHDRAWN_CSEL_DIGEST}" "${withdrawn}" \
   && grep -qF -- "${WITHDRAWN_HISTORICAL_COMMIT}" "${withdrawn}"; then
  pass "withdrawn: the historical digest remains attributable to ${WITHDRAWN_HISTORICAL_COMMIT}"
else
  fail "withdrawn: the historical attribution is incomplete"
fi

# ---- nothing under provisioning/fabric may still render the stale body ------
stale_found=0
while IFS= read -r candidate; do
  rendered_stale="${WORK}/stale.json"
  sed -n "/^cat > \"\${TMP}\" <<'BODY'\$/,/^BODY\$/p" "${candidate}" | sed '1d;$d' > "${rendered_stale}"
  [[ -s "${rendered_stale}" ]] || continue
  if [[ "$(sha256sum "${rendered_stale}" | cut -d' ' -f1)" == "${WITHDRAWN_CSEL_DIGEST}" ]]; then
    fail "stale body still renders from ${candidate}"
    stale_found=1
  fi
done < <(find "${ROOT}/provisioning/fabric" -type f)
if (( stale_found == 0 )); then
  pass "no artifact under provisioning/fabric renders the withdrawn CSEL body"
fi

# ---- every G11-BC-N ceremony is gated ---------------------------------------
#
# A new ceremony must not be able to join the chain without the clock check.
#
# Scoped to *-freeze.txt, which is what "ceremony" means here: a block an
# operator pastes into a shell. The inert *-input.json bodies beside them are
# reviewed BYTES, not ceremonies -- nothing executes them, so there is nothing
# for a clock to gate. They are judged by digest and byte count below instead.
while IFS= read -r bcn; do
  rel="${bcn#"${ROOT}/"}"
  row_gate=""
  for row in "${ARTIFACTS[@]}"; do
    [[ "$(field "${row}" 1)" == "${rel}" ]] && row_gate="$(field "${row}" 13)"
  done
  if [[ -z "${row_gate}" ]]; then
    fail "${rel} is a G11-BC-N artifact but is not in the table"
  elif [[ "${row_gate}" == "-" ]]; then
    fail "${rel} is a G11-BC-N artifact with no current-time gate"
  else
    pass "${rel} is a G11-BC-N artifact and is gated at ${row_gate}"
  fi
done < <(find "${ROOT}/provisioning/fabric" -type f -name 'g11-bc-n-*-freeze.txt')

# ---- the inert reviewed request bodies, as bytes ---------------------------
#
# G11-BC-N reviewed the CROUTE-0006 and CSEL-000004 bodies, recorded their
# digests in prose, and committed neither. G11-BC-Q re-derived both and
# required exact agreement with the reviewed sha256 and byte count before
# committing them. These assertions are what stop that agreement from being a
# claim in a report: the bytes are here, and they are these bytes.
#
# CSEL-000004 has no executable freeze artifact yet, and must not have one
# until CROUTE-0006 is permanently written -- its baseline does not exist
# before then. Its bytes are preserved here regardless, which is the whole
# point: preserve the body now, prepare the authority later.

printf '\n--- inert reviewed request bodies ---\n'

# path | reviewed sha256 | reviewed bytes | expected record id
INERT_BODIES=(
"provisioning/fabric/g11-bc-n-croute-0006-input.json|cd7a1f9a8cd5f982d3f62b7d02ff253bc6c33b006a9aa0717aff162a1e40a78c|678|CROUTE-0006"
"provisioning/fabric/g11-bc-n-csel-000004-input.json|d04171c50397be2d41f8d066b526f237d982ac1df113840eb81afa6ec44c2f29|605|CSEL-000004"
)

for row in "${INERT_BODIES[@]}"; do
  rel="$(field "${row}" 0)"
  want_sha="$(field "${row}" 1)"
  want_bytes="$(field "${row}" 2)"
  want_record="$(field "${row}" 3)"
  body="${ROOT}/${rel}"

  if [[ ! -f "${body}" ]]; then
    fail "inert: ${rel} is missing"
    continue
  fi
  pass "inert: ${rel} is committed"

  got_sha="$(sha256sum "${body}" | cut -d' ' -f1)"
  if [[ "${got_sha}" == "${want_sha}" ]]; then
    pass "inert: ${want_record} sha256 ${want_sha}"
  else
    fail "inert: ${want_record} sha256 is ${got_sha}, reviewed ${want_sha}"
  fi

  got_bytes="$(wc -c < "${body}")"
  if [[ "${got_bytes}" == "${want_bytes}" ]]; then
    pass "inert: ${want_record} is exactly ${want_bytes} bytes"
  else
    fail "inert: ${want_record} is ${got_bytes} bytes, reviewed ${want_bytes}"
  fi

  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${body}" 2>/dev/null; then
    pass "inert: ${want_record} is one JSON document"
  else
    fail "inert: ${want_record} is not valid JSON"
  fi

  # It is a request body, not a ceremony: nothing in it may be executable.
  if head -c 2 "${body}" | grep -q '#!'; then
    fail "inert: ${rel} carries a shebang"
  else
    pass "inert: ${rel} carries no shebang"
  fi
done

# CSEL-000004's ceremony was withheld until CROUTE-0006 was written, because
# its baseline did not exist before then. CROUTE-0006 is written, so the
# artifact now exists and the guard that withheld it is spent.
#
# What replaces it is stronger and outlives it: the executable FABRIC_BEFORE of
# every artifact must be that step's own baseline, asserted per row above. An
# artifact prepared before its predecessor landed pins a superseded aggregate
# and fails there -- which is the property the existence guard was standing in
# for, checked directly instead of by absence.

# ---- the CINV-000003 payload, as bytes -------------------------------------
#
# The Option-B payload was reviewed, pinned by digest, and never committed; it
# could not be re-rendered from anything in the repository when it was needed.
# These are the bytes, so that cannot happen twice.

printf '\n--- CINV-000003 payload ---\n'
payload="${ROOT}/${PAYLOAD_ARTIFACT}"
if [[ -f "${payload}" ]]; then
  pass "payload: committed at ${PAYLOAD_ARTIFACT}"
  payload_sha="$(sha256sum "${payload}" | cut -d' ' -f1)"
  payload_bytes="$(wc -c < "${payload}")"
  if [[ "${payload_sha}" == "${PAYLOAD_RAW_SHA256}" ]]; then
    pass "payload: raw sha256 ${PAYLOAD_RAW_SHA256}"
  else
    fail "payload: raw sha256 is ${payload_sha}, reviewed ${PAYLOAD_RAW_SHA256}"
  fi
  if [[ "${payload_bytes}" == "${PAYLOAD_RAW_BYTES}" ]]; then
    pass "payload: raw bytes ${PAYLOAD_RAW_BYTES}"
  else
    fail "payload: raw bytes ${payload_bytes}, reviewed ${PAYLOAD_RAW_BYTES}"
  fi
  # The canonical digest is what the CINV record binds, and it is a different
  # number from the file digest. Both are checked, against released code.
  if canon="$(python3 - "${payload}" <<'CANON_PY'
import json, sys, hashlib, pathlib
from tools.capability.invocation_identity import canonical_bytes
raw = pathlib.Path(sys.argv[1]).read_bytes()
doc = json.loads(raw)
blob = canonical_bytes(doc)
print(hashlib.sha256(blob).hexdigest())
print(len(blob))
print(doc["operation"])
CANON_PY
  )"; then
    canon_digest="$(printf '%s' "${canon}" | sed -n 1p)"
    canon_bytes="$(printf '%s' "${canon}" | sed -n 2p)"
    canon_op="$(printf '%s' "${canon}" | sed -n 3p)"
    if [[ "${canon_digest}" == "${PAYLOAD_CANONICAL_DIGEST}" ]]; then
      pass "payload: canonical digest ${PAYLOAD_CANONICAL_DIGEST}"
    else
      fail "payload: canonical digest is ${canon_digest}, reviewed ${PAYLOAD_CANONICAL_DIGEST}"
    fi
    if [[ "${canon_bytes}" == "${PAYLOAD_CANONICAL_BYTES}" ]]; then
      pass "payload: canonical bytes ${PAYLOAD_CANONICAL_BYTES}"
    else
      fail "payload: canonical bytes ${canon_bytes}, reviewed ${PAYLOAD_CANONICAL_BYTES}"
    fi
    if [[ "${canon_op}" == "${PAYLOAD_OPERATION}" ]]; then
      pass "payload: operation ${PAYLOAD_OPERATION}"
    else
      fail "payload: operation ${canon_op}, reviewed ${PAYLOAD_OPERATION}"
    fi
  else
    fail "payload: the canonical digest could not be computed"
  fi
else
  fail "payload: ${PAYLOAD_ARTIFACT} is missing"
fi

# ---- the regression the withdrawal exists for ------------------------------
#
# A backdated evaluated_at must never make an expired authority executable.
# Run the committed gate against a window that has demonstrably closed -- the
# accepted CADV-000006 input, whose authority ended 2026-09-19T06:00:00-05:00 --
# and require a refusal. If this ever passes, the gate has stopped working and
# the G11-BC-M failure is reachable again.

# EVERY gated artifact, not the first one found. The `break` that used to be
# here stopped at CADV-000007, whose gate is single-channel and was sound, and
# so the CINST-000006 gate below it was never extracted, never executed, and
# shipped broken past 136 passing assertions. A loop that stops at the first
# row proves something about that row and nothing about the table.
printf '\n--- backdated-expiry regression ---\n'
gated_artifacts=()
for row in "${ARTIFACTS[@]}"; do
  [[ "$(field "${row}" 13)" != "-" ]] && gated_artifacts+=("${ROOT}/$(field "${row}" 1)")
done
if (( ${#gated_artifacts[@]} == 0 )); then
  fail "regression: no gated artifact in the table to extract from"
fi
for gated_artifact in ${gated_artifacts[@]+"${gated_artifacts[@]}"}; do
  label="provisioning/fabric/$(basename "${gated_artifact}")"
  gate_py="${WORK}/gate.py"
  sed -n "/<<'GATE_PY'\$/,/^GATE_PY\$/p" \
    "${gated_artifact}" | sed '1d;$d' > "${gate_py}"
  if [[ ! -s "${gate_py}" ]]; then
    fail "regression: ${label}: the current-time gate could not be extracted"
    continue
  fi
  pass "regression: ${label}: the current-time gate was extracted"

  # Four spellings, because four records need different things. An
  # advertisement carries its own window, so its gate reads one file. An
  # instance's window is its admission and the governing advertisement's, so
  # its gate reads two -- the body, then the inspect output. A route carries no
  # window at all: both windows it rests on are live records, so its gate reads
  # three -- the body, the advertisement, then the instance. A selection rests
  # on all of that AND on the route that must resolve it, so its gate reads
  # four. The gate says which it is; this does not guess, and does not assume
  # every gate looks like the first one.
  if grep -q 'sys.argv\[4\]' "${gate_py}"; then
    arity=4
  elif grep -q 'sys.argv\[3\]' "${gate_py}"; then
    arity=3
  elif grep -q 'sys.argv\[2\]' "${gate_py}"; then
    arity=2
  else
    arity=1
  fi
  pass "regression: ${label}: the gate reads ${arity} input file(s)"

  expired="${WORK}/expired.json"
  open_window="${WORK}/open.json"
  body_fixture="${WORK}/gate-body.json"
  instance_fixture="${WORK}/gate-instance.json"
  route_fixture="${WORK}/gate-route.json"
  python3 - "${expired}" "${open_window}" "${body_fixture}" "${arity}" \
           "${instance_fixture}" "${route_fixture}" <<'FIXTURE_PY'
import json
import sys
from datetime import datetime, timedelta

expired_path, open_path, body_path, arity, instance_path, route_path = sys.argv[1:7]
now = datetime.now().astimezone()
day = timedelta(days=1)
hour = timedelta(hours=1)


def window(observed, expires):
    if arity == "1":
        # The advertisement body IS the window.
        return {"observed_at": observed, "valid_until": expires}
    # The inspect output the instance and route gates read.
    return {"findings": [], "reason": None,
            "records": [{"advertisement_id": "CADV-000007",
                         "observed_at": observed,
                         "valid_until": expires}]}


# The withdrawn G11-BC-M window: closed 2026-09-19T06:00:00-05:00.
json.dump(window("2026-09-15T06:00:00-05:00", "2026-09-19T06:00:00-05:00"),
          open(expired_path, "w"), indent=2)
json.dump(window((now - day).isoformat(), (now + day).isoformat()),
          open(open_path, "w"), indent=2)

if arity == "4":
    # A selection body: it names a request CLASS, not a route, so the class
    # must match the route fixture field for field or the gate refuses before
    # it ever looks at a clock.
    request_class = {"capability_id": "CAPDEF-0001",
                     "contract_id": "CCON-0001",
                     "data_classification": "internal",
                     "locality": "local-only",
                     "accepted_contract_versions": ["1.0.0"]}
    body = dict(request_class)
    body["local_node_identity"] = "HOST-0001"
    body["recorded_at"] = now.isoformat()
    body["evaluated_at"] = now.isoformat()
    json.dump(body, open(body_path, "w"), indent=2)
    json.dump({"findings": [], "reason": None,
               "records": [{"instance_id": "CINST-000006",
                            "advertisement_id": "CADV-000007",
                            "lifecycle_state": "admitted",
                            "admitted_at": (now - hour).isoformat(),
                            "admitted_until": (now + hour).isoformat()}]},
              open(instance_path, "w"), indent=2)
    route = dict(request_class)
    route["route_id"] = "CROUTE-0006"
    route["route_version"] = 6
    route["candidate_instances"] = ["CINST-000006"]
    json.dump({"findings": [], "reason": None, "records": [route]},
              open(route_path, "w"), indent=2)
elif arity == "3":
    # A route body: no window of its own, so it states what it routes to and
    # when it was recorded. The admission it rests on is a separate live
    # record, supplied as the third file.
    json.dump({"candidate_instances": ["CINST-000006"],
               "supersedes": "CROUTE-0005",
               "route_version": 6,
               "recorded_at": now.isoformat()},
              open(body_path, "w"), indent=2)
    json.dump({"findings": [], "reason": None,
               "records": [{"instance_id": "CINST-000006",
                            "advertisement_id": "CADV-000007",
                            "lifecycle_state": "admitted",
                            "admitted_at": (now - hour).isoformat(),
                            "admitted_until": (now + hour).isoformat()}]},
              open(instance_path, "w"), indent=2)
else:
    json.dump({"advertisement_id": "CADV-000007",
               "admitted_at": (now - hour).isoformat(),
               "admitted_until": (now + hour).isoformat()},
              open(body_path, "w"), indent=2)
FIXTURE_PY

  if [[ "${arity}" == 4 ]]; then
    expired_argv=("${body_fixture}" "${expired}" "${instance_fixture}" "${route_fixture}")
    open_argv=("${body_fixture}" "${open_window}" "${instance_fixture}" "${route_fixture}")
  elif [[ "${arity}" == 3 ]]; then
    expired_argv=("${body_fixture}" "${expired}" "${instance_fixture}")
    open_argv=("${body_fixture}" "${open_window}" "${instance_fixture}")
  elif [[ "${arity}" == 2 ]]; then
    expired_argv=("${body_fixture}" "${expired}")
    open_argv=("${body_fixture}" "${open_window}")
  else
    expired_argv=("${expired}")
    open_argv=("${open_window}")
  fi

  if python3 "${gate_py}" "${expired_argv[@]}" >/dev/null 2>&1; then
    fail "regression: ${label}: the gate ACCEPTED the expired G11-BC-M window"
  else
    pass "regression: ${label}: the gate refuses the expired G11-BC-M window"
  fi

  # And it must still accept a window that is genuinely open, or it is not a
  # gate, it is a brick.
  if python3 "${gate_py}" "${open_argv[@]}" >/dev/null 2>&1; then
    pass "regression: ${label}: the gate accepts a window that is open now"
  else
    fail "regression: ${label}: the gate refuses a window that is open now"
  fi
done

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Fabric freeze artifact validation passed.\n'
else
  printf 'Fabric freeze artifact validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
