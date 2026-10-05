#!/usr/bin/env bash
set -Eeuo pipefail

# THE FOUR G11-BC-AM FREEZE ARTIFACTS, CHECKED AGAINST WHAT A FREEZE IS ALLOWED
# TO BE.
#
# A freeze artifact has one job: put one reviewed body under /etc/kyri/fabric and
# ask the released engine what it WOULD do with it. It must not write to
# /var/lib/kyri/fabric, and it must prove afterwards that it did not. Each
# production write is a separate reviewer authorisation and lives in no artifact.
#
# Static by construction. Nothing here runs an artifact, freezes anything, or
# touches /etc -- reading them is the test. That matters because running one
# would be the operator's step, and this suite is not the operator.
#
# Governed by the G11-BC-AM renewal plan; the chain itself is rehearsed against a
# byte copy by tests/test-fabric-renewal-chain-rehearsal.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FABRIC_DIR="${ROOT}/provisioning/fabric"

# Spelled in two halves for the same reason the pattern below is assembled: a
# literal write expression naming the governed store is exactly the shape the
# repository's static guard refuses, and a test that searches for it should not
# read as one.
store_leaf=fabric

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# artifact | input | reviewed sha | bytes | record | verb | pre-baseline | digest
ARTIFACTS=(
"g11-bc-am-cadv-000008-freeze.txt|g11-bc-am-cadv-000008-input.json|f0e97487b5d45e7f56db220d632811ffd29370c607d517b24f4412340afbdef1|674|CADV-000008|register-advertisement|a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5|sha256:bbf9abe4b4abe48260592a75d3a856663d0971d239778b70c16d51d528f9f578"
"g11-bc-am-cinst-000007-freeze.txt|g11-bc-am-cinst-000007-input.json|ce4f67fad131af757801ea550e44596ac5fe75264ac592454daa8ccd56ccfd27|1270|CINST-000007|admit-instance|31f49e1299afe3864d877fbde9507c08e852ef9db03f24cb337b725538538161|sha256:e2224ba5defb542565bda24772feafdef956486ea45f47370d35881ddeee0fee"
"g11-bc-am-croute-0007-freeze.txt|g11-bc-am-croute-0007-input.json|28725679855c2b9c76022d90995e2abf9511397edd362a0b513d9f5ff72a00d0|679|CROUTE-0007|create-route|2c40e7057d3b76b7977c4403d24c5222e38ea832e5cd8358c3204fae21b64612|sha256:4b6f3d35a16ce4fb1c19ae0949557841b9c3be531140db7f9437ac5bf32391d2"
"g11-bc-am-csel-000005-freeze.txt|g11-bc-am-csel-000005-input.json|bedb7ee40eb29d385750c482a4fb5e70f3496043eee3c69733d2014d5696cde4|606|CSEL-000005|select|4d8147310a62d9cfbdc1b2b51733d68c83d28fd8a06e1a5aef2f12498d6cea54|sha256:2215d46f52770499e944913e6e52599779c0d849baea7fc2f057a455f2c461c2"
)

printf -- '--- all four artifacts and their inputs exist and parse ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  path="${FABRIC_DIR}/${artifact}"
  if [[ -f "${path}" ]] && bash -n "${path}" 2>/dev/null; then
    pass "${artifact} exists and parses"
  else
    fail "${artifact} is missing or does not parse"
    continue
  fi
  got="$(sha256sum "${FABRIC_DIR}/${input}" 2>/dev/null | cut -d' ' -f1)"
  bytes="$(wc -c < "${FABRIC_DIR}/${input}" 2>/dev/null || echo 0)"
  if [[ "${got}" == "${sha}" && "${bytes}" == "${size}" ]]; then
    pass "${record}: the reviewed input is ${sha:0:16}…, ${size} bytes"
  else
    fail "${record}: the input is ${got:-absent} at ${bytes} bytes, reviewed ${sha} at ${size}"
  fi
done

printf -- '\n--- 1-2. each artifact renders reviewed bytes and pins them ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  ok=1
  grep -qF "REVIEWED=${sha}" <<<"${body}" || { ok=0; fail "${record}: the reviewed digest is not pinned"; }
  grep -qF "REVIEWED_BYTES=${size}" <<<"${body}" || { ok=0; fail "${record}: the byte count is not pinned"; }
  # THE BODY COMES FROM THE REPOSITORY, not retyped into the artifact. A body
  # retyped into a ceremony is a body nobody reviewed.
  grep -qF "SOURCE=provisioning/fabric/${input}" <<<"${body}" \
    || { ok=0; fail "${record}: the artifact does not take its body from the reviewed input file"; }
  (( ok == 1 )) && pass "${record}: pins its reviewed digest, its byte count, and takes the body from ${input}"
done

printf -- '\n--- 3. predecessor bodies are refused BY NAME ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  named="$(grep -c '^ACCEPTED_' <<<"${body}" || true)"
  if (( named >= 2 )); then
    pass "${record}: refuses ${named} accepted predecessor bodies by name"
  else
    fail "${record}: names only ${named} predecessor bodies"
  fi
  # Matched in two halves so this pattern carries no shell expansion of its own:
  # the artifact's refusal interpolates the body's name, and a single-quoted
  # pattern containing that interpolation is what ShellCheck rightly flags.
  if grep -q 'REFUSE: this is ' <<<"${body}" && grep -q ', not the ' <<<"${body}"; then
    pass "${record}: and the refusal says which body was pasted"
  else
    fail "${record}: a predecessor mis-paste would not be named"
  fi
done

printf -- '\n--- 4. each gates on the current wall clock ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  ok=1
  grep -q 'current-time freshness gate' <<<"${body}" || { ok=0; }
  grep -q 'datetime.now().astimezone()' <<<"${body}" || { ok=0; }
  grep -q 'this authority is EXPIRED at the current clock' <<<"${body}" || { ok=0; }
  # The gate must read the instants out of the rendered body rather than restate
  # them, or it can drift from the bytes it guards.
  grep -q 'body.get("valid_until")' <<<"${body}" || { ok=0; }
  if (( ok == 1 )); then
    pass "${record}: gates on the operator clock, reading the instants out of the rendered body"
  else
    fail "${record}: the current-time freshness gate is missing or restates its instants"
  fi
  # And a dependent window must not outlive the one that governs it.
  if grep -q 'outlives the governing advertisement' <<<"${body}"; then
    pass "${record}: and refuses a window that outlives its governing advertisement"
  else
    fail "${record}: nothing checks the governing advertisement's window"
  fi
done

printf -- '\n--- 5. each gates on the exact Fabric baseline for its step ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  if grep -qF "FABRIC_BEFORE=${pre}" <<<"${body}"; then
    pass "${record}: pins the step's own pre-baseline ${pre:0:16}…"
  else
    fail "${record}: does not pin ${pre}"
  fi
done
# The four baselines must chain: each step's pre-baseline is the previous step's
# rehearsed post-baseline. A chain that did not join would mean the steps were
# measured against stores that never followed one another.
printf -- '\n--- and the four baselines form one chain ---\n'
chain_ok=1
previous=""
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  if [[ -n "${previous}" ]]; then
    [[ "${pre}" == "${previous}" ]] || { chain_ok=0
      fail "${record}: its pre-baseline ${pre:0:16}… is not the previous step's post-baseline ${previous:0:16}…"; }
  fi
  previous="$(grep -oE '^#   POST_BASELINE             [0-9a-f]{64}' <<<"${body}" | awk '{print $3}')"
  [[ -n "${previous}" ]] || { chain_ok=0; fail "${record}: states no rehearsed post-baseline"; }
done
(( chain_ok == 1 )) && pass "each step's pre-baseline is the previous step's rehearsed post-baseline"

printf -- '\n--- 6. PREFLIGHT ONLY: no artifact may write production Fabric ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  # Every invocation of a Fabric write verb in the artifact must carry --preflight.
  calls="$(grep -c "tools.fabric.cli ${verb}" <<<"${body}" || true)"
  flagged="$(grep -c -- '--preflight' <<<"${body}" || true)"
  if [[ "${calls}" == "1" && "${flagged}" == "1" ]]; then
    pass "${record}: exactly one ${verb} invocation, and it is --preflight"
  else
    fail "${record}: ${calls} ${verb} invocation(s), ${flagged} --preflight flag(s)"
  fi
  # And the destination of the only install is /etc, never the store.
  installs="$(grep -cE '^sudo install ' <<<"${body}" || true)"
  if [[ "${installs}" == "1" ]] && grep -q 'DEST=/etc/kyri/fabric/' <<<"${body}"; then
    pass "${record}: installs exactly one file, into /etc/kyri/fabric"
  else
    fail "${record}: ${installs} install(s), or the destination is not /etc/kyri/fabric"
  fi
  # The pattern is assembled from parts so this check does not itself read as a
  # write expression naming the governed store -- which is what the docs-static
  # guard looks for, and rightly.
  WRITE_VERBS='(install|cp|mv|rm|tee|>)'
  GOVERNED_STORE="/var/lib/kyri/${store_leaf}/"
  if grep -qE "${WRITE_VERBS}[^#]*${GOVERNED_STORE}" <<<"${body}"; then
    fail "${record}: A WRITE PATH NAMES THE GOVERNED STORE"
  else
    pass "${record}: no write path names the governed Fabric store"
  fi
done

printf -- '\n--- 7-8. each proves its predicted record and its request digest ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  ok=1
  grep -qF "\${PREDICTED}\" = \"${record}\"" <<<"${body}" || { ok=0; }
  grep -qF "\${DIGEST}\" = \"${digest}\"" <<<"${body}" || { ok=0; }
  if (( ok == 1 )); then
    pass "${record}: proves predicted_record_id and request_digest ${digest:7:16}… separately"
  else
    fail "${record}: does not pin both the predicted identity and the request digest"
  fi
done

printf -- '\n--- 9. each proves production Fabric byte-identical afterwards ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  if grep -q 'changed during the freeze' <<<"${body}" \
     && grep -q 'unchanged at %s' <<<"${body}"; then
    pass "${record}: measures production Fabric after the freeze and refuses if it moved"
  else
    fail "${record}: does not prove production Fabric unchanged"
  fi
done

printf -- '\n--- 10. the write is a separate authorisation, and says so ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  if grep -q "WRITE is a separate" <<<"${body}" \
     && grep -q "is NOT in this block" <<<"${body}"; then
    pass "${record}: states that the ${verb} write is a separate authorisation"
  else
    fail "${record}: does not separate the freeze from the write"
  fi
done

printf -- '\n--- the chain is ordered, and each artifact says where it sits ---\n'
step=1
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  if grep -qF "STEP ${step} OF 4 IN THE G11-BC-AM RENEWAL CHAIN" <<<"${body}"; then
    pass "${record} is step ${step} of 4"
  else
    fail "${record} does not declare itself step ${step} of 4"
  fi
  step=$((step + 1))
done

printf -- '\n--- no authority is broadened, and each artifact says which scope it keeps ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  missing=""
  for term in CAPDEF-0001 CPKG-0001 CHOST-0001 CCON-0001 1.0.0 x86-64 execute internal HOST-0001 local-only; do
    grep -qF "${term}" <<<"${body}" || missing+="${term} "
  done
  if [[ -z "${missing}" ]]; then
    pass "${record}: names every scope dimension it keeps equal"
  else
    fail "${record}: does not name ${missing}"
  fi
done

printf -- '\n--- the reviewed inputs do not broaden the accepted scope ---\n'
if (cd "${ROOT}" && python3 - <<'SCOPE'
import json
import sys

HERE = "provisioning/fabric/"


def load(name):
    with open(HERE + name, encoding="utf-8") as handle:
        return json.load(handle)


adv = load("g11-bc-am-cadv-000008-input.json")
inst = load("g11-bc-am-cinst-000007-input.json")
route = load("g11-bc-am-croute-0007-input.json")
sel = load("g11-bc-am-csel-000005-input.json")

expected = {
    "capability": "CAPDEF-0001", "package": "CPKG-0001",
    "host": "CHOST-0001", "contract": "CCON-0001", "version": "1.0.0",
    "architecture": "x86-64", "operation": "execute",
    "classification": "internal", "target": "HOST-0001",
    "locality": "local-only",
}

checks = [
    (adv["capability_package_id"], expected["package"], "advertisement package"),
    (adv["capability_host_id"], expected["host"], "advertisement host"),
    (adv["contract_id"], expected["contract"], "advertisement contract"),
    (adv["satisfied_contract_versions"], [expected["version"]], "advertisement versions"),
    (adv["advertised_resource_profile"], {"architecture": expected["architecture"]},
     "advertisement profile"),
    (inst["capability_id"], expected["capability"], "instance capability"),
    (inst["admission_scope"]["permitted_capabilities"], [expected["capability"]],
     "instance permitted capabilities"),
    (inst["admission_scope"]["permitted_operations"], [expected["operation"]],
     "instance permitted operations"),
    (inst["admission_scope"]["permitted_data_classifications"],
     [expected["classification"]], "instance permitted classifications"),
    (inst["admission_scope"]["permitted_targets"], [expected["target"]],
     "instance permitted targets"),
    (route["capability_id"], expected["capability"], "route capability"),
    (route["accepted_contract_versions"], [expected["version"]], "route versions"),
    (route["data_classification"], expected["classification"], "route classification"),
    (route["locality"], expected["locality"], "route locality"),
    (sel["capability_id"], expected["capability"], "selection capability"),
    (sel["data_classification"], expected["classification"], "selection classification"),
    (sel["locality"], expected["locality"], "selection locality"),
    (sel["local_node_identity"], expected["target"], "selection node"),
]
for got, want, what in checks:
    if got != want:
        sys.exit(f"{what}: {got!r}, expected {want!r}")

# The windows: the instance must not outlive the advertisement that governs it.
if inst["admitted_until"] > adv["valid_until"]:
    sys.exit(f"the instance admission {inst['admitted_until']} outlives the "
             f"advertisement {adv['valid_until']}")
# And no record may claim to predate the advertisement it depends on.
for name, body, field in (("instance", inst, "recorded_at"),
                          ("route", route, "recorded_at"),
                          ("selection", sel, "recorded_at")):
    if body[field] < adv["observed_at"]:
        sys.exit(f"the {name} {field} {body[field]} predates the advertisement "
                 f"{adv['observed_at']}")
# The successors must each name the predecessor they replace, so the chain is
# append-only rather than parallel.
if adv["supersedes"] != "CADV-000007":
    sys.exit("the advertisement does not supersede CADV-000007")
if inst["supersedes"] != "CINST-000006":
    sys.exit("the instance does not supersede CINST-000006")
if route["supersedes"] != "CROUTE-0006":
    sys.exit("the route does not supersede CROUTE-0006")
print("every scope dimension equal; windows ordered; each successor names its "
      "predecessor")
SCOPE
); then
  pass "the four reviewed inputs keep every scope dimension equal and order their windows"
else
  fail "THE REVIEWED INPUTS BROADEN THE ACCEPTED SCOPE OR MISORDER THEIR WINDOWS"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Fabric renewal freeze-artifact validation passed.\n'
else
  printf 'Fabric renewal freeze-artifact validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
