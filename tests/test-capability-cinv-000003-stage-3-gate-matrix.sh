#!/usr/bin/env bash
set -Eeuo pipefail

# BLOCK B OF THE CINV-000003 STAGE-3 CEREMONY, AND ITS 22-CASE FAILURE MATRIX,
# AGAINST A SYNTHETIC PRE-STAGE-3 FIXTURE.
#
# WHY THIS SUITE EXISTS SEPARATELY. The production-host rehearsal
# (tests/test-capability-cinv-000003-stage-3-rehearsal.sh) went to SPENT MODE at
# G11-BC-AJ: Stage 3 has run, CRES-000002 exists, CINV-000003 is concluded, and
# rebuilding its substrate by subtracting later history from production meant a
# hand-kept list that had already drifted twice. Going spent was right, and it
# cost BLOCK B's gates and their sabotage matrix -- the one piece of coverage not
# recovered anywhere else. The reviewer's G11-BC-AL ruling is to recover it HERE,
# against a fixture built for the purpose.
#
# THE PRODUCTION-HOST REHEARSAL STAYS SPENT. Nothing in this file makes it
# executable again, and nothing here drives the coordinator, the protocol, or
# BLOCK C. What runs is BLOCK B -- the gates, which only ever READ -- and the 22
# ways it must refuse.
#
# THE FIXTURE IS ASSEMBLED, NOT REWOUND, and the difference is the point.
#
#   A REWIND copies production and removes the objects it knows about by name. It
#   drifts: every later accepted ceremony adds something the list does not
#   mention, and the fixture silently carries it.
#
#   THIS ASSEMBLES by HIGH-WATER MARK. The pre-Stage-3 state is defined by what
#   had been allocated at that moment -- CADM up to 000002, CMUT up to
#   000000000010, CRES up to 000001, and no transition at sequence 3 or beyond for
#   CINV-000001 or CINV-000003. Those are facts about the past and they never
#   move. Anything above a mark is excluded by DERIVATION, so a record allocated
#   next year is excluded by the same rule that excludes CADM-000003, with nothing
#   edited here.
#
# AND IT IS PROVED COMPLETE BY CONTENT. The assembled store must reproduce the
# accepted pre-Stage-3 aggregate
#
#   648066f6e79af23732eb6131bf772579bad898e71179def5ae4dabb6475e133a
#
# EXACTLY, or this suite refuses to run at all. That pin is what turns the
# derivation into a checked claim: if the marks were wrong, or production's
# reviewed objects had changed, the fixture is rejected rather than driven.
#
# HOST-ONLY. The reviewed objects the fixture is assembled FROM -- the launch
# authorisation, the handoff, the staged tree, the Fabric chain, the published
# payload -- live on the host, and they are the real accepted bytes rather than
# synthesised look-alikes. What is synthetic is the STORE SHAPE, not its contents.
#
# NOTHING HERE WRITES TO PRODUCTION. The gates read a substituted root; the
# aggregate is measured before and after; the handoff output leaf, which §13 gave
# to the execution identity, is recreated empty because the coordinator cannot
# read it, exactly as the rehearsal did.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh disable=SC1091
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /data/kyri/capability-runtime /usr/lib/kyri/python \
                   /etc/kyri/backing-store.json /var/lib/kyri/fabric \
                   /data/kyri/capability-handoff/CINV-000003 \
                   /data/kyri/work/g11bcn/third-invoke.json

CEREMONY="${ROOT}/provisioning/execution/g11-bc-aa-cinv-000003-stage-3-ceremony.txt"
PRODUCTION=/data/kyri/capability-runtime          # prod-path-reference
PRODUCTION_FABRIC=/var/lib/kyri/fabric            # prod-path-reference

# WHICH FABRIC AUTHORITY THE GATES ARE ASKED ABOUT. Production by default, and
# nothing about the gates changes when it is overridden -- the released verifier
# still runs at the real wall clock against a real chain, which is the whole
# point. What an override lets a reviewer do is ask the SAME gates about a
# renewed chain that has not been written to production yet.
#
# This is a substitution of the kind `render_gates` already performs on the roots,
# and it is NOT one of the things G11-BC-AM's §I forbids: BLOCK B is not
# reordered, no verification is bypassed, no window is injected, expired
# production is not special-cased, and no intended-refusal requirement becomes a
# generic nonzero-exit assertion. The chain an override points at is a real chain
# the released write verbs produced.
FABRIC_SOURCE="${KYRI_STAGE3_FABRIC_SOURCE:-${PRODUCTION_FABRIC}}"
AUTHORITY_SELECTION="${KYRI_STAGE3_SELECTION:-CSEL-000005}"
AUTHORITY_INSTANCE="${KYRI_STAGE3_INSTANCE:-CINST-000007}"
# BLOCK B pins the route head and the advertisement separately from the
# selection, and it is right to: a chain whose selection still resolves can
# still have been superseded underneath, which is exactly what it refuses. All
# four move together or none of them do.
AUTHORITY_ROUTE="${KYRI_STAGE3_ROUTE:-CROUTE-0007}"
AUTHORITY_ADVERTISEMENT="${KYRI_STAGE3_ADVERTISEMENT:-CADV-000008}"
if [[ "${FABRIC_SOURCE}" != "${PRODUCTION_FABRIC}" ]]; then
  printf 'note     Fabric authority under test: %s (selection %s, instance %s)\n' \
    "${FABRIC_SOURCE}" "${AUTHORITY_SELECTION}" "${AUTHORITY_INSTANCE}"
  printf 'note     route head %s, advertisement %s\n' \
    "${AUTHORITY_ROUTE}" "${AUTHORITY_ADVERTISEMENT}"
fi
PRODUCTION_HANDOFF=/data/kyri/capability-handoff  # prod-path-reference
# The worker-owned output leaf, which the coordinator cannot read once §13 has
# transferred it. Named once so the exclusion is a stated fact, not a glob.
HANDOFF_OUTPUT_LEAF=out
# The accepted capability-runtime aggregate BEFORE Stage 3, which the rewound
# fixture must reproduce exactly. Pinned so the rewind is checked, not trusted.
RUNTIME_BEFORE_STAGE3=648066f6e79af23732eb6131bf772579bad898e71179def5ae4dabb6475e133a
PAYLOAD=/data/kyri/work/g11bcn/third-invoke.json  # prod-path-reference

TARGET=CINV-000003
ARTIFACT_DIGEST=6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
PAYLOAD_DIGEST=591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d -p /data/kyri g11bcaa-rehearsal.XXXXXX)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }
PRODUCTION_BEFORE="$(aggregate "${PRODUCTION}")"
FABRIC_BEFORE="$(aggregate "${FABRIC_SOURCE}")"
# Production's own aggregate, kept separately, because the final check asks
# whether PRODUCTION moved -- which must hold whichever chain the gates were
# asked about.
PRODUCTION_FABRIC_BEFORE="$(aggregate "${PRODUCTION_FABRIC}")"

# The ceremony's own BLOCK B, extracted whole. The logic under test is the
# operator's, not a paraphrase of it.
GATES="${WORK}/gates.sh"
awk "/^bash <<'GATES'\$/{on=1;next} /^GATES\$/{on=0} on" "${CEREMONY}" > "${GATES}"
if [[ -s "${GATES}" ]]; then
  pass "BLOCK B extracted whole from the reviewed ceremony ($(wc -l < "${GATES}") lines)"
else
  fail "BLOCK B could not be extracted from ${CEREMONY}"
  exit 1
fi

# ===========================================================================
# The synthetic pre-Stage-3 fixture
# ===========================================================================
#
# The high-water marks. Facts about the moment before Stage 3, which do not move.
LAST_CADM_BEFORE_STAGE3=2
LAST_CMUT_BEFORE_STAGE3=10
LAST_CRES_BEFORE_STAGE3=1
# AND THE TRANSITIONS FOLLOW FROM THE CMUT MARK, not from a list of invocations.
#
# Every lifecycle transition spends exactly one CMUT, and each mutation's intent
# NAMES the transition it journalled -- `target_kind: execution-transition`,
# `target_name: CINV-000001.000003`. So "which transitions existed before Stage 3"
# is answered by "which were journalled at or below the CMUT mark", which is one
# fact rather than two.
#
# The first attempt here excluded every transition at sequence 3 or above, which
# also removed `CINV-000002.000003` -- the CINV-000002 abandonment of 2026-09-20,
# which happened BEFORE Stage 3. The aggregate check caught it immediately, which
# is what the aggregate check is for.

build_synthetic_fixture() {
  local base="$1"
  [[ -e "${base}" ]] && { chmod -R u+w "${base}"; rm -rf "${base}"; }
  mkdir -p "${base}/handoff" "${base}/work"
  cp -a "${PRODUCTION}" "${base}/runtime"
  cp -a "${FABRIC_SOURCE}" "${base}/fabric"
  chmod -R u+w "${base}/runtime"

  # RESTRICT BY MARK, not by name. Every identity above a mark is excluded by the
  # same rule, so an object allocated after this suite was written needs no edit
  # here to be excluded.
  python3 - "${base}/runtime" "${LAST_CADM_BEFORE_STAGE3}" \
            "${LAST_CMUT_BEFORE_STAGE3}" "${LAST_CRES_BEFORE_STAGE3}" <<'RESTRICT'
import json
import os
import re
import shutil
import sys

root, cadm_mark, cmut_mark, cres_mark = sys.argv[1:5]
marks = {"CADM": int(cadm_mark), "CMUT": int(cmut_mark), "CRES": int(cres_mark)}

# Which transitions the mutations ABOVE the mark journalled. Read from the
# mutation intents, so the exclusion is derived from the CMUT mark rather than
# from a second list that could disagree with it.
post_stage3_transitions = set()
mutations = os.path.join(root, "execution", "mutations")
for name in sorted(os.listdir(mutations)):
    found = re.match(r"CMUT-(\d+)$", name)
    if not found or int(found.group(1)) <= marks["CMUT"]:
        continue
    intent = os.path.join(mutations, name, "intent")
    if not os.path.exists(intent):
        continue
    with open(intent, encoding="utf-8") as handle:
        document = json.load(handle)
    if document.get("target_kind") == "execution-transition":
        post_stage3_transitions.add(document["target_name"])

for directory, pattern in (
        (os.path.join(root, "execution", "admin-records"), r"CADM-(\d+)$"),
        (os.path.join(root, "execution", "mutations"),     r"CMUT-(\d+)$"),
        (os.path.join(root, "capability-results"),         r"CRES-(\d+)\.yaml$")):
    if not os.path.isdir(directory):
        continue
    for name in sorted(os.listdir(directory)):
        found = re.match(pattern, name)
        if not found:
            continue
        if int(found.group(1)) > marks[name.split("-")[0]]:
            path = os.path.join(directory, name)
            shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)

transitions = os.path.join(root, "execution", "transitions")
for name in sorted(os.listdir(transitions)):
    if name in post_stage3_transitions:
        os.remove(os.path.join(transitions, name))
if post_stage3_transitions - set(os.listdir(transitions)) != post_stage3_transitions:
    sys.exit("a transition named by a post-mark mutation survived the restriction")

for relative, value in (
        ("execution/cadm-counter", "%06d\n" % marks["CADM"]),
        ("execution/cmut-counter", "%012d\n" % marks["CMUT"]),
        ("sequences/capability-result.seq", "%d\n" % marks["CRES"])):
    with open(os.path.join(root, relative), "w", encoding="utf-8") as handle:
        handle.write(value)
RESTRICT

  # PROVED COMPLETE BY CONTENT. The aggregate includes pathnames, so the copy's
  # paths are rewritten to the production prefix before it is compared -- the
  # same method the rehearsal used, and the reason a copy elsewhere can be
  # measured against a pin taken on the real root.
  local assembled
  assembled="$( cd "${base}/runtime" && find . -type f -print0 | sort -z \
                | xargs -0 sha256sum | sed "s|  \./|  ${PRODUCTION}/|" \
                | sha256sum | cut -d' ' -f1 )"
  if [[ "${assembled}" != "${RUNTIME_BEFORE_STAGE3}" ]]; then
    fail "the assembled fixture is ${assembled}, not the accepted pre-Stage-3 ${RUNTIME_BEFORE_STAGE3}"
    return 1
  fi

  # The output leaf is excluded and recreated empty. §13 transferred it to the
  # execution identity -- uid 999, mode 0700 -- so the coordinator cannot read it
  # and `cp -a` of the whole subtree fails. `_verify_handoff` requires the leaf to
  # exist and be a directory and checks neither its mode nor its owner, so an
  # empty one satisfies the released code exactly without this fixture pretending
  # to hold bytes it cannot read.
  mkdir -p "${base}/handoff/${TARGET}"
  find "${PRODUCTION_HANDOFF}/${TARGET}" -mindepth 1 -maxdepth 1 \
       ! -name "${HANDOFF_OUTPUT_LEAF}" -exec cp -a {} "${base}/handoff/${TARGET}/" \;
  mkdir -p "${base}/handoff/${TARGET}/${HANDOFF_OUTPUT_LEAF}"
  chmod 0700 "${base}/handoff/${TARGET}/${HANDOFF_OUTPUT_LEAF}"
  chmod 0555 "${base}/handoff/${TARGET}"
  cp "${PAYLOAD}" "${base}/work/third-invoke.json"
  chmod 0600 "${base}/work/third-invoke.json"
  # BLOCK A's observation, represented rather than performed: the execution image
  # is present in the kyri-capability store and no kyri-CINV-000003 container
  # exists. This suite cannot read that store and does not pretend to -- the
  # witness is the operator's recorded observation, and the gate under test is the
  # one that JUDGES a witness, including its freshness.
  printf 'stage-3-observation\nimage 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190\nno-target-container kyri-%s\n' \
    "${TARGET}" > "${base}/work/witness"
  chmod 0600 "${base}/work/witness"
}

# THE LIBRARY THE CEREMONY WAS REVIEWED AGAINST, materialised from its own
# reviewed commit.
#
# BLOCK B's first gate pins the Generation-20 digests, because Generation 20 is
# what the operator ran it against. That pin is HISTORICAL EVIDENCE and is not
# edited -- the G11-BC-AJ rule. But a Generation-22 host cannot satisfy it, and a
# gate matrix that cannot get past gate one proves nothing about the other
# twenty-one.
#
# So the ceremony is given the library it was reviewed against, built from the
# Generation-20 source authority. Nothing about the gates changes; what changes is
# that the thing they measure is the thing they were written to measure. The host's
# own installed library is never substituted INTO the fixture, and the sabotage
# case "the installed runtime is not Generation 20" still exercises that very gate.
GEN20_COMMIT="$(sed -n 's/^COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' \
                "${ROOT}/provisioning/execution/install-generation-20.sh" | head -1)"
REVIEWED_LIBRARY="${WORK}/generation-20-library"
mkdir -p "${REVIEWED_LIBRARY}"
if [[ -n "${GEN20_COMMIT}" ]] \
   && (cd "${ROOT}" && git archive "${GEN20_COMMIT}" tools) \
        | tar -x -C "${REVIEWED_LIBRARY}"; then
  pass "the reviewed Generation-20 library is materialised from ${GEN20_COMMIT:0:7}, the commit its own installer pins"
else
  fail "the Generation-20 source authority could not be materialised"
  exit 1
fi
# The flattened privileged helpers live at the library root once installed, and
# BLOCK B's generation gate names some of them.
for helper in quota transition transition-action verify worker podman launcher; do
  source_file="${REVIEWED_LIBRARY}/provisioning/execution/kyri-exec-${helper}.py"
  [[ -f "${source_file}" ]] \
    && cp "${source_file}" "${REVIEWED_LIBRARY}/kyri_exec_${helper//-/_}.py"
done
true

FIX="${WORK}/fix"
printf -- '\n--- the synthetic fixture is the accepted pre-Stage-3 store ---\n'
if build_synthetic_fixture "${FIX}"; then
  pass "assembled by high-water mark, and it reproduces ${RUNTIME_BEFORE_STAGE3} exactly"
else
  fail "the synthetic fixture could not be assembled; nothing below can be trusted"
  exit 1
fi
# The facts the ruling named, each asserted of the assembled store rather than
# assumed from the aggregate.
if [[ ! -e "${FIX}/runtime/capability-results/CRES-000002.yaml" ]]; then
  pass "CRES-000002 is absent: Stage 3 has not run in this store"
else
  fail "the fixture carries CRES-000002"
fi
if [[ "$(sha256sum "${FIX}/runtime/execution/${TARGET}/launch-authorisation" | cut -d' ' -f1)" \
      == "885801a1362dcf99faaacdcdf457b7a9cecac99104012c24cfb6cfa5284f31df" ]]; then
  pass "the accepted launch authorisation is present, byte-identical"
else
  fail "the launch authorisation is not the accepted one"
fi
if [[ "$(sha256sum "${FIX}/handoff/${TARGET}/payload" | cut -d' ' -f1)" == "${PAYLOAD_DIGEST}" ]] \
   && [[ -d "${FIX}/runtime/staging/tree-sha256-${ARTIFACT_DIGEST}" ]]; then
  pass "the reviewed handoff and the staged tree are present"
else
  fail "the handoff payload or the staged tree is missing"
fi
if [[ "$(cat "${FIX}/runtime/execution/cadm-counter")" == "000002" ]] \
   && [[ "$(cat "${FIX}/runtime/execution/cmut-counter")" == "000000000010" ]] \
   && [[ "$(cat "${FIX}/runtime/sequences/capability-result.seq")" == "1" ]] \
   && [[ "$(find "${FIX}/runtime/execution/transitions" -type f | wc -l)" == "7" ]]; then
  pass "the counters and the journal are at their pre-Stage-3 values: cadm 000002, cmut 000000000010, 7 transitions, CRES seq 1"
else
  fail "the counters or the journal are not at their pre-Stage-3 values"
fi
# Paths are part of the aggregate, so the copy's are rewritten to the production
# prefix before it is compared -- the same method the runtime check above uses.
fixture_fabric="$( cd "${FIX}/fabric" && find . -type f -print0 | sort -z \
                   | xargs -0 sha256sum | sed "s|  \./|  ${FABRIC_SOURCE}/|" \
                   | sha256sum | cut -d' ' -f1 )"
if [[ "${fixture_fabric}" == "${FABRIC_BEFORE}" ]]; then
  pass "the reviewed Fabric chain is present, byte-identical to the source -- carried as it stands, with no window edited to make a gate pass"
else
  fail "the fixture's Fabric is ${fixture_fabric}, not the source's ${FABRIC_BEFORE}"
fi
printf -- '\n--- the gates, against a fixture ---\n'
render_gates() {
  local base="$1" out="$2"
  sed \
    -e "s#^RUNTIME=/data/kyri/capability-runtime\$#RUNTIME=${base}/runtime#" \
    -e "s#^HANDOFF=/data/kyri/capability-handoff\$#HANDOFF=${base}/handoff#" \
    -e "s#^FABRIC=/var/lib/kyri/fabric\$#FABRIC=${base}/fabric#" \
    -e "s#^WITNESS=/data/kyri/work/g11bcaa-stage-3-witness\$#WITNESS=${base}/work/witness#" \
    -e "s#^PAYLOAD_ROOT=/data/kyri/work/g11bcn\$#PAYLOAD_ROOT=${base}/work#" \
    -e "s#^SELECTION=CSEL-000004\$#SELECTION=${AUTHORITY_SELECTION}#" \
    -e "s#^INSTANCE=CINST-000006\$#INSTANCE=${AUTHORITY_INSTANCE}#" \
    -e "s#^ROUTE=CROUTE-0006\$#ROUTE=${AUTHORITY_ROUTE}#" \
    -e "s#^ADVERTISEMENT=CADV-000007\$#ADVERTISEMENT=${AUTHORITY_ADVERTISEMENT}#" \
    -e "s#^INSTALLED=/usr/lib/kyri/python\$#INSTALLED=${REVIEWED_LIBRARY}#" \
    -e "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${base}/runtime")#" \
    -e "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=$(aggregate "${base}/fabric")#" \
    "${GATES}" > "${out}"
}

build_synthetic_fixture "${FIX}"
rendered="${WORK}/rendered-gates.sh"
render_gates "${FIX}" "${rendered}"
if grep -qE "^(RUNTIME=${PRODUCTION}|FABRIC=${PRODUCTION_FABRIC}|HANDOFF=${PRODUCTION_HANDOFF})\$" "${rendered}"; then
  fail "a production root survived the substitution"
else
  pass "every root BLOCK B measures was substituted"
fi
if grep -q "^INSTALLED=${REVIEWED_LIBRARY}\$" "${rendered}"; then
  pass "the library under test is the reviewed Generation-20 one, not this host's"
else
  fail "the reviewed library was not substituted in"
fi
if grep -q '^TRUST=/var/lib/kyri/trust$' "${rendered}"; then
  pass "Trust still points at the real one, which the block only reads"
else
  fail "Trust was substituted away"
fi

out="${WORK}/gates.out"; status=0
( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?

# THE FABRIC AUTHORITY HAS EXPIRED SINCE STAGE 3 RAN, AND THAT IS A LEGITIMATE
# REFUSAL. BLOCK B checks the Fabric authority's validity window before it checks
# anything about the runtime store, so on a host whose advertisement window has
# closed it refuses there and stops:
#
#   REFUSE: the authority is not currently supported: admission-window-not-open
#   REFUSE: the Fabric authority is not currently valid; renew and re-prepare
#
# That is the gate working. It is NOT weakened here, the ceremony's gate order is
# not edited, and the fixture does NOT carry a synthesised validity window -- it
# carries the reviewed chain exactly as the source holds it, whether that chain is
# expired or live. It was expired for as long as CADV-000007/CINST-000006 were the
# heads; it is live now that the G11-BC-AM..AS renewal has been written. Either
# way the suite never declares which: whether the authority is live is MEASURED
# from this run, from what BLOCK B actually said.
FABRIC_EXPIRED=0
if grep -q 'admission-window-not-open' "${out}"; then
  FABRIC_EXPIRED=1
fi

if (( status == 0 )); then
  pass "BLOCK B passes against an unmodified fixture"
elif (( FABRIC_EXPIRED == 1 )); then
  pass "BLOCK B refuses the clean fixture ONLY on the expired Fabric authority (admission-window-not-open), which is the gate working rather than failing"
  # And it got that far: everything ahead of the Fabric gate passed.
  if grep -q 'not the reviewed Generation-20' "${out}"; then
    fail "BLOCK B refused before the Fabric gate: the reviewed library is not satisfying its generation gate"
  else
    pass "and it reached the Fabric gate: the generation gate and the observation gate passed"
  fi
else
  fail "BLOCK B refused a clean fixture for something other than the expired authority: $(tail -3 "${out}" | tr '\n' ' ')"
fi
# What BLOCK B reports BEFORE the Fabric gate is reachable today and is asserted
# unconditionally. What it reports AFTER is asserted only when the authority is
# live -- and the moment it is renewed, these become requirements with no edit
# here. Listing them in two groups is how this suite says which coverage it is
# currently providing and which it is not.
AHEAD_OF_FABRIC_GATE=('ok  observation')
for expected in "${AHEAD_OF_FABRIC_GATE[@]}"; do
  if grep -qF "${expected}" "${out}"; then
    pass "BLOCK B reports: ${expected}"
  else
    fail "BLOCK B did not report: ${expected}"
  fi
done
BEHIND_FABRIC_GATE=(
'ok  current authority supported at'
'ok  sequences 3/1, cadm 000002, cmut 000000000010, 7 transitions, no CRES-000002'
'ok  the launch authorisation is the reviewed one, for CIMP-000001'
'ok  the published handoff is the reviewed one, with the reviewed modes'
'ok  CINV-000003 is launch_authorized and awaiting execution'
'ok  occupancy 2 of 2 -- Stage 3 reserves nothing and releases nothing'
'ALL GATES PASSED.'
)
for expected in "${BEHIND_FABRIC_GATE[@]}"; do
  if grep -qF "${expected}" "${out}"; then
    pass "BLOCK B reports: ${expected}"
  elif (( FABRIC_EXPIRED == 1 )); then
    printf 'note     behind the expired Fabric gate, not reachable on this host: %s\n' "${expected}"
  else
    fail "BLOCK B did not report: ${expected}"
  fi
done
# ===========================================================================
# 7. The failure matrix
# ===========================================================================

printf -- '\n--- fail closed, by gate ---\n'

# THE THREE AUTHORITY SABOTAGES MUST SABOTAGE THE CHAIN UNDER TEST.
#
# They used to name CADV-000007, CROUTE-0006 and CSEL-000004 literally, which is
# right while those are the heads and useless the moment they are not: against a
# renewed chain the edit lands on a record BLOCK B no longer consults, so the
# gates pass and the case silently proves nothing. They now derive their target
# from the authority under test, and each ASSERTS that the record it is about to
# break is the one the gates will read.
expire_advertisement() {
  local path="${FIX}/fabric/capability-advertisements/${AUTHORITY_ADVERTISEMENT}.yaml"
  chmod u+w "${path}"
  python3 - "${path}" <<'EXPIRE'
import sys
from datetime import datetime, timedelta
path = sys.argv[1]
body = open(path, encoding="utf-8").read()
# Read the window out of the record and close it, rather than matching a literal
# date that belongs to one generation of the chain.
line = [l for l in body.splitlines() if l.startswith("valid_until:")]
assert len(line) == 1, line
was = line[0].split(": ", 1)[1].strip().strip("'")
closed = (datetime.fromisoformat(was) - timedelta(days=30)).isoformat()
open(path, "w", encoding="utf-8").write(
    body.replace(line[0], f"valid_until: '{closed}'"))
EXPIRE
}
supersede_route() {
  local routes="${FIX}/fabric/capability-routes"
  # A successor to whatever the head is, so the head stops being the head.
  local head="${AUTHORITY_ROUTE}"
  local ordinal="${head##*-}"
  local successor
  successor="$(printf 'CROUTE-%04d' "$(( 10#${ordinal} + 1 ))")"
  chmod u+w "${routes}"
  cp "${routes}/${head}.yaml" "${routes}/${successor}.yaml"
  chmod u+w "${routes}/${successor}.yaml"
  python3 - "${routes}/${successor}.yaml" "${head}" "${successor}" <<'ROUTE'
import re
import sys
path, head, successor = sys.argv[1:4]
body = open(path, encoding="utf-8").read()
assert f"route_id: {head}" in body, f"the copied route does not name {head}"
body = body.replace(f"route_id: {head}", f"route_id: {successor}")
body = re.sub(r"^supersedes: .*$", f"supersedes: {head}", body, count=1,
              flags=re.M)
open(path, "w", encoding="utf-8").write(body)
ROUTE
}
change_selection() {
  local selection="${FIX}/fabric/capability-selections/${AUTHORITY_SELECTION}.yaml"
  chmod u+w "${selection}"
  python3 - "${selection}" "${AUTHORITY_INSTANCE}" <<'SELECT'
import sys
path, instance = sys.argv[1:3]
body = open(path, encoding="utf-8").read()
assert f"selected_instance_id: {instance}" in body, \
    f"the selection does not name {instance}"
# Point it at the predecessor it superseded, which is a real identity and not a
# plausible one: an unparseable record would be a different test.
ordinal = int(instance.split("-")[-1])
other = f"CINST-{ordinal - 1:06d}"
open(path, "w", encoding="utf-8").write(
    body.replace(f"selected_instance_id: {instance}",
                 f"selected_instance_id: {other}"))
SELECT
}
corrupt() { chmod u+w "$1"; printf 'x' >> "$1"; }
# A DIFFERENT lifecycle, not a broken one. Rewriting the state to `created`
# would make `reserved -> created` an edge the released vocabulary does not
# have, and `all_states` would raise -- a crash scoring as a refusal, which is
# the thing a failure matrix must never accept. `abandoned` IS reachable from
# `reserved`, so the chain stays valid, the journal still holds seven records,
# and the gate under test is the one that judges.
revert_lifecycle() {
  local transition="${FIX}/runtime/execution/transitions/CINV-000003.000002"
  chmod u+w "${transition}"
  python3 - "${transition}" <<'HOLD'
import sys
path = sys.argv[1]
body = open(path).read()
assert '"state":"launch_authorized"' in body, "the transition does not record launch_authorized"
open(path, "w").write(body.replace('"state":"launch_authorized"',
                                   '"state":"abandoned"'))
HOLD
}

SABOTAGE=(
"the installed runtime is not Generation 20|sed -i 's#^check_installed tools/capability/cli.py .*#check_installed tools/capability/cli.py 0000000000000000000000000000000000000000000000000000000000000000#' \"\${rendered}\"|not the reviewed Generation-20"
"the advertisement authority has expired|expire_advertisement; REFABRIC=1|the Fabric authority is not currently valid"
"current eligibility is false|change_selection; REFABRIC=1|the Fabric authority is not currently valid"
"the route has moved|supersede_route; REFABRIC=1|has been superseded and is no longer the route head"
"the Fabric baseline moved|corrupt \"\${FIX}/fabric/capability-routes/CROUTE-0006.yaml\"|the Fabric has moved"
"the runtime baseline moved|corrupt \"\${FIX}/runtime/execution/cadm-counter\"|the capability-runtime store has moved"
"CINV-000003 changed|corrupt \"\${FIX}/runtime/capability-invocations/CINV-000003.yaml\"; RERENDER=1|CINV-000003.yaml is"
"the lifecycle is not launch_authorized|revert_lifecycle; RERENDER=1|the lifecycle is"
"the launch-authorisation changed|corrupt \"\${FIX}/runtime/execution/CINV-000003/launch-authorisation\"; RERENDER=1|launch-authorisation is"
"the handoff payload changed|corrupt \"\${FIX}/handoff/CINV-000003/payload\"|payload is"
"the handoff profile changed|corrupt \"\${FIX}/handoff/CINV-000003/profile\"|profile is"
"the handoff output directory is missing|chmod u+w \"\${FIX}/handoff/CINV-000003\"; rmdir \"\${FIX}/handoff/CINV-000003/out\"|the handoff has no output directory"
"the payload changed|corrupt \"\${FIX}/work/third-invoke.json\"|third-invoke.json is"
"the staged tree changed|corrupt \"\${FIX}/runtime/staging/tree-sha256-\${ARTIFACT_DIGEST}/main.py\"; RERENDER=1|main.py is"
"a result already exists|cp \"\${FIX}/runtime/capability-results/CRES-000001.yaml\" \"\${FIX}/runtime/capability-results/CRES-000002.yaml\"; RERENDER=1|CRES-000002 exists"
"the result sequence moved|printf '2\\n' > \"\${FIX}/runtime/sequences/capability-result.seq\"; RERENDER=1|capability-result.seq is not 1"
"the invocation sequence moved|printf '9\\n' > \"\${FIX}/runtime/sequences/capability-invocation.seq\"; RERENDER=1|capability-invocation.seq is not 3"
"a lifecycle transition appeared|cp \"\${FIX}/runtime/execution/transitions/CINV-000003.000002\" \"\${FIX}/runtime/execution/transitions/CINV-000003.000003\"; RERENDER=1|the transition journal does not hold 7 records"
"the execution image is absent|printf 'stage-3-observation\\nno-target-container kyri-CINV-000003\\n' > \"\${FIX}/work/witness\"|does not record the expected execution image"
"a target container exists|printf 'stage-3-observation\\nimage 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190\\n' > \"\${FIX}/work/witness\"|does not record the absence of a kyri-CINV-000003 container"
"the witness is absent|rm -f \"\${FIX}/work/witness\"|run BLOCK A first"
"the witness is stale|touch -d '2 hours ago' \"\${FIX}/work/witness\"|re-run BLOCK A"
)

REACHED=0
MASKED=0
MASKED_CASES=()
CLOSED=0
for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name breakage refusal <<<"${case}"
  build_synthetic_fixture "${FIX}"
  render_gates "${FIX}" "${rendered}"
  RERENDER=0; REFABRIC=0
  eval "${breakage}"
  (( RERENDER == 1 )) && sed -i "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${FIX}/runtime")#" "${rendered}"
  (( REFABRIC == 1 )) && sed -i "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=$(aggregate "${FIX}/fabric")#" "${rendered}"

  out="${WORK}/sabotage.out"; status=0
  ( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?
  if (( status != 0 )); then
    pass "${name}: BLOCK B exits nonzero"
    CLOSED=$(( CLOSED + 1 ))
  else
    fail "${name}: BLOCK B exited 0"
  fi
  if grep -qF -- "${refusal}" "${out}"; then
    pass "${name}: refuses for its own reason (${refusal})"
    REACHED=$(( REACHED + 1 ))
  elif (( FABRIC_EXPIRED == 1 )) && grep -q 'admission-window-not-open' "${out}"; then
    # MASKED, NOT PASSED. BLOCK B checks the Fabric authority's validity before it
    # checks anything about the runtime store, so with the window closed this case
    # cannot reach its own gate. It still fails closed and it still does not crash,
    # both asserted above and below. What is NOT proved today is that this gate
    # refuses for ITS reason, and that is recorded rather than glossed.
    printf 'note     %s: masked by the expired Fabric authority, not yet proved\n' "${name}"
    MASKED=$(( MASKED + 1 ))
    MASKED_CASES+=("${name} -> ${refusal}")
  else
    fail "${name}: refused, but not for its own reason: $(grep -m1 -E 'REFUSE' "${out}" || echo 'no refusal line')"
  fi
  if grep -q 'Traceback (most recent call last)' "${out}"; then
    fail "${name}: something crashed instead of judging its input"
  else
    pass "${name}: no traceback"
  fi
done
# ===========================================================================
# What this run actually proved
# ===========================================================================

printf -- '\n--- the matrix, accounted for ---\n'
total="${#SABOTAGE[@]}"
if (( total == 22 )); then
  pass "all 22 reviewed sabotage cases are present and were run"
else
  fail "the matrix holds ${total} cases, and the reviewed matrix is 22"
fi
if (( CLOSED == total )); then
  pass "every one of the ${total} fails closed: BLOCK B exits nonzero in all of them"
else
  fail "only ${CLOSED} of ${total} failed closed"
fi
if (( REACHED + MASKED == total )); then
  pass "every case is accounted for: ${REACHED} reached their own refusal, ${MASKED} masked"
else
  fail "${total} cases, but ${REACHED} reached and ${MASKED} masked do not account for them"
fi
if (( MASKED == 0 )); then
  pass "all ${total} sabotages reach their intended refusal: the matrix is fully restored"
else
  printf 'note     %d case(s) cannot reach their own gate while the Fabric authority is expired:\n' "${MASKED}"
  for entry in "${MASKED_CASES[@]}"; do
    printf 'note       %s\n' "${entry}"
  done
  printf 'note     Renewing Fabric is a SEPARATE reviewer decision and is not done here.\n'
  printf 'note     These become requirements automatically once it is renewed: nothing in\n'
  printf 'note     this suite needs editing, because the masking is measured, not declared.\n'
  # Masking is tolerated ONLY because the authority is genuinely expired. If it is
  # live and a case still cannot reach its gate, that is a real failure.
  if (( FABRIC_EXPIRED == 0 )); then
    fail "cases were masked while the Fabric authority is live: that is not masking, it is a defect"
  else
    pass "and the masking is attributable: the expired authority refuses ahead of them, measured from this run"
  fi
fi

# ===========================================================================
# Production, after everything
# ===========================================================================

printf -- '\n--- production untouched ---\n'
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the production runtime is byte-identical: ${PRODUCTION_BEFORE}"
else
  fail "THE PRODUCTION RUNTIME CHANGED"
fi
# PRODUCTION, whichever chain the gates were asked about. An override points the
# fixture at another tree; it must never let production move.
if [[ "$(aggregate "${PRODUCTION_FABRIC}")" == "${PRODUCTION_FABRIC_BEFORE}" ]]; then
  pass "the production Fabric is byte-identical: ${PRODUCTION_FABRIC_BEFORE}"
else
  fail "THE PRODUCTION FABRIC CHANGED"
fi
# The spent rehearsal's subject, untouched by this suite: Stage 3's result and
# the closure that followed it are production's, and nothing here reaches them.
if [[ "$(sha256sum "${PRODUCTION}/capability-results/CRES-000002.yaml" 2>/dev/null | cut -d' ' -f1)" \
      == "2d908b866e4f953cc8c53f7f5b367015f9cc75cb1bcbea518261f4997aafaebf" ]]; then
  pass "production's CRES-000002 is byte-identical: this suite executed nothing"
else
  fail "THE PRODUCTION RESULT CHANGED"
fi
if [[ ! -e "${PRODUCTION}/capability-results/CRES-000003.yaml" ]]; then
  pass "no CRES-000003 exists: this suite ran no payload"
else
  fail "A PRODUCTION RESULT WAS WRITTEN"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINV-000003 Stage-3 BLOCK B gate matrix passed.\n'
else
  printf 'CINV-000003 Stage-3 BLOCK B gate matrix FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
