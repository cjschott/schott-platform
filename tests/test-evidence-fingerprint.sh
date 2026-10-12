#!/usr/bin/env bash
set -Eeuo pipefail

# The declarative platform-model Evidence fingerprint, and the S0 ceremony that
# produces a record carrying one.
#
# WHY THIS EXISTS. `content_fingerprint` was a required field nobody recomputed:
# a record could carry sixty-four zeroes, or keep a stale digest while its facts
# were edited, and validate clean. A digest that is never checked documents an
# intention rather than enforcing one. These cases pin the preimage, the
# canonicalisation, and the enforcement.
#
# FIXTURE ONLY. Every publication case writes into a temporary root. Nothing
# here writes into platform-model/evidence/, and the suite asserts that
# directory is still empty when it finishes.
#
# Governed by:
#   platform-model/schemas/evidence.schema.yaml
#   docs/standards/evidence-standard.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

EVIDENCE_BEFORE="$(find platform-model/evidence -name '*.yaml' | wc -l)"

python3 - <<'PY'
import copy, json, hashlib, os, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, ".")

from tools.platform_model import evidence_fingerprint as F
from tools.platform_model import observe_host_architecture as S0

ROOT = Path(".").resolve()
failures = 0
def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        failures += 1
        print(f"FAIL: {description}", file=sys.stderr)

BASE = {
    "api_version": "schott-platform/v1", "kind": "Evidence",
    "id": "EVID-000001", "type": "evidence", "target": "HOST-0001",
    "source_type": "command-output", "collector": "s0-host-architecture",
    "collected_at": "2026-08-19T09:00:00-05:00", "status": "success",
    "facts": {"governed_field": "architecture", "canonical_value": "x86-64"},
    "provenance": {"class": "observed", "observed_at": "2026-08-19T09:00:00-05:00"},
    "sensitivity": "public", "retention": "3650d",
    "redaction": {"performed": False}, "references": [],
}

# =========================================================================
# 1. the preimage is exactly the six ruled fields
# =========================================================================
check(F.PREIMAGE_FIELDS == ("schema_version", "target", "source_type",
                            "collector", "status", "facts"),
      f"the preimage is the six ruled fields ({F.PREIMAGE_FIELDS})")
pre = F.preimage(BASE)
check(set(pre) == set(F.PREIMAGE_FIELDS), "the built preimage carries only those six")
check(pre["schema_version"] == BASE["api_version"],
      "schema_version is taken from the record's api_version")

# A known vector: the digest is reproducible by hand from the documented rule.
expected = "sha256:" + hashlib.sha256(json.dumps(
    {"schema_version": "schott-platform/v1", "target": "HOST-0001",
     "source_type": "command-output", "collector": "s0-host-architecture",
     "status": "success",
     "facts": {"governed_field": "architecture", "canonical_value": "x86-64"}},
    sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
).hexdigest()
check(F.fingerprint(BASE) == expected,
      f"the known vector reproduces independently ({F.fingerprint(BASE)})")
check(F.is_well_formed(F.fingerprint(BASE)), "the rendered form is sha256:<64 lowercase hex>")

# =========================================================================
# 2. canonicalisation
# =========================================================================
shuffled = {k: BASE[k] for k in reversed(list(BASE))}
check(F.fingerprint(shuffled) == F.fingerprint(BASE),
      "record key order does not affect the digest")
nested = copy.deepcopy(BASE)
nested["facts"] = {"canonical_value": "x86-64", "governed_field": "architecture"}
check(F.fingerprint(nested) == F.fingerprint(BASE),
      "facts key order does not affect the digest")
unicode_record = copy.deepcopy(BASE)
unicode_record["facts"] = {"note": "café-Ω"}
check(F.canonical_bytes(unicode_record).decode("utf-8").count("café-Ω") == 1,
      "non-ASCII is emitted literally, not escaped")
check(isinstance(F.canonical_bytes(BASE), bytes), "the preimage is UTF-8 bytes")

# No default=str: a value JSON cannot represent must raise, never stringify.
import datetime as _dt
uncoercible = copy.deepcopy(BASE)
uncoercible["facts"] = {"when": _dt.datetime(2026, 8, 19)}
raised = False
try:
    F.fingerprint(uncoercible)
except F.FingerprintError:
    raised = True
check(raised, "a non-JSON-representable value refuses rather than being stringified")

missing = copy.deepcopy(BASE); del missing["target"]
raised = False
try:
    F.preimage(missing)
except F.FingerprintError:
    raised = True
check(raised, "a record missing a preimage field refuses")

# =========================================================================
# 3. every included field is bound; every excluded field is not
# =========================================================================
for field, changed in (("api_version", "schott-platform/v2"),
                       ("target", "HOST-0002"),
                       ("source_type", "manual-attestation"),
                       ("collector", "linux-host"),
                       ("status", "partial")):
    variant = copy.deepcopy(BASE); variant[field] = changed
    check(F.fingerprint(variant) != F.fingerprint(BASE),
          f"changing {field} changes the digest")
variant = copy.deepcopy(BASE)
variant["facts"] = {"governed_field": "architecture", "canonical_value": "arm64"}
check(F.fingerprint(variant) != F.fingerprint(BASE), "changing facts changes the digest")

for field, changed in (("id", "EVID-000002"),
                       ("collected_at", "2030-01-01T00:00:00+00:00"),
                       ("retention", "90d"),
                       ("sensitivity", "internal"),
                       ("references", ["EVID-000009"])):
    variant = copy.deepcopy(BASE); variant[field] = changed
    check(F.fingerprint(variant) == F.fingerprint(BASE),
          f"changing the audit field {field} does not change the digest")
variant = copy.deepcopy(BASE)
variant["provenance"] = {"class": "observed", "observed_at": "2030-01-01T00:00:00+00:00"}
check(F.fingerprint(variant) == F.fingerprint(BASE),
      "changing the provenance timestamp does not change the digest")

check(not F.is_well_formed(F.fingerprint(BASE).upper()), "uppercase hex is not well formed")
for bad in ("sha256:zz", "abc", "", None, 7, "sha1:" + "a" * 64,
            "sha256:" + "A" * 64, "sha256:" + "a" * 63):
    check(not F.is_well_formed(bad), f"a malformed fingerprint is rejected ({bad!r})")

# =========================================================================
# 4. the validator recomputes and refuses
# =========================================================================
import yaml
def model_root(record):
    tmp = Path(tempfile.mkdtemp())
    for name in ("schemas", "evidence", "hosts"):
        (tmp / name).mkdir()
    for schema in ("evidence.schema.yaml", "verification.schema.yaml",
                   "drift-rule.schema.yaml"):
        (tmp / "schemas" / schema).write_text(
            (ROOT / "platform-model" / "schemas" / schema).read_text())
    (tmp / "hosts" / "schai.yaml").write_text(
        (ROOT / "platform-model" / "hosts" / "schai.yaml").read_text())
    (tmp / "evidence" / "evid-000001-schai-host-architecture.yaml").write_text(
        yaml.safe_dump(record, sort_keys=False))
    return tmp

def validate(root):
    done = subprocess.run(
        [sys.executable, str(ROOT / "tools/platform_model/validate_evidence.py"),
         "--root", str(root)], capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr

sound = copy.deepcopy(BASE); sound["content_fingerprint"] = F.fingerprint(sound)
code, out = validate(model_root(sound))
check(code == 0, f"a record whose fingerprint matches validates ({out.strip()[:90]})")

zeroed = copy.deepcopy(sound); zeroed["content_fingerprint"] = "sha256:" + "0" * 64
code, out = validate(model_root(zeroed))
check(code == 1 and "does not match" in out, "an all-zero fingerprint is refused")

stale = copy.deepcopy(sound)
stale["facts"] = {"governed_field": "architecture", "canonical_value": "arm64"}
code, out = validate(model_root(stale))
check(code == 1 and "does not match" in out, "mutated facts with a stale fingerprint are refused")

moved = copy.deepcopy(sound); moved["target"] = "HOST-0002"
code, out = validate(model_root(moved))
check(code == 1, "a changed target with a stale fingerprint is refused")

shaped = copy.deepcopy(sound); shaped["content_fingerprint"] = "not-a-digest"
code, out = validate(model_root(shaped))
check(code == 1 and "64 lowercase" in out, "a malformed fingerprint is refused by shape")

upper = copy.deepcopy(sound)
upper["content_fingerprint"] = sound["content_fingerprint"].upper()
code, out = validate(model_root(upper))
check(code == 1, "an uppercase digest is refused")

unknown = copy.deepcopy(sound); unknown["target"] = "HOST-9999"
unknown["content_fingerprint"] = F.fingerprint(unknown)
code, out = validate(model_root(unknown))
check(code == 1 and "does not resolve" in out,
      "an unknown target is refused even with a correct fingerprint")

# Audit metadata may move without invalidating the record.
retimed = copy.deepcopy(sound)
retimed["collected_at"] = "2027-03-04T11:22:33+00:00"
retimed["provenance"] = {"class": "observed", "observed_at": "2027-03-04T11:22:33+00:00"}
code, out = validate(model_root(retimed))
check(code == 0, "changing audit timestamps keeps the record valid")

# =========================================================================
# 5. HOST-0001 is schai, from committed source
# =========================================================================
host = yaml.safe_load((ROOT / "platform-model" / "hosts" / "schai.yaml").read_text())
check(host["id"] == "HOST-0001" and host["name"] == "schai"
      and host["hostname"] == "schai" and host["type"] == "host",
      "HOST-0001 is schai in the committed model")

# =========================================================================
# 6. observations and normalisation
# =========================================================================
from tools.fabric.resources import normalise_host_architecture
check(S0.OBSERVATIONS[0][1] == "uname -m", "uname -m is observed")
check("lscpu" in S0.OBSERVATIONS[1][1], "lscpu is observed")
check("dpkg --print-architecture" == S0.OBSERVATIONS[2][1], "dpkg is observed")
check(len(S0.OBSERVATIONS) == 3, "all three observations are mandatory")
source = (ROOT / "tools/platform_model/observe_host_architecture.py").read_text()
check("normalise_host_architecture" in source and "x86-64" not in source,
      "the generator defers to the shared normaliser and never spells the token")
check(S0.COLLECTOR == "s0-host-architecture" and S0.SOURCE_TYPE == "command-output",
      "the collector and source_type follow repository convention")

facts, canonical = S0.collect()
check(canonical == normalise_host_architecture("x86_64"),
      f"the ceremony's canonical value is the normaliser's ({canonical})")
check(len(facts["observations"]) == 3, "all three raw observations are retained")
check({o["raw_value"] for o in facts["observations"]} == {"x86_64", "amd64"},
      "the raw values are retained exactly as reported")
check(facts["all_sources_consistent"] is True, "consistency is recorded")
check(facts["governed_field"] == "architecture", "the governed field is architecture")
for absent in ("host_memory_mb", "host_cpu_cores", "accelerator_class",
               "quota", "network"):
    check(absent not in json.dumps(facts), f"no {absent} fact is evidenced")

# Refusals, with the observation table swapped for a failing one.
original = S0.OBSERVATIONS
for label, table in (
        ("a missing command", (("x", "nope", ["definitely-not-a-command"]),)),
        ("a non-zero command", (("x", "false", ["sh", "-c", "exit 3"]),)),
        ("empty output", (("x", "empty", ["sh", "-c", "printf ''"]),)),
        ("an unsupported architecture", (("x", "bogus", ["sh", "-c", "echo sparc64"]),)),
        ("disagreement after normalisation",
         (("a", "x86", ["sh", "-c", "echo x86_64"]),
          ("b", "arm", ["sh", "-c", "echo arm64"]))),
):
    S0.OBSERVATIONS = table
    raised = False
    try:
        S0.collect()
    except S0.CeremonyError:
        raised = True
    check(raised, f"{label} refuses")
S0.OBSERVATIONS = original

# =========================================================================
# 7. identifier derivation and publication
# =========================================================================
with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp) / "evidence"
    check(S0.next_identifier(directory) == "EVID-000001",
          "an empty directory derives EVID-000001")
    directory.mkdir()
    (directory / "evid-000001-x.yaml").write_text(yaml.safe_dump({"id": "EVID-000001"}))
    check(S0.next_identifier(directory) == "EVID-000002",
          "an occupied identifier advances to the lowest unused one")
    (directory / "evid-000003-x.yaml").write_text(yaml.safe_dump({"id": "EVID-000003"}))
    check(S0.next_identifier(directory) == "EVID-000002",
          "a gap is filled before advancing past it")

with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp) / "evidence"
    facts, _ = S0.collect()
    record = S0.build(target="HOST-0001", collected_at="2026-08-19T09:00:00-05:00",
                      identifier="EVID-000001", facts=facts)
    check(record["content_fingerprint"] == F.fingerprint(record),
          "the generated record verifies against its own fingerprint")
    final = S0.publish(record, directory, "schai-host-architecture")
    check(final.name == "evid-000001-schai-host-architecture.yaml",
          f"the filename is deterministic and six-digit ({final.name})")
    check(len(list(directory.glob("*.yaml"))) == 1, "publication writes exactly one file")
    check(not list(directory.glob(".s0-*")), "no temporary artefact remains")

    refused = False
    try:
        S0.publish(record, directory, "schai-host-architecture")
    except S0.CeremonyError:
        refused = True
    check(refused, "publishing over an existing pathname refuses")
    check(len(list(directory.glob("*.yaml"))) == 1, "the refusal wrote nothing further")

# A failure during publication leaves nothing behind.
with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp) / "evidence"
    broken = copy.deepcopy(record)
    broken["facts"] = {"when": _dt.datetime(2026, 8, 19)}   # unserialisable
    raised = False
    try:
        S0.publish(broken, directory, "slug")
    except Exception:
        raised = True
    check(raised, "an unpublishable record raises")
    check(not list(directory.glob("*.yaml")) and not list(directory.glob(".s0-*")),
          "no partial file survives a failed publication")

# =========================================================================
# 8. default behaviour and boundaries
# =========================================================================
done = subprocess.run([sys.executable,
                       str(ROOT / "tools/platform_model/observe_host_architecture.py")],
                      capture_output=True, text=True)
check(done.returncode == 0, "the default run succeeds")
emitted = yaml.safe_load(done.stdout)
check(emitted["id"] == "EVID-000001" and emitted["target"] == "HOST-0001",
      "the candidate is printed to stdout")
check(F.fingerprint(emitted) == emitted["content_fingerprint"],
      "the printed candidate verifies against its own fingerprint")
check("nothing was written" in done.stderr, "the default run says it wrote nothing")

for token in ("podman", "docker", "kyri-exec", "sudo", "/var/lib/kyri",
              "/data/kyri"):
    check(token not in source, f"the ceremony never mentions {token}")
code_lines = [l for l in source.splitlines() if not l.lstrip().startswith("#")]
code = "\n".join(code_lines)
for symbol in ("EvidenceStore", "allocate_id", "evidence_builder"):
    check(f"import {symbol}" not in code and f"{symbol}(" not in code,
          f"the ceremony neither imports nor calls {symbol}")
check("subprocess.run" in source, "the ceremony runs only its own read-only observations")

# The runtime observation store is untouched and still refuses a repository root.
from tools.observation.evidence_store import EvidenceStore, StoreError
refused = False
try:
    EvidenceStore(str(ROOT / "platform-model"))
except StoreError:
    refused = True
check(refused, "the runtime EvidenceStore still refuses a root inside a git repository")

print()
if failures:
    print(f"Evidence fingerprint validation FAILED: {failures}", file=sys.stderr)
    sys.exit(1)
print("Evidence fingerprint and S0 ceremony validation passed.")
PY
status=$?

EVIDENCE_AFTER="$(find platform-model/evidence -name '*.yaml' | wc -l)"
if [[ "${EVIDENCE_BEFORE}" != "${EVIDENCE_AFTER}" ]]; then
  printf 'FAIL: the suite changed platform-model/evidence (%s -> %s)\n' \
    "${EVIDENCE_BEFORE}" "${EVIDENCE_AFTER}" >&2
  exit 1
fi
printf 'PASS: platform-model/evidence still holds %s records\n' "${EVIDENCE_AFTER}"
exit "${status}"
