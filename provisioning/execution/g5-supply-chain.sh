#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G5 supply-chain tooling: Cosign trust, Chainguard SPDX attestation
# retrieval, and candidate/approval evidence.
#
# THIS SCRIPT MUTATES NOTHING AND REACHES NO NETWORK, IN ANY MODE. It downloads
# no binary, installs nothing, pulls no image, retrieves no attestation, and
# writes no approval. Network-touching and root-installing steps are PRINTED
# for an operator to run and review; the verification of their results is what
# happens here.
#
# =============================================================================
# WHY THERE IS NO LOCAL SBOM GENERATOR
# =============================================================================
# The evidence rule (design §27, runbook) is that `sbom_sha256` is the SHA-256
# of exact named bytes, committed verbatim -- no normaliser, no
# re-serialisation, no canonicaliser invented to make a hash stable. A local
# generator would put its own timestamps and document identifiers under that
# commitment.
#
# Chainguard already publishes a SIGNED SPDX attestation for every public
# image. Committing those bytes means the commitment is over something a third
# party signed, retrieved rather than generated, and immutable because the
# attestation layer is content-addressed in the registry. That is strictly
# stronger than anything a generator on this host could produce.
#
# =============================================================================
# WHICH BYTES ARE COMMITTED, AND WHY THOSE
# =============================================================================
# `cosign download attestation` emits one DSSE envelope per line:
#
#   {"payloadType":"application/vnd.in-toto+json","payload":"<base64>",
#    "signatures":[...]}
#
# Three candidates were considered:
#
#   A. the whole DSSE envelope -- rejected. It is mostly signature material,
#      and re-signing the same SBOM would change the committed bytes.
#   B. the base64-decoded payload: the in-toto Statement, carrying the SPDX
#      document as its predicate.  **CHOSEN.**
#   C. the SPDX predicate alone -- rejected. Extracting a sub-object out of the
#      statement means re-emitting JSON, which is exactly the re-serialisation
#      the rule forbids.
#
# B is the only one that is both byte-exact and meaningful. The DSSE signature
# covers PAE("application/vnd.in-toto+json", payload), so these are precisely
# the bytes Chainguard signed -- and base64 decoding is a byte-exact transform,
# not a rendering. The statement is parsed to *inspect* its predicate type and
# subject, and the parse result is then discarded: the bytes written out are
# the decoded payload itself, never a re-encoding of it.
#
# `sbom_source` therefore names: the decoded DSSE payload, in-toto Statement
# v0.1, predicateType https://spdx.dev/Document.
#
# Usage (all read-only):
#   --print-cosign-bootstrap        the operator's download/verify/install steps
#   --verify-cosign                 the installed binary is the pinned one
#   --print-attestation-procedure   retrieval, verification, byte extraction
#   --verify-flag-contract          the printed flags are in the pinned option
#                                   set (no binary needed; runs in CI)
#   --verify-cosign-contract        the printed flags are accepted by the
#                                   INSTALLED binary's own help
#   --extract-sbom FILE             deterministic selection + committed digest
#   --verify-candidate              the candidate evidence record
#   --verify-approval               the production approval file
#
#   --manifest-digest HEX  the platform manifest the attestation must bind to
#                          (required by --extract-sbom)
#   --payload-out FILE     write the exact committed bytes, so that "nothing was
#                          re-serialised" is checkable rather than asserted
#   --fixture DIR          test-only: operate on a fixture tree

REPOSITORY="/opt/schott-platform"

# --- Cosign, pinned ---------------------------------------------------------
#
# 2.6.0 rather than "latest". Chainguard documents that platform selection on
# attestations needs 2.2.1 or newer; this is a specific reviewed release above
# that floor, and the floor is recorded so a future bump has a reason to clear.
COSIGN_VERSION="2.6.0"
COSIGN_MINIMUM="2.2.1"
COSIGN_URL="https://github.com/sigstore/cosign/releases/download/v2.6.0/cosign-linux-amd64"
COSIGN_CHECKSUMS_URL="https://github.com/sigstore/cosign/releases/download/v2.6.0/cosign_checksums.txt"
# From the upstream release's own cosign_checksums.txt, read from the release
# asset rather than from a summary of it.
COSIGN_BINARY_SHA256="ea5c65f99425d6cfbb5c4b5de5dac035f14d09131c1a0ea7c7fc32eab39364f9"
# The checksums file itself, so a swapped checksums file is caught before it is
# ever used to bless a binary.
COSIGN_CHECKSUMS_SHA256="423c15cb363bf4fd62bedc7a59d4130d84286e4532b99a0f95bfd4b0195b01c8"

# The complete option set of `cosign verify-attestation` at the pinned version,
# from that release's own reference documentation. It is here so the printed
# procedure can be checked against it mechanically.
#
# WHY THIS EXISTS: a previous revision printed `--platform linux/amd64` on this
# subcommand. It reads plausibly -- `cosign verify` does have --platform, and
# Chainguard documents a cosign floor for "platform attestation selection" --
# but verify-attestation does not, and the error surfaced only when an operator
# ran it live. A CLI contract asserted from prose is not a verified contract.
COSIGN_VERIFY_ATTESTATION_FLAGS="\
--allow-http-registry --allow-insecure-registry --attachment-tag-prefix \
--ca-intermediates --ca-roots --certificate --certificate-chain \
--certificate-github-workflow-name --certificate-github-workflow-ref \
--certificate-github-workflow-repository --certificate-github-workflow-sha \
--certificate-github-workflow-trigger --certificate-identity \
--certificate-identity-regexp --certificate-oidc-issuer \
--certificate-oidc-issuer-regexp --check-claims --experimental-oci11 --help \
--insecure-ignore-sct --insecure-ignore-tlog --k8s-keychain --key \
--local-image --max-workers --new-bundle-format --offline --output --policy \
--private-infrastructure --registry-cacert --registry-client-cert \
--registry-client-key --registry-password --registry-server-name \
--registry-token --registry-username --rekor-url --sct \
--signature-digest-algorithm --sk --slot --timestamp-certificate-chain \
--trusted-root --type --use-signed-timestamps"

# Root-owned operator tooling. Never PATH: PATH is coordinator-influenced, and
# "whatever cosign resolves to today" is not an identity.
TOOLING_ROOT="/root/kyri-g5-tooling"
COSIGN_PATH="/root/kyri-g5-tooling/cosign-2.6.0"

# --- Chainguard public signing identity, pinned -----------------------------
#
# Confirmed against two independent Chainguard provenance pages (python and
# static) plus Chainguard Academy; the values are per-registry, not per-image.
CHAINGUARD_ISSUER="https://token.actions.githubusercontent.com"
CHAINGUARD_IDENTITY="https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main"
PREDICATE_TYPE="https://spdx.dev/Document"
PAYLOAD_TYPE="application/vnd.in-toto+json"
BASE_REPOSITORY="cgr.dev/chainguard/python"

# --- the DISCOVERED CANDIDATE — reviewed by nobody yet ----------------------
#
# Recorded so verification can bind to it. Recording a candidate is not
# approving one: nothing here writes an approval, and --verify-approval reads a
# file this script cannot create.
CANDIDATE_INDEX_DIGEST="fe9ad068be9f8b9417ffebc049c852c43c03897c364146b9823944cdd7e70b94"
CANDIDATE_MANIFEST_DIGEST="84e1f28d16a545d7fdeb0a292005e1d6147059deee4aac8611526888d353f5ca"
CANDIDATE_CONFIG_DIGEST="a33976e6c3275bab76c89686561e5b8cacf6c6f40b70ec67a3d01c8cf8c2bdd6"
CANDIDATE_PLATFORM="linux/amd64"
CANDIDATE_DISCOVERY_REFERENCE="cgr.dev/chainguard/python:latest"

CANDIDATE_EVIDENCE="/root/kyri-g5-candidate-evidence.txt"
BASE_APPROVAL="/root/kyri-g5-approved-base.txt"

MODE=""
FIXTURE=""
MANIFEST_DIGEST=""
ENVELOPE_FILE=""
PAYLOAD_OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-cosign-bootstrap|--verify-cosign|--print-attestation-procedure|\
--verify-flag-contract|--verify-cosign-contract|--verify-candidate|--verify-approval)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --extract-sbom)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; ENVELOPE_FILE="${2:-}"; shift 2
      [[ -n "${ENVELOPE_FILE}" ]] || { printf 'ERROR --extract-sbom needs a file\n' >&2; exit 2; }
      ;;
    --payload-out)
      PAYLOAD_OUT="${2:-}"; shift 2
      [[ -n "${PAYLOAD_OUT}" ]] || { printf 'ERROR --payload-out needs a file\n' >&2; exit 2; }
      ;;
    --manifest-digest)
      MANIFEST_DIGEST="${2:-}"; shift 2
      [[ "${MANIFEST_DIGEST}" =~ ^[0-9a-f]{64}$ ]] \
        || { printf 'ERROR --manifest-digest needs a bare 64-hex digest\n' >&2; exit 2; }
      ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
      ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---verify-cosign}"

if [[ -n "${FIXTURE}" ]]; then
  TOOLING_ROOT="${FIXTURE}${TOOLING_ROOT}"
  COSIGN_PATH="${FIXTURE}${COSIGN_PATH}"
  CANDIDATE_EVIDENCE="${FIXTURE}${CANDIDATE_EVIDENCE}"
  BASE_APPROVAL="${FIXTURE}${BASE_APPROVAL}"
fi

FAILURES=0
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# An absent field must be REPORTED, not fatal. Without the `|| true` the failing
# grep propagates through pipefail into the command substitution, `set -e` exits
# on the assignment, and the operator gets a non-zero status with no reason --
# which is the one outcome worse than a wrong answer.
field_of() { grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# --- Cosign trust -----------------------------------------------------------
print_cosign_bootstrap() {
  cat <<BOOT
Cosign is operator tooling. It is downloaded, verified, and installed by an
operator into root-owned space, once, and then referred to by absolute path.

  # 1. As the coordinator, or anywhere unprivileged. No privilege is involved
  #    in fetching bytes; only in trusting them.
  curl -fsSL -o /tmp/cosign-linux-amd64 \\
      ${COSIGN_URL}
  curl -fsSL -o /tmp/cosign_checksums.txt \\
      ${COSIGN_CHECKSUMS_URL}

  # 2. Verify the checksums FILE before letting it bless anything. A swapped
  #    checksums file would otherwise validate a swapped binary quite happily.
  sha256sum /tmp/cosign_checksums.txt
  # must equal ${COSIGN_CHECKSUMS_SHA256}

  # 3. Verify the binary against its own published line, and against the value
  #    pinned in this script. Both, because they came from the same publisher
  #    and agreeing with yourself is not verification.
  grep ' cosign-linux-amd64\$' /tmp/cosign_checksums.txt
  sha256sum /tmp/cosign-linux-amd64
  # must equal ${COSIGN_BINARY_SHA256}

  # 4. Only now, as root, into root-owned space. Never onto PATH.
  sudo install -d -m 0700 -o root -g root ${TOOLING_ROOT}
  sudo install -m 0500 -o root -g root /tmp/cosign-linux-amd64 ${COSIGN_PATH}
  rm -f /tmp/cosign-linux-amd64 /tmp/cosign_checksums.txt

  # 5. Confirm what was installed.
  sudo bash ${REPOSITORY}/provisioning/execution/g5-supply-chain.sh --verify-cosign

Pinned: cosign ${COSIGN_VERSION} (Chainguard documents ${COSIGN_MINIMUM}+ for
attestation platform selection). The binary is referenced only as
${COSIGN_PATH}; nothing in this ceremony resolves the name "cosign" through
PATH, so a cosign earlier in an operator's PATH cannot substitute itself.
BOOT
}

verify_cosign() {
  [[ -e "${COSIGN_PATH}" ]] \
    || halt "${COSIGN_PATH} is absent; run --print-cosign-bootstrap and complete the operator steps"
  [[ -f "${COSIGN_PATH}" && ! -L "${COSIGN_PATH}" ]] \
    || bad "${COSIGN_PATH} is not a regular file"
  local observed
  observed="$(digest_of "${COSIGN_PATH}")"
  [[ "${observed}" == "${COSIGN_BINARY_SHA256}" ]] \
    || bad "${COSIGN_PATH} is ${observed:-unreadable}, expected the pinned ${COSIGN_BINARY_SHA256}"
  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(stat -c '%U:%G %a' "${COSIGN_PATH}")" == "root:root 500" ]] \
      || bad "${COSIGN_PATH} is not root:root 0500"
    [[ "$(stat -c '%U:%G %a' "${TOOLING_ROOT}")" == "root:root 700" ]] \
      || bad "${TOOLING_ROOT} is not root:root 0700"
    local reported
    reported="$("${COSIGN_PATH}" version 2>/dev/null | grep -iE '^ *GitVersion:' | tr -d ' ' | cut -d: -f2 || true)"
    [[ "${reported#v}" == "${COSIGN_VERSION}" ]] \
      || bad "${COSIGN_PATH} reports ${reported:-nothing}, expected v${COSIGN_VERSION}"
  else
    note "digest checked; ownership and self-reported version are production-only checks"
  fi
  (( FAILURES == 0 )) && ok "cosign ${COSIGN_VERSION} at ${COSIGN_PATH} matches the pinned digest"
}

# --- attestation procedure --------------------------------------------------
print_attestation_procedure() {
  cat <<PROC
Retrieval and verification are one command, and it writes no approval.

INDEX OR CHILD MANIFEST? **The child.** Two facts decide it, and the first was
got wrong once already:

  * \`cosign verify-attestation\` has no --platform flag. It exists on
    \`cosign verify\`, not here. The pinned ${COSIGN_VERSION} option list is
    embedded in this script and --verify-cosign-contract checks the printed
    command against the binary's own help, so this cannot be assumed again.
  * Chainguard publishes an SBOM for the index AND a standalone
    single-architecture SBOM for each variant. The variant attestation is
    attached to the variant's own digest, so naming the child retrieves the
    linux/amd64 SBOM directly.

Naming the child is therefore not a workaround for a missing flag; it is the
stronger option. The signed statement's subject IS the child manifest digest,
so the platform binding is the signature itself rather than a chain of
inference from an index descriptor.

  DISCOVERY ${CANDIDATE_DISCOVERY_REFERENCE}   <- discovery only, never authority
  INDEX     sha256:${CANDIDATE_INDEX_DIGEST}   <- context; not what is verified
  PLATFORM  ${CANDIDATE_PLATFORM}
  CHILD     ${BASE_REPOSITORY}@sha256:${CANDIDATE_MANIFEST_DIGEST}   <- verified, and the build's BASE_IMAGE
  CONFIG    sha256:${CANDIDATE_CONFIG_DIGEST}

  # 1. VERIFY cryptographically. \`download attestation\` checks no signature
  #    and is not an alternative to this.
  ${COSIGN_PATH} verify-attestation \\
      --type ${PREDICATE_TYPE} \\
      --certificate-oidc-issuer=${CHAINGUARD_ISSUER} \\
      --certificate-identity=${CHAINGUARD_IDENTITY} \\
      ${BASE_REPOSITORY}@sha256:${CANDIDATE_MANIFEST_DIGEST} \\
      > /root/kyri-g5-attestation-verified.jsonl

  # 2. Extract the committed bytes and their digest, and require the signed
  #    subject to be the child manifest. Step 1 proves who signed it; this
  #    proves what it is about.
  sudo bash ${REPOSITORY}/provisioning/execution/g5-supply-chain.sh --extract-sbom \\
      /root/kyri-g5-attestation-verified.jsonl \\
      --manifest-digest ${CANDIDATE_MANIFEST_DIGEST}

  # 3. DETERMINISM, mandatory before approval. Repeat step 1 into a second
  #    file and require the committed digest to be identical.
  ${COSIGN_PATH} verify-attestation ... \\
      > /root/kyri-g5-attestation-second.jsonl
  sudo bash ${REPOSITORY}/provisioning/execution/g5-supply-chain.sh --extract-sbom \\
      /root/kyri-g5-attestation-second.jsonl \\
      --manifest-digest ${CANDIDATE_MANIFEST_DIGEST}
  # the two sbom_sha256 values must match, or the candidate is not approvable

IF STEP 1 REPORTS "no matching attestations": stop and report it. That would
mean this candidate publishes the SPDX only against the index, contradicting
the model above, and the remedy is a re-ruling -- an explicit verified chain
from the signed index subject through the index bytes to exactly one
linux/amd64 descriptor. Do not substitute the index reference here and carry on:
the index statement's subject is the index, and accepting it would silently
drop the platform binding this ceremony exists to establish.

A note on discovery: the OCI /referrers endpoint returning count 0 for the
child manifest does NOT indicate the absence of an attestation. Cosign's
attestations are discovered through its tag scheme -- sha256-<digest>.att --
not through the referrers API, so referrers is silent about them either way.

WHAT IS COMMITTED: the base64-decoded DSSE payload, which is the in-toto
Statement carrying the SPDX document as its predicate. Those are the exact
bytes the Chainguard signature covers. The statement is parsed only to read its
predicateType and subject; the bytes written out are the decoded payload
itself. No JSON is ever re-emitted, so nothing is re-serialised.
PROC
}

# --- deterministic selection and the committed digest -----------------------
#
# Runs on a file of DSSE envelopes, one JSON object per line, exactly as
# `cosign download attestation` and `cosign verify-attestation` emit them.
# Reads locally; reaches no network.
extract_sbom() {
  [[ -f "${ENVELOPE_FILE}" ]] || halt "${ENVELOPE_FILE} is absent"
  [[ -n "${MANIFEST_DIGEST}" ]] \
    || halt "--extract-sbom requires --manifest-digest: an SBOM not bound to the selected image is somebody else's SBOM"
  # The program is single-quoted deliberately: the shell must not expand a
  # line of it. Every value it needs arrives as an argument.
  # shellcheck disable=SC2016
  ( cd / && /usr/bin/env -i PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 \
      /usr/bin/python3 -I -B -c '
import base64, hashlib, json, sys

payload_type, predicate_type, subject, path = sys.argv[1:5]
matches = []
with open(path, "rb") as handle:
    for number, line in enumerate(handle, 1):
        line = line.strip()
        if not line:
            continue
        try:
            envelope = json.loads(line)
        except ValueError:
            raise SystemExit("line %d is not JSON" % number)
        if not isinstance(envelope, dict) or envelope.get("payloadType") != payload_type:
            continue
        raw = envelope.get("payload")
        if not isinstance(raw, str):
            raise SystemExit("line %d carries no payload string" % number)
        # Byte-exact: base64 decoding is a transform, not a rendering. These
        # are the bytes PAE(payloadType, payload) signs.
        try:
            payload = base64.b64decode(raw, validate=True)
        except Exception:
            raise SystemExit("line %d payload is not valid base64" % number)
        # Parsed to INSPECT only. The parse result is never written back out;
        # what gets committed below is `payload`, untouched.
        try:
            statement = json.loads(payload)
        except ValueError:
            raise SystemExit("line %d payload is not a JSON statement" % number)
        if statement.get("predicateType") != predicate_type:
            continue
        digests = set()
        for entry in statement.get("subject", []) or []:
            if isinstance(entry, dict):
                value = (entry.get("digest") or {}).get("sha256")
                if isinstance(value, str):
                    digests.add(value)
        if subject not in digests:
            raise SystemExit(
                "line %d attests to %s, not the selected image %s"
                % (number, sorted(digests) or "nothing", subject))
        matches.append((number, payload))

if not matches:
    raise SystemExit(
        "no attestation with predicateType %s bound to %s" % (predicate_type, subject))
if len(matches) > 1:
    # Never "take the first". Two signed statements for the same predicate and
    # the same subject is an ambiguity an operator resolves, not a script.
    raise SystemExit(
        "%d attestations match predicateType %s and subject %s; refusing to choose"
        % (len(matches), predicate_type, subject))

number, payload = matches[0]
statement = json.loads(payload)
predicate = statement.get("predicate") or {}
packages = predicate.get("packages") or []

# Bounded SPDX validation, and it runs BEFORE anything is reported. A refused
# statement must never print an sbom_sha256 an operator could transcribe.
if statement.get("_type") != "https://in-toto.io/Statement/v0.1":
    raise SystemExit("unexpected statement type %r" % statement.get("_type"))
if not str(predicate.get("spdxVersion", "")).startswith("SPDX-"):
    raise SystemExit("the predicate is not an SPDX document")
if not predicate.get("name"):
    raise SystemExit("the SPDX document has no name")
if not predicate.get("documentNamespace"):
    raise SystemExit("the SPDX document has no documentNamespace")
if not packages:
    raise SystemExit("the SPDX document has an empty package inventory")

# The committed bytes, written verbatim. This is the decoded payload object --
# never a re-encoding of the parse above, which exists only to inspect.
if len(sys.argv) > 5 and sys.argv[5]:
    with open(sys.argv[5], "wb") as out:
        out.write(payload)

print("      envelope line:        %d" % number)
print("      spdx version:         %s" % predicate.get("spdxVersion"))
print("      spdx name:            %s" % predicate.get("name"))
print("      package inventory:    %d" % len(packages))
print("      committed bytes:      %d" % len(payload))
print("      sbom_sha256:          %s" % hashlib.sha256(payload).hexdigest())
' "${PAYLOAD_TYPE}" "${PREDICATE_TYPE}" "${MANIFEST_DIGEST}" "${ENVELOPE_FILE}" "${PAYLOAD_OUT}" ) \
    || halt "the attestation did not yield exactly one bound SPDX statement"
  ok "exactly one signed SPDX statement, bound to sha256:${MANIFEST_DIGEST}"
  note "record the sbom_sha256 above as the approval's sbom_sha256; sbom_source is"
  note "  'decoded DSSE payload, in-toto Statement v0.1, predicateType ${PREDICATE_TYPE}'"
}

# Every flag the printed procedure emits for verify-attestation. Extracted from
# the procedure itself rather than restated, so the two cannot drift.
procedure_flags() {
  print_attestation_procedure \
    | sed -n '/verify-attestation \\/,/^$/p' \
    | grep -oE '(^|[[:space:]])--[a-z0-9-]+' \
    | tr -d ' ' | LC_ALL=C sort -u
}

# Check the printed procedure against the PINNED option set. This runs
# everywhere, including CI, and needs no binary.
verify_flag_contract() {
  local flag unsupported=0
  while IFS= read -r flag; do
    [[ -n "${flag}" ]] || continue
    case " ${COSIGN_VERIFY_ATTESTATION_FLAGS} " in
      *" ${flag} "*) ;;
      *) bad "the printed procedure emits ${flag}, which cosign ${COSIGN_VERSION} verify-attestation does not accept"
         unsupported=$((unsupported + 1)) ;;
    esac
  done < <(procedure_flags)
  (( unsupported == 0 )) \
    && ok "every flag in the printed procedure is in the pinned ${COSIGN_VERSION} option set"
}

# Check the printed procedure against the INSTALLED BINARY'S OWN HELP. This is
# the check that would have caught --platform without an operator discovering it
# during a live ceremony, and it consults the tool rather than a document.
verify_cosign_contract() {
  verify_flag_contract
  [[ -x "${COSIGN_PATH}" ]] \
    || halt "${COSIGN_PATH} is absent or not executable; run --print-cosign-bootstrap first"
  local help flag missing=0
  help="$("${COSIGN_PATH}" verify-attestation --help 2>&1)" \
    || halt "${COSIGN_PATH} verify-attestation --help failed"
  while IFS= read -r flag; do
    [[ -n "${flag}" ]] || continue
    grep -qE "(^|[[:space:]])${flag}([[:space:]]|=|,|$)" <<<"${help}" || {
      bad "${COSIGN_PATH} verify-attestation --help does not list ${flag}"
      missing=$((missing + 1)); }
  done < <(procedure_flags)
  # The specific false assumption, asserted directly so the regression has a name.
  if grep -qE '(^|[[:space:]])--platform([[:space:]]|=|,|$)' <<<"${help}"; then
    note "this binary's verify-attestation DOES list --platform; the pinned option set is stale"
  else
    ok "confirmed against the binary: verify-attestation has no --platform flag"
  fi
  (( missing == 0 )) \
    && ok "every printed flag is accepted by ${COSIGN_PATH} verify-attestation"
}

# --- candidate evidence -----------------------------------------------------
CANDIDATE_FIELDS=(
  discovery_reference index_digest platform manifest_digest config_digest
  discovered_at discovery_commands sbom_attestation_verified
  sbom_predicate_type sbom_sha256 cosign_version cosign_sha256
  signing_identity signing_issuer
)

verify_candidate() {
  [[ -f "${CANDIDATE_EVIDENCE}" ]] \
    || halt "${CANDIDATE_EVIDENCE} is absent; candidate discovery has not been recorded"
  local name value
  for name in "${CANDIDATE_FIELDS[@]}"; do
    value="$(field_of "${name}" "${CANDIDATE_EVIDENCE}")"
    [[ -n "${value}" ]] || bad "candidate evidence is missing ${name}"
  done
  [[ "$(field_of index_digest "${CANDIDATE_EVIDENCE}")" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || bad "index_digest is not a sha256: digest"
  [[ "$(field_of manifest_digest "${CANDIDATE_EVIDENCE}")" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || bad "manifest_digest is not a sha256: digest"
  [[ "$(field_of platform "${CANDIDATE_EVIDENCE}")" == "${CANDIDATE_PLATFORM}" ]] \
    || bad "platform is not ${CANDIDATE_PLATFORM}"
  [[ "$(field_of discovery_reference "${CANDIDATE_EVIDENCE}")" == "${CANDIDATE_DISCOVERY_REFERENCE}" ]] \
    || bad "discovery_reference is not the reviewed discovery pointer"
  [[ "$(field_of sbom_predicate_type "${CANDIDATE_EVIDENCE}")" == "${PREDICATE_TYPE}" ]] \
    || bad "sbom_predicate_type is not ${PREDICATE_TYPE}"
  [[ "$(field_of signing_issuer "${CANDIDATE_EVIDENCE}")" == "${CHAINGUARD_ISSUER}" ]] \
    || bad "signing_issuer is not the pinned Chainguard issuer"
  [[ "$(field_of signing_identity "${CANDIDATE_EVIDENCE}")" == "${CHAINGUARD_IDENTITY}" ]] \
    || bad "signing_identity is not the pinned Chainguard identity"
  [[ "$(field_of cosign_sha256 "${CANDIDATE_EVIDENCE}")" == "${COSIGN_BINARY_SHA256}" ]] \
    || bad "cosign_sha256 is not the pinned binary digest"
  [[ "$(field_of sbom_attestation_verified "${CANDIDATE_EVIDENCE}")" == "yes" ]] \
    || bad "sbom_attestation_verified is not yes: the attestation was not cryptographically verified"
  (( FAILURES == 0 )) && ok "candidate evidence is complete and internally consistent"
  printf '\n'
  printf 'THIS IS A CANDIDATE, NOT AN APPROVAL.\n'
  printf 'A human reviews it and root records the approval. Nothing here writes\n'
  printf 'one, and no mode of this script can.\n'
}

# --- the production approval ------------------------------------------------
APPROVAL_FIELDS=(
  base_image_reference platform manifest_digest config_digest
  sbom_source sbom_sha256 cosign_version cosign_sha256
  attestation_predicate_type attestation_signer approved_by approved_at
)

verify_approval() {
  [[ -f "${BASE_APPROVAL}" ]] \
    || halt "${BASE_APPROVAL} is absent: no production base image has been approved"
  local name value reference
  for name in "${APPROVAL_FIELDS[@]}"; do
    value="$(field_of "${name}" "${BASE_APPROVAL}")"
    [[ -n "${value}" ]] || bad "the approval is missing ${name}"
  done
  reference="$(field_of base_image_reference "${BASE_APPROVAL}")"
  [[ "${reference}" =~ ^"${BASE_REPOSITORY}"@sha256:[0-9a-f]{64}$ ]] \
    || bad "base_image_reference ${reference:-absent} is not a digest-pinned ${BASE_REPOSITORY} reference"
  # A tag anywhere in the authoritative reference re-opens the exact hole the
  # digest pin exists to close.
  [[ "${reference}" != *:latest* ]] || bad "base_image_reference names a tag"
  [[ "$(field_of platform "${BASE_APPROVAL}")" == "${CANDIDATE_PLATFORM}" ]] \
    || bad "platform is not ${CANDIDATE_PLATFORM}"
  local manifest
  manifest="$(field_of manifest_digest "${BASE_APPROVAL}")"
  [[ "${manifest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || bad "manifest_digest is not a sha256: digest"
  # The build's base and the verified attestation subject must be the same
  # object. Approving the index reference while attesting the child would give
  # the builder a choice of platform that the signature never covered -- which
  # is the hole the --platform defect would have left open had the flag existed.
  [[ "${reference}" == "${BASE_REPOSITORY}@${manifest}" ]] \
    || bad "base_image_reference ${reference} is not the verified platform manifest ${manifest}"
  [[ "$(field_of config_digest "${BASE_APPROVAL}")" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || bad "config_digest is not a sha256: digest"
  [[ "$(field_of sbom_sha256 "${BASE_APPROVAL}")" =~ ^[0-9a-f]{64}$ ]] \
    || bad "sbom_sha256 is not a bare 64-hex digest"
  [[ "$(field_of attestation_predicate_type "${BASE_APPROVAL}")" == "${PREDICATE_TYPE}" ]] \
    || bad "attestation_predicate_type is not ${PREDICATE_TYPE}"
  [[ "$(field_of attestation_signer "${BASE_APPROVAL}")" == "${CHAINGUARD_IDENTITY}" ]] \
    || bad "attestation_signer is not the pinned Chainguard identity"
  [[ "$(field_of cosign_version "${BASE_APPROVAL}")" == "${COSIGN_VERSION}" ]] \
    || bad "cosign_version is not the pinned ${COSIGN_VERSION}"
  [[ "$(field_of cosign_sha256 "${BASE_APPROVAL}")" == "${COSIGN_BINARY_SHA256}" ]] \
    || bad "cosign_sha256 is not the pinned binary digest"
  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(stat -c '%U:%G %a' "${BASE_APPROVAL}")" == "root:root 400" ]] \
      || bad "${BASE_APPROVAL} is not root:root 0400"
  fi
  (( FAILURES == 0 )) && ok "the production approval is complete, digest-pinned, and signer-bound"
}

# ===========================================================================
printf '== G5 supply chain (%s) ==\n\n' "${MODE#--}"
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; ownership checks relaxed"

case "${MODE}" in
--print-cosign-bootstrap)      print_cosign_bootstrap ;;
--verify-cosign)               verify_cosign ;;
--print-attestation-procedure) print_attestation_procedure ;;
--verify-flag-contract)        verify_flag_contract ;;
--verify-cosign-contract)      verify_cosign_contract ;;
--extract-sbom)                extract_sbom ;;
--verify-candidate)            verify_candidate ;;
--verify-approval)             verify_approval ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 supply chain %s: all checks passed.\n' "${MODE#--}"
  printf 'Nothing was downloaded, installed, pulled, approved, or built.\n'
else
  printf 'G5 supply chain %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
