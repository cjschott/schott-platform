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
"g11-bc-an-cadv-000008-freeze.txt|g11-bc-am-cadv-000008-input.json|f683104575018b4b77c15852e08358765a3dc70a6677a22938c4cc54a55fcc61|674|CADV-000008|register-advertisement|a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5|sha256:3a35799239002a7ee9ee09b6002fd804bdc436030d7a3cb66d17d089f7be9a28"
"g11-bc-ap-cinst-000007-freeze.txt|g11-bc-ap-cinst-000007-input.json|92c71fb26184cc98a55949805cada709b78bd859b0d2b9765f0e85b8b7b09890|1270|CINST-000007|admit-instance|d11c939a5722beb9e7edb98de9970cfb3c87e93ffb78133cc1ff0b9479ca562c|sha256:06e4cf9676352ebbb950e01702d225cce441b0661e6abc93bdb080953adbd9db"
"g11-bc-ar-croute-0007-freeze.txt|g11-bc-ar-croute-0007-input.json|beb687c26677cad701519b635b7b1ee82bb8721f4da10d0f7d1a9c29b5ca2989|679|CROUTE-0007|create-route|1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb|sha256:db8962e39dcb6efb2b1a91c12ca7b97f8d2ae446e8225f226b4228144cba2e9e"
"g11-bc-as-csel-000005-freeze.txt|g11-bc-as-csel-000005-input.json|4a98b76bf1131788cf19b2728ee5e854f99cc2e3eaabe0580b9799de83838231|606|CSEL-000005|select|758c6c6578abdfccc7d29d2f1b7e9d56cbf4d933636853c884fb599ef70862ba|sha256:dd232d5275cd5a69959772179668f9964f8a455bc748199442e7b2570817d721"
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

printf -- '\n--- the superseded artifacts are marked, not live ---\n'
# THE MARKER IS MATCHED BY SHAPE, NOT BY A LIST OF CHECKPOINT LETTERS. An
# enumeration like G11-BC-A[NOP] has to be edited every time a record is
# re-derived, and the edit is easy to forget -- which is exactly how a live
# artifact and a superseded one become indistinguishable. What matters is that
# the banner names SOME checkpoint and says DO NOT RUN THIS.
#
# THE ADMISSION HAS BEEN RE-DERIVED TWICE, so its supersession chain is two hops
# long: G11-BC-AM chose a cadence slot thirty seconds after the advertisement
# observation, G11-BC-AO used its own preparation instant, and G11-BC-AP uses the
# instant the operator decided and measured. An admission is a DECISION, and
# neither of the first two was one.
for superseded_pair in \
  "g11-bc-am-cadv-000008-freeze.txt:g11-bc-an-cadv-000008-freeze.txt:f0e97487b5d45e7f56db220d632811ffd29370c607d517b24f4412340afbdef1" \
  "g11-bc-am-cinst-000007-freeze.txt:g11-bc-ao-cinst-000007-freeze.txt:cc4e8fe6c435ebf6edbcdf9d7d771e754859a61f85968182fea6f8bd2af9ab78" \
  "g11-bc-ao-cinst-000007-freeze.txt:g11-bc-ap-cinst-000007-freeze.txt:e1bdd53e6e402c8d3f44b158cfc8601e217f701f9c33d08d1fdc622e95b4dd17" \
  "g11-bc-am-croute-0007-freeze.txt:g11-bc-ar-croute-0007-freeze.txt:6724622395a7b1ec0c74157b4b354ed9ec894c5f8a5ddde782f9a3a4fa129e25" \
  "g11-bc-am-csel-000005-freeze.txt:g11-bc-as-csel-000005-freeze.txt:2480aac0ccac4e626fbbe592de81d09170d56aaeb11da42f57668c61c61e785b"
do
  IFS=: read -r was now old_pin <<<"${superseded_pair}"
  path="${FABRIC_DIR}/${was}"
  [[ -f "${path}" ]] || { pass "${was} no longer exists"; continue; }
  if grep -qE 'SUPERSEDED AT G11-BC-[A-Z]{1,2}\. DO NOT RUN THIS\.' "${path}" \
     && grep -qF "${now}" "${path}"; then
    pass "${was} is marked superseded and names ${now}"
  else
    fail "${was} is a second artifact for its record and is not marked superseded"
  fi
  # AND IT KEEPS ITS OLD PINS, deliberately. A superseded artifact carrying
  # current numbers would be indistinguishable from the live one.
  if grep -qF "REVIEWED=${old_pin}" "${path}"; then
    pass "and ${was} still carries its own pins, so it cannot be mistaken for current"
  else
    fail "${was} had its pins updated, which makes it look live"
  fi
  # A SUPERSEDED ARTIFACT MAY NAME ANOTHER SUPERSEDED ONE -- the admission's chain
  # is two hops -- but following the pointers must END at the artifact this suite
  # calls live. Otherwise a reader who starts at the oldest artifact and follows
  # it forward stops somewhere that is also marked DO NOT RUN.
  hop="${now}"
  for _ in 1 2 3 4; do
    grep -qE 'SUPERSEDED AT G11-BC-[A-Z]{1,2}\. DO NOT RUN THIS\.' "${FABRIC_DIR}/${hop}" 2>/dev/null \
      || break
    hop="$(grep -oE 'g11-bc-a[a-z]-c[a-z]+-[0-9]+-freeze\.txt' "${FABRIC_DIR}/${hop}" | head -1)"
  done
  live=0
  for entry in "${ARTIFACTS[@]}"; do
    [[ "${entry%%|*}" == "${hop}" ]] && live=1
  done
  if (( live == 1 )); then
    pass "and following ${was} forward reaches the live ${hop}"
  else
    fail "following ${was} forward reaches ${hop:-nothing}, which this suite does not call live"
  fi
done

# A SUPERSEDED BODY OF THE SAME LENGTH IS A MIS-PASTE A BYTE COUNT CANNOT CATCH.
# The AO and AP admission bodies both render to 1270 bytes, because the two
# instants are the same width and so are the two request ids. The live artifact
# must therefore refuse the superseded body by DIGEST.
printf -- '\n--- a superseded body of equal length is refused by digest ---\n'
for stale_pair in \
  "CINST-000007:g11-bc-ao-cinst-000007-input.json" \
  "CROUTE-0007:g11-bc-am-croute-0007-input.json" \
  "CSEL-000005:g11-bc-am-csel-000005-input.json"
do
  IFS=: read -r stale_record superseded_input <<<"${stale_pair}"
  stale="${FABRIC_DIR}/${superseded_input}"
  [[ -f "${stale}" ]] || { pass "${superseded_input} no longer exists"; continue; }
  stale_sha="$(sha256sum "${stale}" | cut -d' ' -f1)"
  stale_bytes="$(wc -c < "${stale}")"
  for entry in "${ARTIFACTS[@]}"; do
    IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
    [[ "${record}" == "${stale_record}" ]] || continue
    if [[ "${stale_bytes}" != "${size}" ]]; then
      pass "${superseded_input} is ${stale_bytes} bytes against the live ${size}, so a length tells them apart"
    elif grep -qF "${stale_sha}" "${FABRIC_DIR}/${artifact}"; then
      pass "${superseded_input} is the same ${size} bytes as the live body and ${artifact} refuses it by digest"
    else
      fail "${superseded_input} is the same ${size} bytes as the live body and ${artifact} does not refuse it by digest"
    fi
  done
done

printf -- '\n--- (the advertisement artifact, in detail) ---\n'
SUPERSEDED="${FABRIC_DIR}/g11-bc-am-cadv-000008-freeze.txt"
if [[ -f "${SUPERSEDED}" ]]; then
  if grep -q 'SUPERSEDED AT G11-BC-AN. DO NOT RUN THIS.' "${SUPERSEDED}" \
     && grep -q 'g11-bc-an-cadv-000008-freeze.txt' "${SUPERSEDED}"; then
    pass "the G11-BC-AM advertisement artifact is marked superseded and names its replacement"
  else
    fail "a second artifact for CADV-000008 exists and is not marked superseded"
  fi
  # AND ITS PINS ARE THE OLD ONES, deliberately. A superseded artifact carrying
  # current numbers would be indistinguishable from the live one.
  if grep -q 'REVIEWED=f0e97487b5d45e7f56db220d632811ffd29370c607d517b24f4412340afbdef1' "${SUPERSEDED}"; then
    pass "and it still carries its own G11-BC-AM pins, so it cannot be mistaken for current"
  else
    fail "the superseded artifact's pins were updated, which makes it look live"
  fi
else
  pass "no superseded advertisement artifact remains"
fi

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
  grep -q 'datetime.now().astimezone()' <<<"${body}" || { ok=0; }
  # A closed window must be NAMED as closed at the current clock, in whatever
  # words -- an advertisement expires, an admission closes, and binding to one
  # phrasing would make this a spelling test.
  grep -qiE '(EXPIRED|CLOSED) at the current clock' <<<"${body}" || { ok=0; }
  # AND THE GATE MUST READ ITS BOUNDS OUT OF THE RECORDS, NOT RESTATE THEM. Which
  # record carries the bound depends on the kind, and conflating the two is how
  # this check came to demand a window of a record that has none (G11-BC-AR).
  #
  #   an advertisement and an admission CARRY a window, in their own body;
  #   a route and a selection carry a DECISION INSTANT and borrow their window
  #   from the records they depend on.
  #
  # So a route artifact that read `admitted_until` out of its own body would be
  # reading a field that does not exist there.
  case "${record}" in
    CADV-*|CINST-*)
      grep -qE 'body\.get\("(valid_until|admitted_until)"\)' <<<"${body}" || { ok=0; }
      bound="its own window, out of the rendered body" ;;
    CROUTE-*|CSEL-*)
      grep -qE 'body\.get\("recorded_at"\)|body\[.recorded_at.\]' <<<"${body}" || { ok=0; }
      # and the governing bound must come out of a governing RECORD file
      grep -qE 'admitted_until|valid_until' <<<"${body}" || { ok=0; }
      grep -qE 'capability-(instances|advertisements)/C(INST|ADV)-[0-9]+\.yaml' <<<"${body}" || { ok=0; }
      bound="its decision instant from the body and its window from the governing records" ;;
  esac
  if (( ok == 1 )); then
    pass "${record}: gates on the operator clock, reading ${bound}"
  else
    fail "${record}: the clock gate is missing, or restates bounds instead of reading ${bound}"
  fi
  # A DEPENDENT record must be bounded by the authority that governs it. What
  # "bounded" means differs by kind: a window must not OUTLIVE the advertisement;
  # a decision instant must not fall AT OR AFTER it expires.
  case "${record}" in
    CADV-*)
      pass "${record}: it IS the governing advertisement, so no containment check applies to it" ;;
    CINST-*)
      if grep -qiE 'outliv(es|ing) the (governing )?advertisement' <<<"${body}"; then
        pass "${record}: and refuses a window that outlives its governing advertisement"
      else
        fail "${record}: nothing checks that its window is contained by the advertisement's"
      fi ;;
    *)
      if grep -qiE 'at or after the (governing )?advertisement expires|outliv(es|ing) the (governing )?advertisement' <<<"${body}"; then
        pass "${record}: and refuses a decision instant at or after the advertisement expires"
      else
        fail "${record}: nothing bounds its decision instant by the governing advertisement"
      fi ;;
  esac
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
# THE CHAIN NOW JOINS END TO END. G11-BC-AS prepared the selection, so all four
# steps carry pins derived from bodies the operator actually decided, and each
# step's pre-baseline is the previous step's rehearsed post-baseline. Their pins are STALE BY
# CONSTRUCTION and are not asserted here -- they are re-prepared at their own
# checkpoint, with their own rehearsal. Asserting a joined chain across an
# unprepared step would be asserting a number nobody has measured.
printf -- '\n--- the prepared steps chain, and the unprepared ones say they do not ---\n'
PREPARED=(CADV-000008 CINST-000007 CROUTE-0007 CSEL-000005)
chain_ok=1
previous=""
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  prepared=0
  for name in "${PREPARED[@]}"; do [[ "${record}" == "${name}" ]] && prepared=1; done
  if (( prepared == 0 )); then
    if grep -qE 'STALE|SUPERSEDED|re-prepared' <<<"${body}"; then
      pass "${record}: not prepared at this checkpoint, and the artifact says its pins are stale"
    else
      fail "${record}: carries pins derived from a re-derived body and does not say so"
    fi
    continue
  fi
  if [[ -n "${previous}" ]]; then
    [[ "${pre}" == "${previous}" ]] || { chain_ok=0
      fail "${record}: its pre-baseline ${pre:0:16}… is not the previous step's post-baseline ${previous:0:16}…"; }
  fi
  previous="$(grep -oE '^#   POST_BASELINE +[0-9a-f]{64}' <<<"${body}" | awk '{print $3}')"
  [[ -n "${previous}" ]] || { chain_ok=0; fail "${record}: states no rehearsed post-baseline"; }
done
(( chain_ok == 1 )) && pass "every prepared step's pre-baseline is the previous prepared step's rehearsed post-baseline"

printf -- '\n--- 6. PREFLIGHT ONLY: no artifact may write production Fabric ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  # Every invocation of a Fabric write verb in the artifact must carry --preflight.
  # Each invocation is classified by the ROOT it names. Against production it
  # must carry --preflight; against a scratch root it is the eligibility
  # rehearsal the reviewer asked for, which has to write to mean anything.
  if python3 - "${FABRIC_DIR}/${artifact}" "${verb}" <<'CLASSIFY'
import re
import sys

path, verb = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
production = scratch = 0
unflagged = []
for match in re.finditer(rf"tools\.fabric\.cli\s+{re.escape(verb)}\b", text):
    # The invocation and its continuation lines, up to the first line that does
    # not end in a backslash.
    tail = text[match.end():]
    lines, consumed = [], 0
    for line in tail.splitlines():
        lines.append(line)
        consumed += 1
        if not line.rstrip().endswith("\\"):
            break
    window = " ".join(lines)
    if "store-root /var/lib/kyri/fabric" in window:
        production += 1
        if "--preflight" not in window:
            unflagged.append(window.strip()[:70])
    else:
        scratch += 1
if production < 1:
    sys.exit(f"no production {verb} invocation at all")
if unflagged:
    sys.exit(f"a production {verb} invocation carries no --preflight: {unflagged}")
print(f"{production} production invocation(s), every one --preflight; "
      f"{scratch} against a scratch root")
CLASSIFY
  then
    pass "${record}: every production ${verb} invocation is a --preflight"
  else
    fail "${record}: a production ${verb} invocation is not a preflight"
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
  if grep -qF "\${DIGEST}\" = \"${digest}\"" <<<"${body}"; then
    :
  elif grep -qF "REQUEST_DIGEST=${digest}" <<<"${body}" \
       && grep -qF 'DIGEST}" = "' <<<"${body}" \
       && grep -qF 'REQUEST_DIGEST}"' <<<"${body}"; then
    :
  else
    ok=0
  fi
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
  if grep -qE 'changed during the (freeze|preflight)|moved during the freeze' <<<"${body}" \
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
  flattened="$(tr '\n' ' ' <<<"${body}" | sed 's/#//g' | tr -s ' ')"
  if grep -qi "write is a separate" <<<"${flattened}" \
     && grep -qi "is not in this block" <<<"${flattened}"; then
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
  if grep -qiE "STEP ${step} OF 4" <<<"${body}"; then
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
  # EVERY KIND NAMES WHAT IT CARRIES; NO KIND IS ASKED TO PIN WHAT IT DOES NOT.
  #
  # An admission carries the package, the host, the verified architecture and the
  # permitted operation. A ROUTE carries none of those -- it carries a
  # capability, a contract, accepted versions, a classification, a locality and
  # its candidates. Demanding a route artifact pin CPKG-0001 or x86-64 was
  # demanding prose about authority it does not hold (G11-BC-AR), which is the
  # same mistake as demanding an admission pin locality.
  #
  # So each kind names its own dimensions, and SAYS where the others live. Saying
  # so is the point: an artifact that claimed authority over a field it does not
  # touch would be claiming more than it has.
  for term in CAPDEF-0001 CCON-0001 1.0.0 internal; do
    grep -qF "${term}" <<<"${body}" || missing+="${term} "
  done
  case "${record}" in
    CROUTE-*|CSEL-*)
      grep -qF local-only <<<"${body}" || missing+="local-only "
      for term in CPKG-0001 CHOST-0001 x86-64 execute; do
        grep -qF "${term}" <<<"${body}" \
          || missing+="a statement of where ${term} is carried " ;
      done ;;
    *)
      for term in CPKG-0001 CHOST-0001 x86-64 execute HOST-0001; do
        grep -qF "${term}" <<<"${body}" || missing+="${term} "
      done
      grep -qF local-only <<<"${body}" \
        || missing+="a statement of where local-only is carried " ;;
  esac
  if [[ -z "${missing}" ]]; then
    pass "${record}: names every scope dimension it keeps equal"
  else
    fail "${record}: does not name ${missing}"
  fi
done

printf -- '\n--- every artifact carries the G11-BC-AN window, and none the G11-BC-AM one ---\n'
for entry in "${ARTIFACTS[@]}"; do
  IFS='|' read -r artifact input sha size record verb pre digest <<<"${entry}"
  body="$(cat "${FABRIC_DIR}/${artifact}")"
  # The G11-BC-AM instants may appear only in prose explaining why they were
  # replaced -- never as a pinned value on an assignment.
  if grep -qE "^[A-Z_]+=.*2026-10-05T15:" <<<"${body}"; then
    fail "${record}: a G11-BC-AM instant survives as a pinned value"
  else
    pass "${record}: carries no G11-BC-AM instant as a pinned value"
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
inst = load("g11-bc-ap-cinst-000007-input.json")
route = load("g11-bc-ar-croute-0007-input.json")
sel = load("g11-bc-as-csel-000005-input.json")

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
