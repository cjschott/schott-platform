#!/usr/bin/env bash
# This suite uses `<test> && pass ... || fail ...`. SC2015 warns the C branch
# can run when A succeeded -- impossible here, because `pass` is a single
# printf and cannot fail.
# shellcheck disable=SC2015
set -Eeuo pipefail

# Validation for governed-version base-image discovery.
#
# WHY IT EXISTS. Discovery used to read `:latest` and record whatever was
# current. That is how a Python 3.14.7 candidate came to be approved and built
# against a governed 3.14.6: the tag had moved and nothing in the discovery
# step knew what version it was looking for. Discovery now asks which child
# proves the governed Python and walks the tag history until it finds one.
#
# NO NETWORK. Every case drives the selection logic against recorded history
# and recorded SPDX from a fixture directory, so the suite does not depend on
# what the vendor publishes today -- which is precisely the dependency that
# caused the incident.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISCOVER="${REPOSITORY}/provisioning/execution/g5-discover-base.sh"
[[ -f "${DISCOVER}" ]] || { printf 'discovery tooling missing: %s\n' "${DISCOVER}" >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${DISCOVER}" | head -1; }
GOVERNED_PACKAGE="$(read_pin GOVERNED_SBOM_PACKAGE)"
GOVERNED_VERSION="$(read_pin GOVERNED_PYTHON_VERSION)"
PREDICATE_TYPE="$(read_pin PREDICATE_TYPE)"

# ===========================================================================
# Recorded registry state
# ===========================================================================
# Three history entries, newest first: two at the wrong version and one at the
# governed one, so selection has to walk past something to succeed.
NEWEST="sha256:$(printf 'a%.0s' {1..64})"
MIDDLE="sha256:$(printf 'b%.0s' {1..64})"
GOVERNED="sha256:$(printf 'c%.0s' {1..64})"
CHILD_NEWEST="sha256:$(printf '1%.0s' {1..64})"
CHILD_MIDDLE="sha256:$(printf '2%.0s' {1..64})"
CHILD_GOVERNED="sha256:$(printf '3%.0s' {1..64})"

build_fixture() {
  local root="$1"; rm -rf "${root}"; mkdir -p "${root}"
  python3 - "${root}" "${NEWEST}" "${MIDDLE}" "${GOVERNED}" \
             "${CHILD_NEWEST}" "${CHILD_MIDDLE}" "${CHILD_GOVERNED}" \
             "${GOVERNED_PACKAGE}" "${GOVERNED_VERSION}" "${PREDICATE_TYPE}" <<'PY'
import json, os, sys
(root, newest, middle, governed, child_newest, child_middle, child_governed,
 package, version, predicate_type) = sys.argv[1:11]

def write(name, document):
    with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
        json.dump(document, handle)

# Ascending, as the API returns it: the newest entry is last.
write("history.json", {"history": [
    {"digest": governed, "updateTimestamp": "2026-08-05T14:46:13.893Z"},
    {"digest": middle,   "updateTimestamp": "2026-08-07T01:16:57.000Z"},
    {"digest": newest,   "updateTimestamp": "2026-08-14T07:45:50.000Z"},
]})

def index(name, child):
    write("index-%s.json" % name.replace(":", "-"), {"manifests": [
        {"digest": "sha256:" + "f" * 64,
         "platform": {"os": "linux", "architecture": "arm64"}},
        {"digest": child, "platform": {"os": "linux", "architecture": "amd64"}},
    ]})

for name, child in ((newest, child_newest), (middle, child_middle),
                    (governed, child_governed)):
    index(name, child)

def spdx(child, versions):
    write("spdx-%s.json" % child.replace(":", "-"), {
        "_type": "https://in-toto.io/Statement/v0.1",
        "predicateType": predicate_type,
        "subject": [{"name": "cgr.dev/chainguard/python",
                     "digest": {"sha256": child.split(":", 1)[1]}}],
        "predicate": {"spdxVersion": "SPDX-2.3", "name": "sbom-sha256:x",
                      "documentNamespace": "https://spdx.org/spdxdocs/x",
                      "packages": [{"name": package, "versionInfo": v}
                                   for v in versions]
                                  + [{"name": "cpython", "versionInfo": "v" + version}]}})

spdx(child_newest, ["3.14.7-r0"])
spdx(child_middle, ["3.14.7-r0"])
spdx(child_governed, [version + "-r4"])
PY
}

run_discover() {
  local root="$1"; shift
  ( cd "${REPOSITORY}" && bash "${DISCOVER}" --fixture "${root}" --discover "$@" ) \
    > "${root}/last-run.log" 2>&1
}

# ===========================================================================
# 1. selection by governed version, not by tag
# ===========================================================================
root="${WORK}/clean"; build_fixture "${root}"
if run_discover "${root}"; then
  if grep -qF "manifest_digest       ${CHILD_GOVERNED}" "${root}/last-run.log"; then
    pass "discovery selects the child whose SPDX proves the governed version"
  else
    fail "the wrong child was selected: $(grep manifest_digest "${root}/last-run.log")"
  fi
else
  fail "discovery failed on a fixture containing a governed child: $(tail -6 "${root}/last-run.log")"
fi
grep -qF "index_digest          ${GOVERNED}" "${root}/last-run.log" \
  && pass "the reported index is the one that carried the governed child" \
  || fail "the reported index is wrong"
# The newest entries are at the wrong version and must be walked past, not taken.
grep -qF "${CHILD_NEWEST}" "${root}/last-run.log" \
  && fail "discovery reported the newest child despite its version" \
  || pass "the newest child is not selected merely for being newest"
grep -q '3.14.7-r0' "${root}/last-run.log" \
  && pass "the versions walked past are reported, so the choice is auditable" \
  || fail "discovery does not show what it rejected"

# The vendor revision is observed; the upstream patch is what gets recorded.
grep -qF "${GOVERNED_VERSION}-r4 (observed)" "${root}/last-run.log" \
  && pass "the vendor revision is reported as observed" \
  || fail "the observed vendor revision is not reported"
grep -qF "${GOVERNED_VERSION} (record this" "${root}/last-run.log" \
  && pass "the upstream governed patch is what the operator is told to record" \
  || fail "discovery does not distinguish the recorded value from the observed one"

# A tag may be named as provenance; it must never be the authority.
grep -q 'never authority' "${root}/last-run.log" \
  && pass "the discovery tag is labelled as provenance, not authority" \
  || fail "the discovery tag is not marked non-authoritative"
grep -qi 'unverified' "${root}/last-run.log" \
  && pass "the output is labelled unverified: an anonymous read is not a signature check" \
  || fail "the output does not say it is unverified"

# ===========================================================================
# 2. fail-closed, every way
# ===========================================================================
# No governed child in the window.
root="${WORK}/nogoverned"; build_fixture "${root}"
python3 - "${root}" "${CHILD_GOVERNED}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / ("spdx-%s.json" % sys.argv[2].replace(":", "-"))
document = json.loads(path.read_text())
for package in document["predicate"]["packages"]:
    if package["name"].startswith("python-"):
        package["versionInfo"] = "3.14.7-r0"
path.write_text(json.dumps(document))
PY
if run_discover "${root}"; then
  fail "discovery reported a candidate with no governed child present"
else
  grep -q 'no child in the newest' "${root}/last-run.log" \
    && pass "no governed child in the window is a stop, not a fallback to latest" \
    || fail "an absent governed child was refused for the wrong reason"
fi

# Two versions of the governed package in one signed document.
root="${WORK}/ambiguous"; build_fixture "${root}"
python3 - "${root}" "${CHILD_GOVERNED}" "${GOVERNED_PACKAGE}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / ("spdx-%s.json" % sys.argv[2].replace(":", "-"))
document = json.loads(path.read_text())
document["predicate"]["packages"].append(
    {"name": sys.argv[3], "versionInfo": "3.14.6-r9"})
path.write_text(json.dumps(document))
PY
if run_discover "${root}"; then
  fail "an SPDX naming the governed package at two versions was accepted"
else
  grep -q 'refusing to choose' "${root}/last-run.log" \
    && pass "an SPDX naming the governed package twice is a stop, not a preference" \
    || fail "ambiguity was refused for the wrong reason"
fi

# A missing attestation is reported and walked past, never assumed absent-good.
root="${WORK}/noatt"; build_fixture "${root}"
rm -f "${root}/spdx-${CHILD_GOVERNED//:/-}.json"
if run_discover "${root}"; then
  fail "a child with no attestation was selected"
else
  grep -q 'no attestation' "${root}/last-run.log" \
    && pass "a child with no attestation is reported and never selected" \
    || fail "a missing attestation was handled silently"
fi

# An index with no platform child, and one with two.
root="${WORK}/noplatform"; build_fixture "${root}"
python3 - "${root}" "${GOVERNED}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / ("index-%s.json" % sys.argv[2].replace(":", "-"))
document = json.loads(path.read_text())
document["manifests"] = [m for m in document["manifests"]
                         if m["platform"]["architecture"] != "amd64"]
path.write_text(json.dumps(document))
PY
run_discover "${root}" \
  && fail "an index with no linux/amd64 child was accepted" \
  || pass "an index with no platform child is a stop"

root="${WORK}/twoplatform"; build_fixture "${root}"
python3 - "${root}" "${GOVERNED}" "${CHILD_MIDDLE}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / ("index-%s.json" % sys.argv[2].replace(":", "-"))
document = json.loads(path.read_text())
document["manifests"].append(
    {"digest": sys.argv[3], "platform": {"os": "linux", "architecture": "amd64"}})
path.write_text(json.dumps(document))
PY
if run_discover "${root}"; then
  fail "an index with two linux/amd64 children was accepted"
else
  grep -q 'refusing to choose' "${root}/last-run.log" \
    && pass "an index resolving two platform children is a stop" \
    || fail "a duplicate platform child was refused for the wrong reason"
fi

# A predicate that is not SPDX is not an SBOM.
root="${WORK}/notspdx"; build_fixture "${root}"
python3 - "${root}" "${CHILD_GOVERNED}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / ("spdx-%s.json" % sys.argv[2].replace(":", "-"))
document = json.loads(path.read_text())
document["predicateType"] = "https://slsa.dev/provenance/v1"
path.write_text(json.dumps(document))
PY
run_discover "${root}" \
  && fail "a non-SPDX predicate was read as an SBOM" \
  || pass "a non-SPDX predicate is not treated as an SBOM"

# ===========================================================================
# 3. the constants agree with the ruled schema
# ===========================================================================
module_package="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from tools.provisioning.provisioning_evidence import GOVERNED_SBOM_PACKAGE
print(GOVERNED_SBOM_PACKAGE)' "${REPOSITORY}")"
module_version="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from tools.provisioning.provisioning_evidence import GOVERNED_PYTHON_VERSION
print(GOVERNED_PYTHON_VERSION)' "${REPOSITORY}")"
[[ "${GOVERNED_PACKAGE}" == "${module_package}" && "${GOVERNED_VERSION}" == "${module_version}" ]] \
  && pass "discovery targets the same governed package and version as the ruled schema" \
  || fail "discovery targets ${GOVERNED_PACKAGE}/${GOVERNED_VERSION}, the schema ${module_package}/${module_version}"

# ===========================================================================
# 4. discovery approves nothing, and the no-network invariant is preserved
# ===========================================================================
if grep -qE '> *"?\$\{?BASE_APPROVAL|kyri-g5-approved-base' "${DISCOVER}"; then
  fail "discovery writes an approval"
else
  pass "discovery cannot write an approval: a candidate is promoted by a human"
fi
for forbidden in 'podman' 'docker' 'cosign' 'buildah'; do
  grep -qE "^[[:space:]]*${forbidden}" "${DISCOVER}" \
    && fail "discovery invokes ${forbidden}" || true
done
pass "discovery pulls no image and runs no container runtime"
# The other supply-chain tooling must stay network-free; that is why discovery
# is a separate artefact rather than another mode of it.
if grep -qE '^[[:space:]]*(curl|wget)' "${REPOSITORY}/provisioning/execution/g5-supply-chain.sh" \
   | grep -v '^ *#'; then
  fail "the supply-chain tooling gained a network call"
else
  pass "the supply-chain tooling is still network-free: discovery is separate"
fi

name="tests/test-capability-execution-g5-discovery.sh"
grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
  && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml" \
  && pass "the suite runs in local validation and in CI" \
  || fail "the suite is not registered in local validation and CI"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 discovery validation passed.\n'
else
  printf 'G5 discovery validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
