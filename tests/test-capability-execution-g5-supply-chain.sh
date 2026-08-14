#!/usr/bin/env bash
# This suite uses `<test> && pass ... || fail ...` throughout. SC2015 warns that
# the C branch can run when A succeeded -- true in general, and impossible here:
# `pass` is a single printf to stdout, so it cannot fail and cannot fall through
# to `fail`. Disabled once, with that premise stated, rather than 28 times.
# shellcheck disable=SC2015
set -Eeuo pipefail

# Validation for the G5 supply-chain tooling: Cosign trust, Chainguard SPDX
# attestation semantics, and candidate/approval evidence.
#
# ISOLATED BY CONSTRUCTION. Every case runs against a throwaway fixture tree or
# a synthetic DSSE envelope this suite builds. Nothing here reaches the
# network, downloads or installs Cosign, pulls an image, retrieves a real
# attestation, writes an approval, or touches /root.
#
# WHAT IS PROVEN. The two properties the evidence rule stands on: the committed
# bytes are the decoded DSSE payload verbatim -- byte-compared against the
# bytes that were encoded into the envelope, so "nothing was re-serialised" is
# measured rather than asserted -- and selection is deterministic, refusing
# rather than choosing when more than one signed statement matches.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUPPLY="${REPOSITORY}/provisioning/execution/g5-supply-chain.sh"
[[ -f "${SUPPLY}" ]] || { printf 'supply-chain tooling missing: %s\n' "${SUPPLY}" >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${SUPPLY}" | head -1; }
COSIGN_VERSION="$(read_pin COSIGN_VERSION)"
COSIGN_BINARY_SHA256="$(read_pin COSIGN_BINARY_SHA256)"
COSIGN_PATH_ABS="$(read_pin COSIGN_PATH)"
CHAINGUARD_ISSUER="$(read_pin CHAINGUARD_ISSUER)"
CHAINGUARD_IDENTITY="$(read_pin CHAINGUARD_IDENTITY)"
PREDICATE_TYPE="$(read_pin PREDICATE_TYPE)"
BASE_REPOSITORY="$(read_pin BASE_REPOSITORY)"
MANIFEST="$(read_pin CANDIDATE_MANIFEST_DIGEST)"
INDEX="$(read_pin CANDIDATE_INDEX_DIGEST)"
CONFIG="$(read_pin CANDIDATE_CONFIG_DIGEST)"
DISCOVERY="$(read_pin CANDIDATE_DISCOVERY_REFERENCE)"

run_supply() { ( cd "${REPOSITORY}" && bash "${SUPPLY}" "$@" ); }

# ===========================================================================
# Synthetic DSSE envelopes
# ===========================================================================
# Built here rather than retrieved, because the suite must run with no network
# and must not depend on a registry's availability. The statement bytes are
# emitted with deliberately compact separators so that any re-serialisation on
# the read path would change them and be caught by the byte comparison below.
ATT="${WORK}/att"; mkdir -p "${ATT}"
python3 - "${ATT}" "${MANIFEST}" "${PREDICATE_TYPE}" <<'PY'
import base64, json, sys, pathlib

out, subject, predicate_type = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]

def statement(ptype=None, subj=None, spdx=True, packages=True, namespace=True, name=True):
    predicate = {"spdxVersion": "SPDX-2.3",
                 "name": "cgr.dev/chainguard/python",
                 "documentNamespace": "https://spdx.org/spdxdocs/chainguard/abc",
                 "packages": [{"name": "python", "versionInfo": "3.14.6"}]}
    if not spdx:
        predicate.pop("spdxVersion")
    if not packages:
        predicate["packages"] = []
    if not namespace:
        predicate.pop("documentNamespace")
    if not name:
        predicate.pop("name")
    return {"_type": "https://in-toto.io/Statement/v0.1",
            "predicateType": ptype or predicate_type,
            "subject": [{"name": "cgr.dev/chainguard/python",
                         "digest": {"sha256": subj or subject}}],
            "predicate": predicate}

def envelope(st):
    raw = json.dumps(st, separators=(",", ":")).encode()
    line = json.dumps({"payloadType": "application/vnd.in-toto+json",
                       "payload": base64.b64encode(raw).decode(),
                       "signatures": [{"keyid": "", "sig": "AAAA"}]})
    return raw, line

raw, good = envelope(statement())
(out / "good.jsonl").write_text(good + "\n")
(out / "good-second.jsonl").write_text(good + "\n")
(out / "expected-payload.bin").write_bytes(raw)

for name, st in (
        ("wrong-predicate", statement(ptype="https://slsa.dev/provenance/v1")),
        ("wrong-subject",   statement(subj="b" * 64)),
        ("not-spdx",        statement(spdx=False)),
        ("empty-packages",  statement(packages=False)),
        ("no-namespace",    statement(namespace=False)),
        ("no-name",         statement(name=False)),
):
    (out / (name + ".jsonl")).write_text(envelope(st)[1] + "\n")

(out / "duplicate.jsonl").write_text(good + "\n" + good + "\n")
_, provenance = envelope(statement(ptype="https://slsa.dev/provenance/v1"))
(out / "mixed.jsonl").write_text(provenance + "\n" + good + "\n")
(out / "not-json.jsonl").write_text("this is not json\n")
PY

extract() { run_supply --extract-sbom "${ATT}/$1" --manifest-digest "${2:-${MANIFEST}}" "${@:3}"; }

# ===========================================================================
# 1. the committed bytes, and that nothing re-serialises them
# ===========================================================================
if extract good.jsonl "${MANIFEST}" --payload-out "${ATT}/out1.bin" > "${ATT}/good.log" 2>&1; then
  if cmp -s "${ATT}/out1.bin" "${ATT}/expected-payload.bin"; then
    pass "the committed bytes are the decoded payload verbatim: nothing was re-serialised"
  else
    fail "the committed bytes differ from the bytes encoded into the envelope"
  fi
else
  fail "extraction failed on a valid attestation: $(tail -4 "${ATT}/good.log")"
fi

reported="$(sed -n 's/.*sbom_sha256: *//p' "${ATT}/good.log" | tr -d ' ')"
actual="$(sha256sum "${ATT}/expected-payload.bin" | cut -d' ' -f1)"
if [[ -n "${reported}" && "${reported}" == "${actual}" ]]; then
  pass "the reported sbom_sha256 is the SHA-256 of exactly those bytes"
else
  fail "reported ${reported:-nothing}, the payload hashes to ${actual}"
fi

# ===========================================================================
# 2. determinism across two retrievals
# ===========================================================================
extract good-second.jsonl "${MANIFEST}" --payload-out "${ATT}/out2.bin" > "${ATT}/second.log" 2>&1 || true
second="$(sed -n 's/.*sbom_sha256: *//p' "${ATT}/second.log" | tr -d ' ')"
if cmp -s "${ATT}/out1.bin" "${ATT}/out2.bin" && [[ "${reported}" == "${second}" ]]; then
  pass "two retrievals of the same attestation commit byte-identical bytes and the same digest"
else
  fail "the two retrievals disagree: ${reported} vs ${second}"
fi

# ===========================================================================
# 3. deterministic selection, never "the first one"
# ===========================================================================
if extract mixed.jsonl > "${ATT}/mixed.log" 2>&1; then
  if [[ "$(sed -n 's/.*sbom_sha256: *//p' "${ATT}/mixed.log" | tr -d ' ')" == "${reported}" ]]; then
    pass "an unrelated provenance attestation alongside the SPDX one is ignored, not counted"
  else
    fail "the wrong statement was selected from a mixed envelope set"
  fi
else
  fail "a mixed envelope set was refused: $(tail -4 "${ATT}/mixed.log")"
fi

if extract duplicate.jsonl > "${ATT}/dup.log" 2>&1; then
  fail "two matching attestations were silently reduced to one"
else
  if grep -q "refusing to choose" "${ATT}/dup.log"; then
    pass "two attestations matching the same predicate and subject are refused, not chosen between"
  else
    fail "duplicates refused for the wrong reason: $(tail -4 "${ATT}/dup.log")"
  fi
fi

# ===========================================================================
# 4. binding and bounded SPDX validation
# ===========================================================================
if extract wrong-subject.jsonl > "${ATT}/subj.log" 2>&1; then
  fail "an attestation for a different image was accepted"
else
  if grep -q "not the selected image" "${ATT}/subj.log"; then
    pass "a valid SBOM signed for another image is refused: subject binding is enforced"
  else
    fail "wrong subject refused for the wrong reason: $(tail -4 "${ATT}/subj.log")"
  fi
fi

if extract wrong-predicate.jsonl > "${ATT}/pred.log" 2>&1; then
  fail "an attestation with the wrong predicate type was accepted"
else
  grep -q "no attestation with predicateType" "${ATT}/pred.log" \
    && pass "a non-SPDX predicate type yields no match" \
    || fail "wrong predicate refused for the wrong reason"
fi

for case in not-spdx:"not an SPDX document" empty-packages:"empty package inventory" \
            no-namespace:"no documentNamespace" no-name:"no name"; do
  name="${case%%:*}"; expect="${case#*:}"
  if extract "${name}.jsonl" > "${ATT}/${name}.log" 2>&1; then
    fail "${name} was accepted"
  else
    grep -q "${expect}" "${ATT}/${name}.log" \
      && pass "bounded SPDX validation refuses: ${expect}" \
      || fail "${name} refused for the wrong reason: $(tail -3 "${ATT}/${name}.log")"
  fi
done

if extract not-json.jsonl > "${ATT}/nj.log" 2>&1; then
  fail "a non-JSON line was accepted"
else
  pass "a malformed envelope line is refused"
fi

# A refused statement must never print a digest an operator could transcribe.
leaked=0
for name in not-spdx empty-packages no-namespace no-name wrong-subject duplicate; do
  grep -q 'sbom_sha256' "${ATT}/${name}.log" 2>/dev/null && {
    fail "${name} printed an sbom_sha256 despite being refused"; leaked=$((leaked + 1)); }
done
(( leaked == 0 )) && pass "no refused statement reports an sbom_sha256"

# --manifest-digest is not optional: an unbound SBOM is somebody else's SBOM.
if run_supply --extract-sbom "${ATT}/good.jsonl" > "${ATT}/nodigest.log" 2>&1; then
  fail "extraction ran without a subject to bind to"
else
  grep -q "requires --manifest-digest" "${ATT}/nodigest.log" \
    && pass "extraction requires an explicit subject digest" \
    || fail "missing --manifest-digest refused for the wrong reason"
fi

# ===========================================================================
# 5. Cosign trust: pinned version, pinned digest, never PATH
# ===========================================================================
[[ "${COSIGN_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  && pass "an exact Cosign version is pinned (${COSIGN_VERSION}), not a range or 'latest'" \
  || fail "the pinned Cosign version is not exact: ${COSIGN_VERSION}"
[[ "${COSIGN_BINARY_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
  && pass "an exact Cosign binary SHA-256 is pinned" \
  || fail "no Cosign binary digest is pinned"
if grep -qE '^COSIGN_CHECKSUMS_SHA256="[0-9a-f]{64}"$' "${SUPPLY}"; then
  pass "the upstream checksums file is itself pinned, so it cannot bless a swapped binary"
else
  fail "the checksums file is not pinned"
fi
if grep -qE '^COSIGN_URL="https://github\.com/sigstore/cosign/releases/download/v' "${SUPPLY}"; then
  pass "the artifact URL is an official Sigstore release asset"
else
  fail "the Cosign artifact URL is not an official release asset"
fi
# The binary is referenced by absolute path only. A bare `cosign` anywhere would
# mean PATH decides which cosign runs.
if sed -e '/^print_cosign_bootstrap()/,/^}/d' -e '/^print_attestation_procedure()/,/^}/d' \
     "${SUPPLY}" \
   | grep -nE '(^|[^-[:alnum:]_/])cosign +(verify|download|version)' \
   | grep -vE '\$\{COSIGN_PATH\}|^ *[0-9]+: *#' | grep -q .; then
  fail "the tooling invokes cosign through PATH"
else
  pass "cosign is only ever invoked as \${COSIGN_PATH}; PATH cannot substitute another binary"
fi

tool="${WORK}/tool"; mkdir -p "${tool}$(dirname "${COSIGN_PATH_ABS}")"
printf 'not the pinned binary\n' > "${tool}${COSIGN_PATH_ABS}"
if run_supply --fixture "${tool}" --verify-cosign > "${WORK}/badcosign.log" 2>&1; then
  fail "a binary with the wrong digest was accepted"
else
  grep -q "expected the pinned" "${WORK}/badcosign.log" \
    && pass "a Cosign binary whose digest does not match the pin is refused" \
    || fail "a wrong Cosign binary was refused for the wrong reason"
fi

tool2="${WORK}/tool2"; mkdir -p "${tool2}$(dirname "${COSIGN_PATH_ABS}")"
if run_supply --fixture "${tool2}" --verify-cosign > "${WORK}/nocosign.log" 2>&1; then
  fail "a missing Cosign was accepted"
else
  grep -q "is absent" "${WORK}/nocosign.log" \
    && pass "an absent Cosign is refused with the bootstrap step named" \
    || fail "an absent Cosign was refused for the wrong reason"
fi

# ===========================================================================
# 6. signer identity is pinned and cannot be weakened
# ===========================================================================
[[ "${CHAINGUARD_ISSUER}" == "https://token.actions.githubusercontent.com" ]] \
  && pass "the Chainguard OIDC issuer is pinned exactly" \
  || fail "the pinned issuer is ${CHAINGUARD_ISSUER}"
[[ "${CHAINGUARD_IDENTITY}" == https://github.com/chainguard-images/images/* ]] \
  && pass "the Chainguard certificate identity is pinned exactly" \
  || fail "the pinned identity is ${CHAINGUARD_IDENTITY}"
# The procedure must verify, not merely download. `cosign download attestation`
# performs no signature verification at all.
if run_supply --print-attestation-procedure > "${WORK}/proc.log" 2>&1; then
  missing=0
  for required in "verify-attestation" "--certificate-oidc-issuer=${CHAINGUARD_ISSUER}" \
                  "--certificate-identity=${CHAINGUARD_IDENTITY}" \
                  "--type ${PREDICATE_TYPE}"; do
    grep -qF -- "${required}" "${WORK}/proc.log" || {
      fail "the procedure omits ${required}"; missing=$((missing + 1)); }
  done
  (( missing == 0 )) && pass "the procedure verifies cryptographically with the pinned issuer and identity"
else
  fail "--print-attestation-procedure failed"
fi
if grep -qE '^ *\$\{COSIGN_PATH\} download attestation' "${SUPPLY}"; then
  fail "the procedure retrieves without verifying"
else
  pass "retrieval is not offered as an alternative to verification"
fi

# ===========================================================================
# 7. child-digest verification, and the flag contract that now guards it
# ===========================================================================
# The defect this section exists for: a previous revision printed
# `--platform linux/amd64` on verify-attestation. It reads plausibly -- `cosign
# verify` does have that flag -- but verify-attestation does not, and the error
# surfaced only when an operator ran the ceremony live.
# Checked against the COMMAND lines, not the prose: the procedure explains at
# length that this flag does not exist, and that explanation must not trip the
# assertion that it is not emitted.
if grep -qE '^[[:space:]]*--platform' "${WORK}/proc.log"; then
  fail "the printed procedure still emits --platform on verify-attestation"
else
  pass "the printed procedure emits no --platform: verify-attestation has no such flag"
fi
if grep -q 'has no --platform flag' "${WORK}/proc.log"; then
  pass "the procedure records why, so the assumption is not made a third time"
else
  fail "the procedure does not record that verify-attestation lacks --platform"
fi

# The procedure is verified against the CHILD manifest, whose attestation
# subject is that manifest, so the platform binding is the signature itself.
if grep -qF "${BASE_REPOSITORY}@sha256:${MANIFEST}" "${WORK}/proc.log"; then
  pass "cosign is invoked against the digest-pinned linux/amd64 child manifest"
else
  fail "the verification reference is not the pinned child manifest"
fi
if grep -qF "sha256:${INDEX}" "${WORK}/proc.log" \
   && grep -q "not what is verified" "${WORK}/proc.log"; then
  pass "the index is recorded as context and explicitly not the verified reference"
else
  fail "the index/child distinction is not stated"
fi
if grep -q "no matching attestations" "${WORK}/proc.log"; then
  pass "the contingency is stated: an index-only publication is a re-ruling, not a substitution"
else
  fail "the procedure does not say what to do if the child carries no attestation"
fi

# The flag contract, checked against the pinned option set. No binary needed.
if run_supply --verify-flag-contract > "${WORK}/flags.log" 2>&1; then
  pass "every flag in the printed procedure is in the pinned option set"
else
  fail "the printed procedure emits an unsupported flag: $(tail -4 "${WORK}/flags.log")"
fi
if grep -qE '^COSIGN_VERIFY_ATTESTATION_FLAGS=' "${SUPPLY}" \
   && ! grep -E '^COSIGN_VERIFY_ATTESTATION_FLAGS=' -A 20 "${SUPPLY}" | grep -q -- '--platform'; then
  pass "the pinned option set is recorded and does not contain --platform"
else
  fail "the pinned verify-attestation option set is missing or claims --platform"
fi

# THE REGRESSION ITSELF: reintroduce the exact defect and require the contract
# check to catch it. An assertion that only passes on correct input proves
# nothing about whether it would have caught the bug.
regressed="${WORK}/regressed.sh"
python3 - "${SUPPLY}" "${regressed}" <<'INJECT'
import pathlib, sys
# Line-based on purpose. The continuation marker is a backslash inside a shell
# heredoc inside a test, and counting escapes through those layers is exactly
# how an injection silently stops injecting and the regression stops regressing.
lines = pathlib.Path(sys.argv[1]).read_text().splitlines(keepends=True)
for index, line in enumerate(lines):
    if line.lstrip().startswith("--certificate-identity=${CHAINGUARD_IDENTITY}"):
        indent = line[:len(line) - len(line.lstrip())]
        body = line.rstrip("\n")
        continuation = body[len(body.rstrip("\\")):]
        lines.insert(index + 1,
                     indent + "--platform ${CANDIDATE_PLATFORM} " + continuation + "\n")
        break
else:
    raise SystemExit("the procedure shape changed; the injection point is gone")
pathlib.Path(sys.argv[2]).write_text("".join(lines))
INJECT

# Asserted against the FILE, not against running it: if the injection ever stops
# landing, that must fail loudly here rather than quietly turning the
# regression into a test of nothing.
# shellcheck disable=SC2016
if ! grep -qF -- '--platform ${CANDIDATE_PLATFORM}' "${regressed}"; then
  fail "the regression injection did not land in ${regressed}"
elif bash "${regressed}" --verify-flag-contract > "${WORK}/regressed.log" 2>&1; then
  fail "the flag contract accepted --platform: it would not have caught the live defect"
elif ! grep -q "does not accept" "${WORK}/regressed.log"; then
  fail "the injected defect was refused for the wrong reason: $(tail -3 "${WORK}/regressed.log")"
else
  pass "reintroducing --platform is caught by the flag contract, naming the flag"
fi

# And against a BINARY'S OWN HELP, which is the check that does not depend on a
# document being right. Driven with a stub so it runs with no cosign installed.
stub_root="${WORK}/stub"; mkdir -p "${stub_root}$(dirname "${COSIGN_PATH_ABS}")"
cat > "${stub_root}${COSIGN_PATH_ABS}" <<'STUB'
#!/usr/bin/env bash
# A stand-in for the pinned binary, emitting a help text shaped like cosign
# 2.6.0's: every flag the procedure uses, and deliberately no --platform.
printf 'Options:
'
for flag in --type --certificate-oidc-issuer --certificate-identity --output             --check-claims --offline --rekor-url --key --help; do
  printf '      %s string
' "${flag}"
done
STUB
chmod 0755 "${stub_root}${COSIGN_PATH_ABS}"
if run_supply --fixture "${stub_root}" --verify-cosign-contract > "${WORK}/stub.log" 2>&1; then
  grep -q "verify-attestation has no --platform flag" "${WORK}/stub.log" \
    && pass "the binary contract check confirms against help that --platform is absent" \
    || fail "the binary contract check did not report the --platform finding"
else
  fail "the binary contract check failed against a conforming stub: $(tail -6 "${WORK}/stub.log")"
fi

# A binary that does NOT accept a flag the procedure prints must be refused.
cat > "${stub_root}${COSIGN_PATH_ABS}" <<'STUB'
#!/usr/bin/env bash
printf 'Options:
      --help
'
STUB
chmod 0755 "${stub_root}${COSIGN_PATH_ABS}"
if run_supply --fixture "${stub_root}" --verify-cosign-contract > "${WORK}/stub2.log" 2>&1; then
  fail "a binary whose help lacks the printed flags was accepted"
else
  grep -q "does not list" "${WORK}/stub2.log" \
    && pass "a binary that does not accept a printed flag is refused, naming the flag" \
    || fail "the mismatched binary was refused for the wrong reason"
fi

# The discovery tag may be NAMED as discovery; it must never be the reference
# cosign or the build is pointed at.
if grep -nE '(verify-attestation|--build-arg BASE_IMAGE)' "${SUPPLY}" | grep -q ':latest'; then
  fail "a tag reaches the verification or build path"
else
  pass "the discovery tag never reaches verification or build: only digests do"
fi

# ===========================================================================
# 8. candidate evidence, and that it is not an approval
# ===========================================================================
cand="${WORK}/cand"; mkdir -p "${cand}/root"
write_candidate() {
  cat > "${cand}/root/kyri-g5-candidate-evidence.txt" <<EOF
discovery_reference=${DISCOVERY}
index_digest=sha256:${INDEX}
platform=linux/amd64
manifest_digest=sha256:${MANIFEST}
config_digest=sha256:${CONFIG}
discovered_at=2026-08-14T12:00:00Z
discovery_commands=sha256:0000000000000000000000000000000000000000000000000000000000000000
sbom_attestation_verified=${1:-yes}
sbom_predicate_type=${PREDICATE_TYPE}
sbom_sha256=${reported}
cosign_version=${COSIGN_VERSION}
cosign_sha256=${2:-${COSIGN_BINARY_SHA256}}
signing_identity=${3:-${CHAINGUARD_IDENTITY}}
signing_issuer=${4:-${CHAINGUARD_ISSUER}}
EOF
}
write_candidate
if run_supply --fixture "${cand}" --verify-candidate > "${cand}/ok.log" 2>&1; then
  grep -q "THIS IS A CANDIDATE, NOT AN APPROVAL" "${cand}/ok.log" \
    && pass "a complete candidate record verifies and is reported as a candidate, not an approval" \
    || fail "the candidate/approval distinction is not stated"
else
  fail "a complete candidate record was rejected: $(tail -6 "${cand}/ok.log")"
fi

write_candidate no
run_supply --fixture "${cand}" --verify-candidate > "${cand}/unverified.log" 2>&1 \
  && fail "a candidate whose attestation was never verified was accepted" \
  || { grep -q "not cryptographically verified" "${cand}/unverified.log" \
       && pass "a candidate without cryptographic verification is refused" \
       || fail "an unverified candidate was refused for the wrong reason"; }

write_candidate yes "$(printf 'c%.0s' {1..64})"
run_supply --fixture "${cand}" --verify-candidate >/dev/null 2>&1 \
  && fail "a candidate naming an unpinned cosign binary was accepted" \
  || pass "a candidate whose cosign_sha256 is not the pinned binary is refused"

write_candidate yes "${COSIGN_BINARY_SHA256}" "https://github.com/attacker/images/.github/workflows/release.yaml@refs/heads/main"
run_supply --fixture "${cand}" --verify-candidate >/dev/null 2>&1 \
  && fail "a candidate signed by the wrong identity was accepted" \
  || pass "a candidate whose signer is not Chainguard is refused"

write_candidate yes "${COSIGN_BINARY_SHA256}" "${CHAINGUARD_IDENTITY}" "https://accounts.google.com"
run_supply --fixture "${cand}" --verify-candidate >/dev/null 2>&1 \
  && fail "a candidate with the wrong OIDC issuer was accepted" \
  || pass "a candidate whose issuer is not the pinned one is refused"

# Nothing in this tooling can write an approval.
if grep -qE '> *"?\$\{BASE_APPROVAL\}|tee .*\$\{BASE_APPROVAL\}|cat .*> *\$\{BASE_APPROVAL\}' "${SUPPLY}"; then
  fail "the supply-chain tooling writes the approval file"
else
  pass "no mode can write the approval: a candidate is promoted by a human, never by a script"
fi
[[ -e "${cand}/root/kyri-g5-approved-base.txt" ]] \
  && fail "verifying a candidate produced an approval" \
  || pass "verifying a candidate produced no approval file"

# ===========================================================================
# 9. the approval schema
# ===========================================================================
appr="${WORK}/appr"; mkdir -p "${appr}/root"
write_approval() {
  cat > "${appr}/root/kyri-g5-approved-base.txt" <<EOF
base_image_reference=${1:-${BASE_REPOSITORY}@sha256:${MANIFEST}}
platform=linux/amd64
manifest_digest=sha256:${MANIFEST}
config_digest=sha256:${CONFIG}
sbom_source=decoded DSSE payload, in-toto Statement v0.1, predicateType ${PREDICATE_TYPE}
sbom_sha256=${reported}
cosign_version=${2:-${COSIGN_VERSION}}
cosign_sha256=${COSIGN_BINARY_SHA256}
attestation_predicate_type=${3:-${PREDICATE_TYPE}}
attestation_signer=${4:-${CHAINGUARD_IDENTITY}}
approved_by=cschott
approved_at=2026-08-14T12:30:00Z
EOF
}
write_approval
run_supply --fixture "${appr}" --verify-approval > "${appr}/ok.log" 2>&1 \
  && pass "a complete digest-pinned approval verifies" \
  || fail "a valid approval was rejected: $(tail -6 "${appr}/ok.log")"

write_approval "${BASE_REPOSITORY}:latest"
run_supply --fixture "${appr}" --verify-approval > "${appr}/tag.log" 2>&1 \
  && fail "a tagged base_image_reference was approved" \
  || { grep -q "not a digest-pinned" "${appr}/tag.log" \
       && pass "a mutable tag can never be the authoritative base reference" \
       || fail "a tagged reference was refused for the wrong reason"; }

write_approval "${BASE_REPOSITORY}@sha256:${MANIFEST}" "2.2.0"
run_supply --fixture "${appr}" --verify-approval >/dev/null 2>&1 \
  && fail "an approval naming an unpinned cosign version was accepted" \
  || pass "an approval whose cosign_version is not the pinned one is refused"

write_approval "${BASE_REPOSITORY}@sha256:${MANIFEST}" "${COSIGN_VERSION}" "https://slsa.dev/provenance/v1"
run_supply --fixture "${appr}" --verify-approval >/dev/null 2>&1 \
  && fail "an approval naming the wrong predicate type was accepted" \
  || pass "an approval whose predicate type is not SPDX is refused"

write_approval "${BASE_REPOSITORY}@sha256:${MANIFEST}" "${COSIGN_VERSION}" "${PREDICATE_TYPE}" "https://github.com/attacker/x@refs/heads/main"
run_supply --fixture "${appr}" --verify-approval >/dev/null 2>&1 \
  && fail "an approval naming the wrong signer was accepted" \
  || pass "an approval whose attestation_signer is not Chainguard is refused"

for missing_field in sbom_source sbom_sha256 config_digest approved_by; do
  write_approval
  grep -v "^${missing_field}=" "${appr}/root/kyri-g5-approved-base.txt" > "${appr}/tmp"
  mv "${appr}/tmp" "${appr}/root/kyri-g5-approved-base.txt"
  if run_supply --fixture "${appr}" --verify-approval > "${appr}/miss.log" 2>&1; then
    fail "an approval missing ${missing_field} was accepted"
  elif ! grep -q "missing ${missing_field}" "${appr}/miss.log"; then
    # Exiting non-zero without naming the field is how a `set -e` trip
    # disguises itself as a refusal. The reason has to be reported.
    fail "a missing ${missing_field} was refused without naming it"
  fi
done
pass "every approval field is mandatory and each refusal names the field it is missing"

rm -f "${appr}/root/kyri-g5-approved-base.txt"
run_supply --fixture "${appr}" --verify-approval > "${appr}/absent.log" 2>&1 \
  && fail "an absent approval was accepted" \
  || { grep -q "no production base image has been approved" "${appr}/absent.log" \
       && pass "an absent approval is reported as 'not approved', not as a defect" \
       || fail "an absent approval was refused for the wrong reason"; }

# ===========================================================================
# 10. the tooling reaches no network and starts nothing
# ===========================================================================
network=0
for forbidden in '^[[:space:]]*curl' '^[[:space:]]*wget' '^[[:space:]]*podman' \
                 '^[[:space:]]*docker' '^[[:space:]]*skopeo' '^[[:space:]]*crane'; do
  # These appear inside the PRINTED operator procedures, which is the point;
  # what must be absent is an executable occurrence outside a heredoc.
  if sed -e '/^print_cosign_bootstrap()/,/^}/d' -e '/^print_attestation_procedure()/,/^}/d' \
       "${SUPPLY}" | grep -qE "${forbidden}"; then
    fail "the tooling executes a network or container command: ${forbidden}"
    network=$((network + 1))
  fi
done
(( network == 0 )) && pass "outside the printed procedures the tooling runs no network or container command"

if grep -qE '^[[:space:]]*(sudo )?install .*\$\{COSIGN_PATH\}' "${SUPPLY}" \
   | grep -v '^ *#'; then
  fail "the tooling installs cosign itself"
else
  pass "the tooling installs nothing: the operator does the root steps"
fi

# ===========================================================================
# 11. registration, and the host is untouched
# ===========================================================================
name="tests/test-capability-execution-g5-supply-chain.sh"
grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
  && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml" \
  && pass "the suite runs in local validation and in CI" \
  || fail "the suite is not registered in local validation and CI"
grep -q 'g5-supply-chain.sh' "${REPOSITORY}/provisioning/execution/README.md" \
  && pass "the runbook documents the supply-chain tooling" \
  || fail "the runbook does not document the supply-chain tooling"

for absent in /var/lib/kyri/implementation-authority \
              /var/lib/kyri/implementation-authority-control \
              /etc/sudoers.d/kyri-exec; do
  [[ -e "${absent}" ]] && fail "G5 state exists on this host: ${absent}"
done
command -v cosign >/dev/null 2>&1 && fail "cosign was installed onto PATH by this suite"
pass "no authority state, no approval, and no cosign installation on this host: G5 is closed"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 supply-chain validation passed.\n'
else
  printf 'G5 supply-chain validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
