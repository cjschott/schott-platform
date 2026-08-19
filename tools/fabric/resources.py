"""The governed resource vocabulary, and the one rule for satisfying it.

**One primitive, consumed by everybody.** Admission and eligibility used to
carry independent `_contained` implementations that happened to agree. Two
implementations of a governance rule are two rules, and the day they diverge
nobody finds out from a test — they find out from a workload placed on a
machine that could not run it. Everything here is a pure function over
mappings, so the plane that admits and the plane that evaluates cannot drift.

**A dimension is governed or it is refused.** The vocabulary is the one
`platform-model/schemas/capability-host.schema.yaml` declares, and an unknown
key is a refusal rather than an ignored field. A profile carrying
`memory_mb` where the vocabulary says `host_memory_mb` is not a narrower
profile; it is a profile nobody validated, and under a containment rule an
unrecognised dimension silently satisfies nothing and blocks nothing.

**Capacity is compared as capacity.** `host_memory_mb`, `host_cpu_cores` and
`accelerator_memory_mb` are quantities, and a requirement of 512 MiB is
satisfied by a machine verified at 8192 MiB. Comparing them for equality —
which is what this plane did — refuses every host that is larger than asked
for, which is fail-closed and simply wrong. Tokens are the opposite: an
architecture or an accelerator class is an identity, and "close enough" has no
meaning, so those compare exactly.

**`architecture` is the host's, and it is canonical.** The governed value is
`x86-64`. It is not `uname -m`'s `x86_64`, not `dpkg`'s `amd64`, and it is
emphatically not an OCI image's `amd64`, which describes a container image and
belongs to a different authority. Raw observations are normalised **once**, at
the boundary where an operator constructs verified evidence, and never inside a
comparison — a comparison that normalised its inputs would be deciding what a
governed record meant at the moment it was read.

Governed by:
  ``platform-model/schemas/capability-host.schema.yaml``
  ``docs/decisions/ADR-0012-distributed-capability-fabric.md`` §heterogeneous
"""

from __future__ import annotations

from typing import Any, Mapping

# --- the governed vocabulary ------------------------------------------------
#
# CAPACITY  a quantity: satisfied when what is available is at least what is
#           required. Positive integers only.
# TOKEN     an identity from a closed set: satisfied only by the same token.
# OPAQUE    an identity from no set anybody may order or interpret: satisfied
#           only by the same string. Deliberately not comparable.
CAPACITY = "capacity"
TOKEN = "token"
OPAQUE = "opaque"

ARCHITECTURE_VALUES = frozenset({"x86-64"})
ACCELERATOR_CLASSES = frozenset({
    "none", "integrated-gpu", "discrete-gpu", "dedicated-accelerator",
    "remote-service"})

RESOURCE_FIELDS: dict[str, tuple[str, frozenset | None]] = {
    "architecture": (TOKEN, ARCHITECTURE_VALUES),
    "accelerator_class": (TOKEN, ACCELERATOR_CLASSES),
    "accelerator_compute_capability": (OPAQUE, None),
    "host_memory_mb": (CAPACITY, None),
    "host_cpu_cores": (CAPACITY, None),
    "accelerator_memory_mb": (CAPACITY, None),
}

# Raw host observations this increment accepts, and the governed token each
# normalises to. `amd64` appears here because `dpkg --print-architecture`
# reports it for this ISA — it is a HOST observation from a host tool. The
# identical string arriving from an OCI image manifest is a different plane's
# fact and never reaches this table, because the caller must say which
# observation it is holding.
HOST_ARCHITECTURE_OBSERVATIONS: dict[str, str] = {
    "x86_64": "x86-64",
    "amd64": "x86-64",
    "x86-64": "x86-64",
}

REASON_UNKNOWN_DIMENSION = "resource-dimension-not-governed"
REASON_MALFORMED_VALUE = "resource-value-malformed"
REASON_UNKNOWN_OBSERVATION = "host-architecture-observation-not-recognised"


def _capacity(value: Any) -> bool:
    """A positive integer, and not a bool wearing one's clothes.

    `bool` is an `int` in Python, so `True` would otherwise pass as one core.
    Zero is refused for the same reason a machine with no accelerator omits the
    dimension rather than declaring nought of it: a capacity of zero is not a
    capacity, and a requirement of zero is a requirement of nothing.
    """
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate_resource_map(value: Any) -> str | None:
    """`None` if this is a governed resource mapping, else why it is not.

    Used for requirements and for profiles alike: both are expressed in the one
    vocabulary, which is the property that makes containment meaningful rather
    than a comparison of two differently-shaped dictionaries.
    """
    if not isinstance(value, Mapping):
        return REASON_MALFORMED_VALUE
    for name, entry in value.items():
        if name not in RESOURCE_FIELDS:
            return REASON_UNKNOWN_DIMENSION
        kind, allowed = RESOURCE_FIELDS[name]
        if kind is CAPACITY:
            if not _capacity(entry):
                return REASON_MALFORMED_VALUE
        elif not isinstance(entry, str) or not entry:
            return REASON_MALFORMED_VALUE
        elif allowed is not None and entry not in allowed:
            return REASON_MALFORMED_VALUE
    return None


def satisfies(required: Any, available: Any) -> bool:
    """Whether ``available`` satisfies every dimension ``required`` names.

    The single containment rule for this plane, and the only one. Read it three
    ways, because three callers need exactly this and nothing else:

    * a package's requirements against a host's **verified** profile;
    * a contract's requirements against a **package's** requirements, which is
      how "a package may never declare less than its contract" is expressed;
    * an advertisement's claim against the verified profile, which is how a
      self-report is prevented from enlarging what an operator attested.

    A dimension `available` does not name is not satisfied. Silence is not a
    capability, and the alternative — treating an absent dimension as
    permissive — is how a workload lands on a machine nobody measured.
    """
    if not isinstance(required, Mapping) or not isinstance(available, Mapping):
        return False
    for name, want in required.items():
        if name not in RESOURCE_FIELDS or name not in available:
            return False
        have = available[name]
        kind, _ = RESOURCE_FIELDS[name]
        if kind is CAPACITY:
            if not _capacity(want) or not _capacity(have) or have < want:
                return False
        elif have != want:
            return False
    return True


def normalise_host_architecture(observation: Any) -> str | None:
    """The governed token for one raw **host** architecture observation.

    Takes what a host tool reported — `uname -m`, `lscpu`, `dpkg
    --print-architecture` — and returns the governed value, or `None` when the
    observation is not one this increment recognises.

    Deliberately narrow, and deliberately named for the plane it serves. There
    is no `normalise_architecture` here that would accept any string from
    anywhere, because the whole distinction being protected is that an `amd64`
    read off a container image is not a fact about this machine. A caller
    holding image metadata cannot reach this function without lying about what
    it is holding.

    Nothing in Fabric calls this during comparison. It exists for the operator
    ceremony that constructs verified host evidence, so the normalisation
    happens once, where it can be recorded alongside the raw observation it
    came from.
    """
    if not isinstance(observation, str):
        return None
    return HOST_ARCHITECTURE_OBSERVATIONS.get(observation.strip())
