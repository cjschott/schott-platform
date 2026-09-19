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
#   current-time gate valid_until | current-eligibility instance
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
"CINST-000005|provisioning/fabric/g11-bc-m-cinst-000005-freeze.txt|850af1361812ee04212c6c525a276868ae5ab81883291367ebc18cee91fda8da|1269|sha256:be0daf493301139aabb7ef6224b93203d744545665ef6f470a8d6236713ede8b|admit-instance|CINST-000005|/etc/kyri/fabric/cinst-000005.json|/etc/kyri/fabric/cadv-000006.json|a242a4b3c7bef26fc8fcdcfcf1d3f9fad7a7b0d6671bfe17e949036013a52f5b|5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c|e542651a4c6f2afd27b6c1141f75b6433f6f348267477608b24658710758c56b|-|-|-"
"CROUTE-0005|provisioning/fabric/g11-bc-m-croute-0005-freeze.txt|6d8311e51560081a765bdb2bce5aacb1b0f296138198c272f26d3200de3f713a|678|sha256:c2ded2c50ee8cee42d9a18faaef85a03d697b136c160f2f25ab9589ff9169bfb|create-route|CROUTE-0005|/etc/kyri/fabric/croute-0005.json|/etc/kyri/fabric/cinst-000005.json|77aac8c8e8aa2e40a2bc9c9888ead1b9ecbb5444f41d8d1a1b41c7e2c483e1e3|bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda|712730063d90f83d86b097aefc7fca5df36a443c8c84a3ab67396611db70d38c|-|-|-"
"CADV-000007|provisioning/fabric/g11-bc-n-cadv-000007-freeze.txt|962555b33e62918f2fbd8dde9d6c26068de0c100436f125b0ba0072cbb6eb81d|673|sha256:f3fe5fa5960f0a623e7da2cd2be860136b039676f1536a4805fec38f2328de62|register-advertisement|CADV-000007|/etc/kyri/fabric/cadv-000007.json|/etc/kyri/fabric/cadv-000006.json|ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad|223d6ec3dbcfa686d32be07d4b6d5b01613de04a14b6bb563f845442ab7348ec|8f1df4b739ca5dd416fc90fba97401eda7996da22f7b145d0be4d69c46258add|-|2026-09-23T06:00:00-05:00|-"
"CINST-000006|provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt|6746234a2b1293052c223ff4a3e253286129ddf58b9d8397d1ecf4d04175e162|1269|sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372|admit-instance|CINST-000006|/etc/kyri/fabric/cinst-000006.json|/etc/kyri/fabric/cadv-000007.json|5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c|850af1361812ee04212c6c525a276868ae5ab81883291367ebc18cee91fda8da|3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28|-|2026-09-23T06:00:00-05:00|CINST-000006"
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
    # guards. Two parses at least, and not one of them off a date literal.
    parses="$(grep -c 'datetime.fromisoformat(' "${artifact}" || true)"
    if (( parses >= 2 )) && ! grep -qE 'fromisoformat\("[0-9]{4}-' "${artifact}"; then
      pass "${name}: the gate reads its windows from authority, not from date literals"
    else
      fail "${name}: the gate restates a window as a constant (${parses} parses)"
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

# ---- every G11-BC-N artifact is gated --------------------------------------
#
# A new artifact must not be able to join the chain without the clock check.
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
done < <(find "${ROOT}/provisioning/fabric" -type f -name 'g11-bc-n-*')

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

printf '\n--- backdated-expiry regression ---\n'
gated_artifact=""
for row in "${ARTIFACTS[@]}"; do
  [[ "$(field "${row}" 13)" != "-" ]] && gated_artifact="${ROOT}/$(field "${row}" 1)" && break
done
if [[ -n "${gated_artifact}" ]]; then
  gate_py="${WORK}/gate.py"
  sed -n "/^GATE=\"\$(python3 - \"\${TMP}\" <<'GATE_PY'\$/,/^GATE_PY\$/p" \
    "${gated_artifact}" | sed '1d;$d' > "${gate_py}"
  if [[ -s "${gate_py}" ]]; then
    pass "regression: the current-time gate was extracted from the committed artifact"

    expired="${WORK}/expired.json"
    cat > "${expired}" <<'EXPIRED_BODY'
{
  "observed_at": "2026-09-15T06:00:00-05:00",
  "valid_until": "2026-09-19T06:00:00-05:00"
}
EXPIRED_BODY
    if python3 "${gate_py}" "${expired}" >/dev/null 2>&1; then
      fail "regression: the gate ACCEPTED the expired G11-BC-M window"
    else
      pass "regression: the gate refuses the expired G11-BC-M window"
    fi

    # And it must still accept a window that is genuinely open, or it is not a
    # gate, it is a brick.
    open_body="${WORK}/open.json"
    python3 - "${open_body}" <<'OPEN_PY'
import sys
from datetime import datetime, timedelta
now = datetime.now().astimezone()
open(sys.argv[1], "w").write(
    '{\n  "observed_at": "%s",\n  "valid_until": "%s"\n}\n'
    % ((now - timedelta(days=1)).isoformat(), (now + timedelta(days=1)).isoformat()))
OPEN_PY
    if python3 "${gate_py}" "${open_body}" >/dev/null 2>&1; then
      pass "regression: the gate accepts a window that is open now"
    else
      fail "regression: the gate refuses a window that is open now"
    fi
  else
    fail "regression: the current-time gate could not be extracted"
  fi
else
  fail "regression: no gated artifact in the table to extract from"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Fabric freeze artifact validation passed.\n'
else
  printf 'Fabric freeze artifact validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
