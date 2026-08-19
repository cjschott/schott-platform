#!/usr/bin/env bash
set -Eeuo pipefail

# The governed Fabric resource vocabulary and the one satisfaction rule.
#
# WHAT THIS EXISTS FOR. Fabric carried two independent containment
# implementations that happened to agree, compared capacities for equality so a
# host larger than required was refused, accepted any dictionary key as a
# resource dimension, and never enforced the documented rule that a package may
# not declare less than its contract. Each of those is a governance rule, and a
# governance rule with no test is a comment.
#
# PURE AND OFFLINE. Every case here is a function call over mappings. Nothing
# writes a record, allocates an identifier, opens a store, or touches the
# installed runtime.
#
# Governed by:
#   platform-model/schemas/capability-host.schema.yaml
#   docs/decisions/ADR-0012-distributed-capability-fabric.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

python3 - <<'PY'
import sys
sys.path.insert(0, ".")

from tools.fabric import admission as A
from tools.fabric import eligibility as E
from tools.fabric import resources as R
from tools.fabric.resources import (ARCHITECTURE_VALUES, REASON_MALFORMED_VALUE,
                                    REASON_UNKNOWN_DIMENSION,
                                    normalise_host_architecture, satisfies,
                                    validate_resource_map)

failures = 0
def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        failures += 1
        print(f"FAIL: {description}", file=sys.stderr)

# =========================================================================
# 1. the governed vocabulary is closed
# =========================================================================
GOVERNED = {"architecture": "x86-64", "accelerator_class": "discrete-gpu",
            "accelerator_compute_capability": "sm_61",
            "host_memory_mb": 8192, "host_cpu_cores": 12,
            "accelerator_memory_mb": 8192}
for name, value in GOVERNED.items():
    check(validate_resource_map({name: value}) is None,
          f"the governed dimension {name} is accepted")
check(validate_resource_map(GOVERNED) is None,
      "every governed dimension is accepted together")
check(set(R.RESOURCE_FIELDS) == set(GOVERNED),
      f"the vocabulary is exactly the six declared dimensions ({sorted(R.RESOURCE_FIELDS)})")

for junk in ("memory_mb", "gpu", "cores", "arch", "quota_blocks", "network"):
    check(validate_resource_map({junk: 1}) == REASON_UNKNOWN_DIMENSION,
          f"the ungoverned dimension {junk} refuses")
check(validate_resource_map({"host_memory_mb": 512, "memory_mb": 512})
      == REASON_UNKNOWN_DIMENSION,
      "one ungoverned dimension refuses the whole mapping")
for shape in (None, 7, "text", ["host_memory_mb"], ()):
    check(validate_resource_map(shape) == REASON_MALFORMED_VALUE,
          f"a resource mapping that is not a mapping refuses ({type(shape).__name__})")

# =========================================================================
# 2. per-field validation
# =========================================================================
for field in ("host_memory_mb", "host_cpu_cores", "accelerator_memory_mb"):
    check(validate_resource_map({field: 1}) is None, f"{field} accepts a positive integer")
    check(validate_resource_map({field: True}) == REASON_MALFORMED_VALUE,
          f"{field} refuses a bool, which is an int in Python and not a capacity")
    check(validate_resource_map({field: False}) == REASON_MALFORMED_VALUE,
          f"{field} refuses False")
    check(validate_resource_map({field: 1.5}) == REASON_MALFORMED_VALUE,
          f"{field} refuses a float")
    check(validate_resource_map({field: 512.0}) == REASON_MALFORMED_VALUE,
          f"{field} refuses a whole float, which is still not an integer")
    check(validate_resource_map({field: "512"}) == REASON_MALFORMED_VALUE,
          f"{field} refuses a numeric string rather than coercing it")
    check(validate_resource_map({field: -1}) == REASON_MALFORMED_VALUE,
          f"{field} refuses a negative capacity")
    # Zero is pinned deliberately: a capacity of nought is not a capacity, and a
    # machine without the resource omits the dimension rather than declaring
    # none of it. Absence is how "no accelerator" is said.
    check(validate_resource_map({field: 0}) == REASON_MALFORMED_VALUE,
          f"{field} refuses zero: absence is expressed by omitting the dimension")

for token_field, good, bad in (
        ("architecture", "x86-64", "x86_64"),
        ("accelerator_class", "discrete-gpu", "gpu")):
    check(validate_resource_map({token_field: good}) is None,
          f"{token_field} accepts the governed token {good}")
    check(validate_resource_map({token_field: bad}) == REASON_MALFORMED_VALUE,
          f"{token_field} refuses the ungoverned token {bad}")
    check(validate_resource_map({token_field: 1}) == REASON_MALFORMED_VALUE,
          f"{token_field} refuses a non-string")
    check(validate_resource_map({token_field: ""}) == REASON_MALFORMED_VALUE,
          f"{token_field} refuses an empty string")
check(validate_resource_map({"accelerator_compute_capability": "anything"}) is None,
      "the opaque vendor string accepts any non-empty string")
check(validate_resource_map({"accelerator_compute_capability": ""})
      == REASON_MALFORMED_VALUE,
      "the opaque vendor string refuses empty")

# =========================================================================
# 3. architecture: canonical token only, and never a producer spelling
# =========================================================================
check(ARCHITECTURE_VALUES == frozenset({"x86-64"}),
      f"the governed architecture space is closed at x86-64 ({sorted(ARCHITECTURE_VALUES)})")
check(validate_resource_map({"architecture": "x86-64"}) is None,
      "the canonical token x86-64 is accepted as a governed value")
for spelling in ("x86_64", "amd64", "X86-64", "X86_64", "arm64", "aarch64",
                 "bogus", " x86-64", "x86-64 "):
    check(validate_resource_map({"architecture": spelling}) == REASON_MALFORMED_VALUE,
          f"the raw or unknown spelling {spelling!r} refuses as a governed value")

# Normalisation lives at the host-observation boundary and nowhere else.
for observation, expected in (("x86_64", "x86-64"), ("amd64", "x86-64"),
                              ("x86-64", "x86-64"), ("  x86_64  ", "x86-64")):
    check(normalise_host_architecture(observation) == expected,
          f"the host observation {observation!r} normalises to {expected}")
for observation in ("arm64", "aarch64", "riscv64", "", None, 7, "AMD64"):
    check(normalise_host_architecture(observation) is None,
          f"the unrecognised host observation {observation!r} normalises to nothing")

# The separation that matters: normalisation is not reachable from comparison,
# so an image's amd64 can never become this machine's architecture by accident.
import inspect
for module in (A, E):
    check("normalise_host_architecture" not in inspect.getsource(module),
          f"{module.__name__} never normalises during comparison")
# The normalisation table is reachable only through the host-observation
# function. Comparison never consults it, so an `amd64` string cannot become a
# governed host value by passing through satisfaction.
check(not satisfies({"architecture": "amd64"}, {"architecture": "x86-64"}),
      "a raw observation is not silently normalised during satisfaction")
check(not satisfies({"architecture": "x86-64"}, {"architecture": "amd64"}),
      "a raw observation in a profile does not satisfy the canonical requirement")
check(validate_resource_map({"architecture": "amd64"}) == REASON_MALFORMED_VALUE,
      "an OCI-spelling architecture cannot be recorded as a governed host value")

# =========================================================================
# 4. satisfaction: capacity is a threshold, a token is an identity
# =========================================================================
check(satisfies({"host_memory_mb": 512}, {"host_memory_mb": 512}),
      "an exactly equal capacity is satisfied")
check(satisfies({"host_memory_mb": 512}, {"host_memory_mb": 8192}),
      "a larger available capacity satisfies a smaller requirement")
check(not satisfies({"host_memory_mb": 8192}, {"host_memory_mb": 512}),
      "a smaller available capacity refuses a larger requirement")
check(not satisfies({"host_memory_mb": 512}, {}),
      "a dimension the profile does not name is not satisfied")
check(not satisfies({"host_memory_mb": 512}, {"host_cpu_cores": 12}),
      "a different dimension does not satisfy a requirement")
check(satisfies({}, {"host_memory_mb": 8192}),
      "an empty requirement is satisfied by anything, which is why {} is never governed policy")
check(satisfies({"architecture": "x86-64"}, {"architecture": "x86-64"}),
      "an identical token is satisfied")
check(not satisfies({"architecture": "x86-64"}, {"architecture": "x86_64"}),
      "a token differing only in spelling is not satisfied")
check(not satisfies({"accelerator_class": "discrete-gpu"},
                    {"accelerator_class": "integrated-gpu"}),
      "a different accelerator class is not satisfied")
check(not satisfies({"memory_mb": 512}, {"memory_mb": 512}),
      "an ungoverned dimension is never satisfied, even against itself")
for shape in (None, 7, "text"):
    check(not satisfies(shape, {"host_memory_mb": 1}) and
          not satisfies({"host_memory_mb": 1}, shape),
          f"satisfaction refuses a non-mapping ({type(shape).__name__})")

# =========================================================================
# 5. contract -> package -> verified host, one rule read three ways
# =========================================================================
CONTRACT = {"host_memory_mb": 512}
check(satisfies(CONTRACT, {"host_memory_mb": 512}),
      "a package matching its contract exactly is accepted")
check(satisfies(CONTRACT, {"host_memory_mb": 1024}),
      "a package requiring more than its contract is accepted: stronger is still an implementation")
check(not satisfies(CONTRACT, {"host_memory_mb": 256}),
      "a package requiring less than its contract refuses")
check(not satisfies(CONTRACT, {"architecture": "x86-64"}),
      "a package omitting a contract dimension refuses")
check(satisfies(CONTRACT, {"host_memory_mb": 512, "architecture": "x86-64"}),
      "a package adding a dimension its contract did not name is accepted")
check(satisfies({"architecture": "x86-64"},
                {"architecture": "x86-64", "host_memory_mb": 512}),
      "extra dimensions on the satisfying side are irrelevant to the requirement")
check(not satisfies({"architecture": "x86-64", "host_memory_mb": 512},
                    {"architecture": "x86-64"}),
      "a package differing from its contract by an omitted dimension refuses")
check(not satisfies({"accelerator_class": "discrete-gpu"},
                    {"accelerator_class": "none"}),
      "a package weakening a contract's token dimension refuses")

HOST = {"host_memory_mb": 8192, "host_cpu_cores": 12, "architecture": "x86-64"}
check(satisfies({"host_memory_mb": 512, "architecture": "x86-64"}, HOST),
      "a package requirement the verified host meets is satisfied")
check(not satisfies({"host_memory_mb": 65536}, HOST),
      "a package requiring more memory than the host was verified to have refuses")
check(not satisfies({"accelerator_memory_mb": 1}, HOST),
      "a dimension the operator never verified refuses")

# Advertisement: a self-report may not enlarge what an operator attested.
check(satisfies({"host_memory_mb": 8192}, HOST),
      "a truthful advertisement claim is satisfied by the verified profile")
check(not satisfies({"host_memory_mb": 65536}, HOST),
      "an inflated advertisement claim refuses")
check(not satisfies({"architecture": "amd64"}, HOST),
      "an advertisement claiming a different architecture token refuses")

# =========================================================================
# 6. one primitive, consumed by both planes
# =========================================================================
check(A.satisfies is R.satisfies,
      "admission consumes the shared satisfaction primitive")
check(E.satisfies is R.satisfies,
      "eligibility consumes the shared satisfaction primitive")
for module in (A, E):
    check("def _contained" not in inspect.getsource(module),
          f"{module.__name__} carries no private containment implementation")
check(A.validate_resource_map is R.validate_resource_map,
      "admission consumes the shared vocabulary validator")

# =========================================================================
# 7. the first fixture's proposed requirement, proven governed
# =========================================================================
FIXTURE = {"architecture": "x86-64"}
check(validate_resource_map(FIXTURE) is None,
      "the proposed first-fixture requirement is governed")
check(FIXTURE != {}, "the proposed first-fixture requirement is not vacuous")
check(satisfies(FIXTURE, HOST),
      "the proposed requirement is satisfied by a schai-shaped verified profile")
check(not satisfies(FIXTURE, {"architecture": "x86_64"}),
      "the proposed requirement is NOT satisfied by a raw-spelling profile")
check(not satisfies(FIXTURE, {"architecture": "amd64"}),
      "the proposed requirement is NOT satisfied by an OCI-spelling profile")
for forbidden in ("quota_blocks", "quota_inodes", "network"):
    check(forbidden not in R.RESOURCE_FIELDS,
          f"{forbidden} is not a Fabric resource dimension")

print()
if failures:
    print(f"Fabric resource-semantics validation FAILED: {failures}", file=sys.stderr)
    sys.exit(1)
print("Fabric resource-semantics validation passed.")
PY
