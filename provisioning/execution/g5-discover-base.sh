#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G5 base-image candidate discovery, by governed version.
#
# THIS SCRIPT REACHES THE NETWORK. It is the only piece of G5 operator tooling
# that does, which is why it is a separate artefact: `g5-supply-chain.sh`
# reaches no network in any mode, and that invariant is asserted by its suite.
# Everything here is READ-ONLY against a public registry -- it pulls no image,
# writes no approval, and mutates nothing, locally or remotely.
#
# =============================================================================
# WHY THIS EXISTS
# =============================================================================
# Discovery used to read `cgr.dev/chainguard/python:latest` and record whatever
# was current. That is how a Python 3.14.7 candidate came to be approved and
# built while the governed version is 3.14.6: `:latest` had moved, and nothing
# in the discovery step knew what version it was looking for.
#
# So discovery no longer asks "what is latest?". It asks "which child proves
# the governed Python?", and walks Chainguard's Tag History API -- anonymously
# readable for the free tier, with pull-by-digest available across tiers --
# until it finds one, newest first. A tag is a question, never an answer.
#
# =============================================================================
# WHAT THIS DOES NOT ESTABLISH
# =============================================================================
# The SPDX read here is fetched with an anonymous pull token and is **NOT
# cryptographically verified**. This produces a CANDIDATE: a digest worth
# reviewing, and the evidence of why. Approval still requires
# `cosign verify-attestation` against the child, exactly as ruled -- see
# `g5-supply-chain.sh --print-attestation-procedure`. Nothing here can write an
# approval and nothing here should be trusted as one.
#
# Usage:
#   --discover        walk the history and report the newest governed child
#   --print-procedure the operator sequence, without touching the network
#
#   --limit N         how many history entries to examine, newest first
#   --fixture DIR     test-only: read recorded history and SPDX from DIR
#                     instead of the network

REPOSITORY="/opt/schott-platform"
REGISTRY="cgr.dev"
IMAGE_REPOSITORY="chainguard/python"
PLATFORM_OS="linux"
PLATFORM_ARCHITECTURE="amd64"
PREDICATE_TYPE="https://spdx.dev/Document"

# Kept in step with the ruled evidence schema; the suite asserts they agree.
GOVERNED_PYTHON_VERSION="3.14.6"
GOVERNED_SBOM_PACKAGE="python-3.14"

DEFAULT_LIMIT=40

MODE=""
FIXTURE=""
LIMIT="${DEFAULT_LIMIT}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --discover|--print-procedure)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --limit)
      LIMIT="${2:-}"; shift 2
      [[ "${LIMIT}" =~ ^[0-9]+$ && "${LIMIT}" -gt 0 ]] \
        || { printf 'ERROR --limit needs a positive integer\n' >&2; exit 2; }
      ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
      ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---print-procedure}"

ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

print_procedure() {
  cat <<PROC
Candidate discovery, by governed version rather than by tag.

  # 1. Walk the history for a child whose SPDX proves the governed Python.
  bash ${REPOSITORY}/provisioning/execution/g5-discover-base.sh --discover

  # 2. OPERATOR REVIEW. The output is a CANDIDATE. It was read with an
  #    anonymous pull token and is not cryptographically verified.

  # 3. Verify it, which is what makes it approvable:
  bash ${REPOSITORY}/provisioning/execution/g5-supply-chain.sh \\
      --print-attestation-procedure

  # 4. OPERATOR REVIEW, then record the approval by hand. No script writes it.

Repository: ${REGISTRY}/${IMAGE_REPOSITORY}
Governed:   ${GOVERNED_SBOM_PACKAGE} at ${GOVERNED_PYTHON_VERSION}, ${PLATFORM_OS}/${PLATFORM_ARCHITECTURE}.

A vendor package revision (-rN) may differ as the same upstream Python is
rebuilt; the upstream patch may not. The revision is reported and the upstream
patch is what gets recorded.

FAIL-CLOSED. Discovery stops rather than guessing when: no child in the window
proves the governed version; a child's attestation is missing or unreadable; an
SPDX names the governed package at more than one version; or the platform child
cannot be resolved. None of those is answered by widening the search silently.
PROC
}

discover() {
  local fixture_argument="${FIXTURE:-}"
  python3 - "${REGISTRY}" "${IMAGE_REPOSITORY}" "${PLATFORM_OS}" \
            "${PLATFORM_ARCHITECTURE}" "${PREDICATE_TYPE}" \
            "${GOVERNED_SBOM_PACKAGE}" "${GOVERNED_PYTHON_VERSION}" \
            "${LIMIT}" "${fixture_argument}" <<'PY'
import base64, json, os, subprocess, sys, urllib.request

(registry, repository, want_os, want_arch, predicate_type,
 governed_package, governed_version, limit, fixture) = sys.argv[1:10]
limit = int(limit)
base = "https://%s/v2/%s" % (registry, repository)

# A fixture replaces the registry entirely, so the selection logic is exercised
# with no network and no dependence on what the vendor publishes today.
def recorded(name):
    path = os.path.join(fixture, name)
    if not os.path.exists(path):
        raise SystemExit("fixture is missing %s" % name)
    with open(path, "rb") as handle:
        return json.load(handle)

if fixture:
    token = None
else:
    with urllib.request.urlopen(
            "https://%s/token?scope=repository:%s:pull" % (registry, repository),
            timeout=30) as response:
        token = json.load(response)["token"]

ACCEPT = ("application/vnd.oci.image.index.v1+json,"
          "application/vnd.oci.image.manifest.v1+json,"
          "application/vnd.docker.distribution.manifest.list.v2+json,"
          "application/vnd.docker.distribution.manifest.v2+json")

def manifest(path):
    request = urllib.request.Request(base + path)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Accept", ACCEPT)
    with urllib.request.urlopen(request, timeout=40) as response:
        return json.load(response)

def blob(digest):
    # curl follows the CDN redirect and drops the auth header on the cross-host
    # hop, which is what the registry expects. urllib re-sends it and is 403ed.
    result = subprocess.run(
        ["curl", "-sSL", "--max-time", "60",
         "-H", "Authorization: Bearer " + token, base + "/blobs/" + digest],
        capture_output=True)
    return result.stdout

def history():
    if fixture:
        document = recorded("history.json")
    else:
        document = manifest("/_chainguard/history/latest")
    entries = document.get("history", document)
    if not isinstance(entries, list) or not entries:
        raise SystemExit("the tag history is empty or unrecognised")
    return entries

def platform_child(index_digest):
    document = recorded("index-%s.json" % index_digest.replace(":", "-")) \
        if fixture else manifest("/manifests/" + index_digest)
    children = document.get("manifests")
    if not children:
        raise SystemExit("%s is not a multi-platform index" % index_digest)
    matches = [child["digest"] for child in children
               if (child.get("platform") or {}).get("os") == want_os
               and (child.get("platform") or {}).get("architecture") == want_arch]
    if len(matches) != 1:
        raise SystemExit(
            "%s resolves %d %s/%s children; refusing to choose"
            % (index_digest, len(matches), want_os, want_arch))
    return matches[0]

def governed_version_of(child_digest):
    """The governed package's version from the child's SPDX, or a refusal."""
    if fixture:
        path = os.path.join(fixture, "spdx-%s.json" % child_digest.replace(":", "-"))
        if not os.path.exists(path):
            return (None, "no attestation")
        with open(path, "rb") as handle:
            statements = [json.load(handle)]
    else:
        try:
            attestation = manifest("/manifests/" + child_digest.replace(":", "-") + ".att")
        except Exception:
            return (None, "no attestation")
        statements = []
        for layer in attestation.get("layers", []):
            try:
                envelope = json.loads(blob(layer["digest"]))
                statements.append(json.loads(base64.b64decode(envelope["payload"])))
            except Exception:
                continue
    spdx = [s for s in statements if s.get("predicateType") == predicate_type]
    if not spdx:
        return (None, "no SPDX predicate")
    packages = (spdx[0].get("predicate") or {}).get("packages") or []
    versions = sorted({p.get("versionInfo") for p in packages
                       if p.get("name") == governed_package})
    if not versions:
        return (None, "no %s package" % governed_package)
    if len(versions) > 1:
        # Ambiguity is a stop, not a preference. Two versions of the governed
        # package in one signed document is a fact somebody must explain.
        raise SystemExit(
            "%s records %s at %s; refusing to choose"
            % (child_digest, governed_package, versions))
    return (versions[0], None)

entries = history()
print("      history entries:     %d" % len(entries))
print("      examining:           %d, newest first" % min(limit, len(entries)))
print("      governed:            %s %s (%s/%s)"
      % (governed_package, governed_version, want_os, want_arch))
print()

examined = 0
for entry in reversed(entries[-limit:]):
    index_digest = entry.get("digest")
    when = (entry.get("updateTimestamp") or entry.get("timestamp") or "?")[:19]
    if not index_digest:
        raise SystemExit("a history entry carries no digest")
    child = platform_child(index_digest)
    observed, why = governed_version_of(child)
    examined += 1
    if observed is None:
        print("      %s  %s  %s" % (when, index_digest[7:19], why))
        continue
    marker = "<-- governed" if observed.startswith(governed_version + "-") \
        or observed == governed_version else ""
    print("      %s  %s  %-12s %s" % (when, index_digest[7:19], observed, marker))
    if marker:
        print()
        print("CANDIDATE (unverified -- an anonymous read, not a signature check)")
        print("  discovery_reference   %s/%s:latest   <- how it was found, never authority"
              % (registry, repository))
        print("  was :latest at        %s" % entry.get("updateTimestamp", "?"))
        print("  index_digest          %s" % index_digest)
        print("  manifest_digest       %s" % child)
        print("  platform              %s/%s" % (want_os, want_arch))
        print("  %-21s %s (observed)" % (governed_package, observed))
        print("  %-21s %s (record this: the upstream governed patch)"
              % (governed_package, governed_version))
        print("  entries examined      %d" % examined)
        raise SystemExit(0)

raise SystemExit(
    "no child in the newest %d history entries proves %s %s; widen --limit "
    "deliberately or rule the governed version"
    % (examined, governed_package, governed_version))
PY
}

printf '== G5 base discovery (%s) ==\n\n' "${MODE#--}"
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: reading recorded history and SPDX from ${FIXTURE}; no network"

case "${MODE}" in
--print-procedure) print_procedure ;;
--discover)
  discover || halt "discovery did not produce a governed candidate"
  printf '\n'
  ok "a candidate was found and nothing was approved, pulled, or written"
  note "verify it cryptographically before approval: nothing above is a signature check"
  ;;
esac
