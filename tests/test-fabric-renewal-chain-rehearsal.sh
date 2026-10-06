#!/usr/bin/env bash
set -Eeuo pipefail

# THE G11-BC-AM FABRIC RENEWAL CHAIN, REHEARSED WHOLE, AND THE STAGE-3 MATRIX
# PROVED AGAINST IT.
#
# WHY THIS EXISTS. The restored Stage-3 BLOCK-B matrix has 22 cases, all of which
# fail closed, and on production only 8 reach their own named refusal: the Fabric
# authority expired on 2026-09-23T06:00:00-05:00 and BLOCK B checks the validity
# window before anything about the runtime store, so 14 cases are masked. Those 14
# are not accepted as proved. This suite prepares the renewal that unmasks them,
# proves the chain with the RELEASED write verbs against a byte copy, and then
# runs the real matrix against the result.
#
# NOTHING HERE WRITES TO PRODUCTION. Every released write names an explicit
# `--store-root` inside a disposable scratch tree, which is the G11-BC-AH class
# rule: a subprocess with a named target is safe, a subprocess without one is not.
# Production Fabric and the production runtime are measured before and after.
#
# WHAT IT PROVES, IN ORDER
#
#   1. The current authority fails, and WHY, from the released verifier at the
#      real clock -- not inferred from dates.
#   2. Which record kinds genuinely need a successor, each isolated: renew one,
#      ask the verifier, and read what it then says.
#   3. Every released write accepts, every predicted identifier matches, every
#      sequence advances by exactly one, and each step's baseline is measured.
#   4. With the whole chain in place, current eligibility is clear and the
#      released verifier reports supported.
#   5. The Stage-3 gate matrix, run against that chain, reaches 22 of 22 intended
#      refusals with nothing masked.
#
# THE MATRIX IS NOT WEAKENED TO GET THERE. BLOCK B is not reordered, no
# verification is bypassed, no window is injected into a record, expired
# production is not special-cased, and no intended-refusal requirement becomes a
# generic nonzero-exit assertion. The only reason the 14 unmask is that the chain
# they are asked about is genuinely live.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh disable=SC1091
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /var/lib/kyri/fabric /var/lib/kyri/trust /usr/lib/kyri/python \
                   /data/kyri/capability-runtime \
                   /data/kyri/capability-handoff/CINV-000003 \
                   /data/kyri/work/g11bcn/third-invoke.json

PRODUCTION_FABRIC=/var/lib/kyri/fabric            # prod-path-reference
PRODUCTION_TRUST=/var/lib/kyri/trust              # prod-path-reference
PRODUCTION_RUNTIME=/data/kyri/capability-runtime  # prod-path-reference
INSTALLED=/usr/lib/kyri/python                    # prod-path-reference
INPUTS="${ROOT}/provisioning/fabric"

# The chain, in the only order the engine admits: an instance needs its
# advertisement, a route needs its candidate instance, a selection needs its
# route head.
CHAIN=(
"register-advertisement|g11-bc-am-cadv-000008-input.json|CADV-000008|advertisement|7|8"
"admit-instance|g11-bc-am-cinst-000007-input.json|CINST-000007|instance|6|7"
"create-route|g11-bc-am-croute-0007-input.json|CROUTE-0007|route|6|7"
"select|g11-bc-am-csel-000005-input.json|CSEL-000005|selection|4|5"
)
# The reviewed bytes, pinned. A body that changed would change its request digest
# and its predicted identity, and this suite would be rehearsing something else.
#
# G11-BC-AN RE-PINNED ALL FOUR. The G11-BC-AM window was tied to its own
# preparation instant, 2026-10-05T15:00:00-05:00, and a production observation
# performed later must not carry it. The window is now the one observed at
# G11-BC-AN -- 2026-10-06T06:25:00-05:00, closing 2026-10-13T06:25:00-05:00 --
# so every body changed, and with it every request digest and every chain
# baseline. None of the AM numbers is carried forward: the suite refused the
# stale pins before these were recomputed, which is what the pins are for.
declare -A REVIEWED=(
[g11-bc-am-cadv-000008-input.json]=f683104575018b4b77c15852e08358765a3dc70a6677a22938c4cc54a55fcc61
[g11-bc-am-cinst-000007-input.json]=cc4e8fe6c435ebf6edbcdf9d7d771e754859a61f85968182fea6f8bd2af9ab78
[g11-bc-am-croute-0007-input.json]=6724622395a7b1ec0c74157b4b354ed9ec894c5f8a5ddde782f9a3a4fa129e25
[g11-bc-am-csel-000005-input.json]=2480aac0ccac4e626fbbe592de81d09170d56aaeb11da42f57668c61c61e785b
)

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d -p /data/kyri g11bcam-renewal.XXXXXX)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }
# THE SAME MEASURE A PRODUCTION WRITE WOULD PRODUCE. The aggregate includes
# pathnames, so a scratch tree can never equal production's number without them
# rewritten -- and with them rewritten it equals it exactly, which is why the
# step baselines below are the ones an operator can pin a ceremony to. Proved
# rather than asserted: the untouched copy must reproduce production's aggregate.
production_equivalent() {
  ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum \
      | sed "s|  \./|  ${PRODUCTION_FABRIC}/|" | sha256sum | cut -d' ' -f1 )
}
FABRIC_BEFORE="$(aggregate "${PRODUCTION_FABRIC}")"
RUNTIME_BEFORE="$(aggregate "${PRODUCTION_RUNTIME}")"
TRUST_BEFORE="$(aggregate "${PRODUCTION_TRUST}")"
UID_N="$(id -u)"; GID_N="$(id -g)"

SCRATCH="${WORK}/fabric"
APPROVED="${WORK}/approved"
cp -a "${PRODUCTION_FABRIC}" "${SCRATCH}"
chmod -R u+w "${SCRATCH}"
mkdir -p "${APPROVED}"

printf -- '--- the scratch copy measures as production does ---\n'
if [[ "$(production_equivalent "${SCRATCH}")" == "${FABRIC_BEFORE}" ]]; then
  pass "the untouched copy reproduces production's aggregate ${FABRIC_BEFORE}, so every step baseline below is one a ceremony can pin"
else
  fail "the copy measures $(production_equivalent "${SCRATCH}"), not production's ${FABRIC_BEFORE}"
  exit 1
fi

printf -- '\n--- the reviewed inputs are the bytes this suite rehearses ---\n'
drift=0
for name in "${!REVIEWED[@]}"; do
  got="$(sha256sum "${INPUTS}/${name}" 2>/dev/null | cut -d' ' -f1)"
  if [[ "${got}" == "${REVIEWED[${name}]}" ]]; then
    cp "${INPUTS}/${name}" "${APPROVED}/${name}"
  else
    fail "${name} is ${got:-absent}, not the reviewed ${REVIEWED[${name}]}"
    drift=$((drift + 1))
  fi
done
chmod 0600 "${APPROVED}"/*.json 2>/dev/null || true
if (( drift == 0 )); then
  pass "all ${#REVIEWED[@]} reviewed inputs match their pinned digests"
else
  fail "the reviewed inputs do not match; nothing below would prove the right chain"
  exit 1
fi

# The released verifier, asked about whichever selection and instance it is
# given, at the real wall clock. One implementation, used for every probe.
verdict() {
  ( cd "${INSTALLED}" && python3 - "$1" "$2" "$3" "${PRODUCTION_TRUST}" \
      "${UID_N}" "${GID_N}" <<'PROBE'
import sys
from datetime import datetime

sys.path.insert(0, ".")
from tools.capability.fabric_evidence import verify_selected_evidence

root, selection, instance, trust, uid, gid = sys.argv[1:7]
now = datetime.now().astimezone()
try:
    v = verify_selected_evidence(root, expected_uid=int(uid),
        expected_gid=int(gid), selection_id=selection, instance_id=instance,
        capability_package_id="CPKG-0001", operation="execute",
        trust_root=trust, evaluated_at=now)
except Exception as error:                                   # noqa: BLE001
    print(f"RAISED {type(error).__name__}: {error}")
else:
    print(f"supported={v.supported} reason={v.reason} "
          f"eligibility={list(v.eligibility_reasons)}")
PROBE
  )
}

sequence() { cat "${SCRATCH}/sequences/capability-$1.seq"; }

printf -- '\n--- 1. why the current authority fails, from the released verifier ---\n'
BASELINE_VERDICT="$(verdict "${SCRATCH}" CSEL-000004 CINST-000006)"
printf 'verdict: %s\n' "${BASELINE_VERDICT}"
if [[ "${BASELINE_VERDICT}" == "supported=False reason=admission-window-not-open eligibility=[]" ]]; then
  pass "the released verifier refuses the accepted pair with admission-window-not-open, at the real clock"
else
  fail "the current authority verdict is not the recorded one: ${BASELINE_VERDICT}"
fi

printf -- '\n--- 2. the chain, one released write at a time ---\n'
for entry in "${CHAIN[@]}"; do
  IFS='|' read -r verb input expect kind before after <<<"${entry}"
  pre="$(aggregate "${SCRATCH}")"
  printf '\nstep %-22s PRE_BASELINE=%s\n' "${expect}" "$(production_equivalent "${SCRATCH}")"
  if [[ "$(sequence "${kind}")" == "${before}" ]]; then
    pass "${expect}: the ${kind} sequence is ${before} before the write"
  else
    fail "${expect}: the ${kind} sequence is $(sequence "${kind}"), expected ${before}"
  fi

  extra=()
  case "${verb}" in
    admit-instance|select) extra=(--trust-store-root "${PRODUCTION_TRUST}") ;;
  esac

  # PREFLIGHT FIRST, and it must predict the identity this chain is authorised to
  # create. `would_accept` alone says a body is well formed; it does not say the
  # engine resolved it to the right record.
  preflight="$( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 -m tools.fabric.cli \
    "${verb}" --store-root "${SCRATCH}" --expected-uid "${UID_N}" \
    --expected-gid "${GID_N}" --input-file "${input}" \
    --approved-directory "${APPROVED}" ${extra[@]+"${extra[@]}"} --preflight )" \
    || { fail "${expect}: the released preflight refused"; continue; }
  read -r accept mutated predicted digest <<<"$(printf '%s' "${preflight}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("would_accept"), d.get("mutated"), d.get("predicted_record_id"), d.get("request_digest"))')"
  if [[ "${accept}" == "True" && "${mutated}" == "False" ]]; then
    pass "${expect}: the preflight accepts and mutates nothing"
  else
    fail "${expect}: preflight would_accept=${accept} mutated=${mutated}"
  fi
  if [[ "${predicted}" == "${expect}" ]]; then
    pass "${expect}: the released preflight predicts this identity"
  else
    fail "${expect}: the preflight predicts ${predicted}"
  fi
  if [[ "${digest}" == sha256:* ]]; then
    pass "${expect}: the request digest is ${digest}"
  else
    fail "${expect}: no request digest"
  fi
  if [[ "$(aggregate "${SCRATCH}")" == "${pre}" ]]; then
    pass "${expect}: the preflight left the store byte-identical"
  else
    fail "${expect}: THE PREFLIGHT MUTATED THE STORE"
  fi

  written="$( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 -m tools.fabric.cli \
    "${verb}" --store-root "${SCRATCH}" --expected-uid "${UID_N}" \
    --expected-gid "${GID_N}" --input-file "${input}" \
    --approved-directory "${APPROVED}" ${extra[@]+"${extra[@]}"} )" \
    || { fail "${expect}: the released write refused"; continue; }
  recorded="$(printf '%s' "${written}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("record_id"))')"
  recorded_digest="$(printf '%s' "${written}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("request_digest"))')"
  if [[ "${recorded}" == "${expect}" ]]; then
    pass "${expect}: the released write created it"
  else
    fail "${expect}: the write created ${recorded}"
  fi
  if [[ "${recorded_digest}" == "${digest}" ]]; then
    pass "${expect}: the written request digest is the one the preflight predicted"
  else
    fail "${expect}: the write recorded ${recorded_digest}, the preflight said ${digest}"
  fi
  if [[ "$(sequence "${kind}")" == "${after}" ]]; then
    pass "${expect}: the ${kind} sequence advanced ${before} -> ${after}, by exactly one"
  else
    fail "${expect}: the ${kind} sequence is $(sequence "${kind}"), expected ${after}"
  fi
  printf 'step %-22s POST_BASELINE=%s\n' "${expect}" "$(production_equivalent "${SCRATCH}")"

  # 3. NECESSITY, ISOLATED. After each step, ask the verifier what it now says.
  # These are the proofs that each successor is required, and they come from the
  # engine rather than from reasoning about dates.
  case "${expect}" in
    CADV-000008)
      now_says="$(verdict "${SCRATCH}" CSEL-000004 CINST-000006)"
      if [[ "${now_says}" == *"admission-window-not-open"* ]]; then
        pass "the instance successor is REQUIRED: with the advertisement renewed alone the verifier still refuses admission-window-not-open"
      else
        fail "after the advertisement alone the verifier says: ${now_says}"
      fi ;;
    CINST-000007)
      now_says="$(verdict "${SCRATCH}" CSEL-000004 CINST-000007)"
      if [[ "${now_says}" == *"claimed-instance-not-selected"* ]]; then
        pass "the selection successor is REQUIRED: the accepted selection does not name the renewed instance"
      else
        fail "after the instance the verifier says: ${now_says}"
      fi
      # And the route: a selection taken against the OLD head resolves to no
      # instance at all, which is the released engine saying the route must move.
      stale="$( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 -m tools.fabric.cli select \
        --store-root "${SCRATCH}" --expected-uid "${UID_N}" --expected-gid "${GID_N}" \
        --input-file g11-bc-am-csel-000005-input.json --approved-directory "${APPROVED}" \
        --trust-store-root "${PRODUCTION_TRUST}" --preflight \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("selected_instance_id"))' )"
      if [[ "${stale}" == "None" ]]; then
        pass "the route successor is REQUIRED: against the old route head a selection resolves to NO instance"
      else
        fail "against the old route head a selection resolves ${stale}"
      fi ;;
    CROUTE-0007)
      now_says="$(verdict "${SCRATCH}" CSEL-000004 CINST-000007)"
      if [[ "${now_says}" == *"claimed-instance-not-selected"* ]]; then
        pass "and the selection is still required after the route: the route does not re-point the accepted selection"
      else
        fail "after the route the verifier says: ${now_says}"
      fi ;;
  esac
done

printf -- '\n--- 4. the renewed chain, judged at the real clock ---\n'
printf 'FINAL_BASELINE=%s  (what production would measure after all four writes)\n' \
  "$(production_equivalent "${SCRATCH}")"
FINAL="$(verdict "${SCRATCH}" CSEL-000005 CINST-000007)"
printf 'verdict: %s\n' "${FINAL}"
if [[ "${FINAL}" == "supported=True reason=None eligibility=[]" ]]; then
  pass "the released verifier reports SUPPORTED for CSEL-000005 -> CINST-000007, with no eligibility reasons"
else
  fail "the renewed chain is not supported: ${FINAL}"
fi
# History is intact: the old pair still refuses, because nothing was rewritten.
OLD="$(verdict "${SCRATCH}" CSEL-000004 CINST-000006)"
if [[ "${OLD}" == *"supported=False"* ]]; then
  pass "and the accepted pair still refuses: the renewal is append-only and rewrote nothing"
else
  fail "the old pair changed verdict: ${OLD}"
fi
if PYTHONDONTWRITEBYTECODE=1 python3 -m tools.fabric.cli validate \
     --store-root "${SCRATCH}" --expected-uid "${UID_N}" --expected-gid "${GID_N}" \
     2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d["findings"] == [] else 1)'; then
  pass "the released validation reports no findings against the renewed store"
else
  fail "the released validation reports findings against the renewed store"
fi

printf -- '\n--- 5. no authority was broadened ---\n'
if ( cd "${INSTALLED}" && python3 - "${SCRATCH}" <<'SCOPE'
import sys
import yaml

root = sys.argv[1]


def load(relative):
    with open(f"{root}/{relative}", encoding="utf-8") as handle:
        return yaml.safe_load(handle)


was = load("capability-instances/CINST-000006.yaml")
now = load("capability-instances/CINST-000007.yaml")
for field in ("capability_id", "capability_package_id", "capability_host_id",
              "contract_id", "satisfied_contract_versions",
              "verified_resource_profile", "effective_scope",
              "package_trust_record_id", "host_trust_record_id"):
    if was[field] != now[field]:
        sys.exit(f"{field}: {was[field]!r} -> {now[field]!r}")

old_route = load("capability-routes/CROUTE-0006.yaml")
new_route = load("capability-routes/CROUTE-0007.yaml")
for field in ("capability_id", "contract_id", "accepted_contract_versions",
              "data_classification", "locality"):
    if old_route[field] != new_route[field]:
        sys.exit(f"route {field}: {old_route[field]!r} -> {new_route[field]!r}")

old_sel = load("capability-selections/CSEL-000004.yaml")
new_sel = load("capability-selections/CSEL-000005.yaml")
if old_sel["request_class"] != new_sel["request_class"]:
    sys.exit(f"request_class: {old_sel['request_class']!r} -> {new_sel['request_class']!r}")
if old_sel["local_node_identity"] != new_sel["local_node_identity"]:
    sys.exit("local_node_identity moved")

old_adv = load("capability-advertisements/CADV-000007.yaml")
new_adv = load("capability-advertisements/CADV-000008.yaml")
for field in ("capability_host_id", "capability_package_id", "contract_id",
              "satisfied_contract_versions", "advertised_resource_profile"):
    if old_adv[field] != new_adv[field]:
        sys.exit(f"advertisement {field}: {old_adv[field]!r} -> {new_adv[field]!r}")
print("every scope field is equal across the renewal")
SCOPE
); then
  pass "the renewed chain broadens nothing: capability, package, host, contract, versions, architecture, scope, classification, target, locality and request class are all equal"
else
  fail "THE RENEWED CHAIN BROADENS AUTHORITY"
fi

printf -- '\n--- 6. the Stage-3 gate matrix, against the renewed chain ---\n'
MATRIX="${WORK}/matrix.out"
if KYRI_STAGE3_FABRIC_SOURCE="${SCRATCH}" \
   KYRI_STAGE3_SELECTION=CSEL-000005 \
   KYRI_STAGE3_INSTANCE=CINST-000007 \
   KYRI_STAGE3_ROUTE=CROUTE-0007 \
   KYRI_STAGE3_ADVERTISEMENT=CADV-000008 \
   bash "${SCRIPT_DIR}/test-capability-cinv-000003-stage-3-gate-matrix.sh" \
   > "${MATRIX}" 2>&1; then
  pass "the gate matrix passes against the renewed chain"
else
  fail "the gate matrix failed against the renewed chain"
  grep -E '^FAIL' "${MATRIX}" | head -10 >&2
fi
for required in \
  'all 22 reviewed sabotage cases are present and were run' \
  'every one of the 22 fails closed' \
  'every case is accounted for: 22 reached their own refusal, 0 masked' \
  'all 22 sabotages reach their intended refusal: the matrix is fully restored' \
  'BLOCK B passes against an unmodified fixture'
do
  if grep -qF "${required}" "${MATRIX}"; then
    pass "matrix: ${required}"
  else
    fail "matrix did not report: ${required}"
  fi
done
if grep -q 'masked by the expired Fabric authority' "${MATRIX}"; then
  fail "a case was still masked against the renewed chain"
else
  pass "no case is masked against the renewed chain"
fi
if grep -q 'Traceback (most recent call last)' "${MATRIX}"; then
  fail "something crashed inside the matrix"
else
  pass "no traceback anywhere in the matrix run"
fi

printf -- '\n--- production untouched ---\n'
for pair in "fabric:${PRODUCTION_FABRIC}:${FABRIC_BEFORE}" \
            "runtime:${PRODUCTION_RUNTIME}:${RUNTIME_BEFORE}" \
            "trust:${PRODUCTION_TRUST}:${TRUST_BEFORE}"; do
  IFS=':' read -r label path want <<<"${pair}"
  if [[ "$(aggregate "${path}")" == "${want}" ]]; then
    pass "the production ${label} is byte-identical: ${want}"
  else
    fail "THE PRODUCTION ${label} CHANGED"
  fi
done
# And nothing of the renewal reached production.
for absent in capability-advertisements/CADV-000008.yaml \
              capability-instances/CINST-000007.yaml \
              capability-routes/CROUTE-0007.yaml \
              capability-selections/CSEL-000005.yaml; do
  if [[ ! -e "${PRODUCTION_FABRIC}/${absent}" ]]; then
    pass "production holds no ${absent##*/}: the renewal is prepared, not written"
  else
    fail "A RENEWAL RECORD REACHED PRODUCTION: ${absent}"
  fi
done

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Fabric renewal chain rehearsal passed.\n'
else
  printf 'Fabric renewal chain rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
