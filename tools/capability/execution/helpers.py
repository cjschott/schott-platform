"""Which privileged helper bytes this runtime supervises through.

**Generation 13 must not be able to report execution-ready against a stale
helper.** The runtime and the helpers are separate deployment authorities
installed by separate ceremonies, and G11-AI already found a host carrying half
of one commit: the verification surface from `16f285e` was installed and
byte-exact while the transition modules from the same commit were not, and the
consequence was live. Deployment order does not solve that on its own, because
order is a thing an operator does and this is a thing a machine can check.

**So the runtime declares what it was built against.** Each object below is a
privileged surface this runtime's supervision path depends on, with the exact
bytes the runtime expects to find. `compatibility` reads what is installed and
reports each object as one of four states — nothing is inferred and nothing is
averaged into a single opinion.

**It grants nothing and installs nothing.** Reading a world-readable executable
is not elevation, and this module cannot invoke, replace or repair anything it
looks at.

**The declaration is checked against the repository, not trusted.** A digest
table that could drift from the sources it names would be a compatibility check
that reports agreement with itself, so
`tests/test-capability-execution-supervision.sh` holds the two together.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
from typing import Any

# What a required helper object turned out to be.
STATE_CURRENT = "current"
STATE_STALE = "stale"
STATE_ABSENT = "absent"
STATE_UNREADABLE = "unreadable"

COMPATIBLE = "compatible"
INCOMPATIBLE = "incompatible"

_READ_FLAGS = os.O_RDONLY | os.O_CLOEXEC
MAXIMUM_HELPER_BYTES = 1024 * 1024


@dataclasses.dataclass(frozen=True)
class RequiredHelper:
    """One privileged object, and the bytes this runtime expects of it."""

    path: str
    digest: str
    purpose: str


@dataclasses.dataclass(frozen=True)
class HelperState:
    """What was found where a required helper should be."""

    path: str
    state: str
    expected: str
    observed: Any
    purpose: str


@dataclasses.dataclass(frozen=True)
class Compatibility:
    """Whether this runtime may supervise through what is installed."""

    verdict: str
    helpers: tuple[HelperState, ...]

    @property
    def compatible(self) -> bool:
        return self.verdict == COMPATIBLE

    @property
    def blocking(self) -> tuple[HelperState, ...]:
        return tuple(helper for helper in self.helpers
                     if helper.state != STATE_CURRENT)


# The privileged surface a supervised execution reaches, and nothing else. The
# verification helper is deliberately absent: it is a governed alternative
# entrypoint, not something supervision depends on.
#
# **The entrypoints are not the whole surface, and this table once said they
# were.** Each entrypoint names the privileged modules it will load in its own
# `POLICY_MODULE`, `ACTION_MODULE`, `QUOTA_MODULE` and `RECONCILE_MODULE`
# constants, and root loads them BY NAME after it has already elevated. G11-AX
# drove the partial-deployment matrix this module exists to defeat and found
# seven mixed states reported `compatible`, because only the four executables
# were declared and none of the modules underneath them were:
#
#   * new entrypoints beside a stale `kyri_exec_transition.py` -- the G11-AI
#     split-generation defect, surviving inside the check written to prevent it;
#   * a new transition beside a stale `kyri_exec_transition_action.py`, which is
#     the layer that performs the credential drop;
#   * a reconcile entrypoint installed without `kyri_exec_reconcile.py`, where
#     root elevates and the worker then fails to import the module it execs for.
#
# So the modules are declared too. `kyri_exec_podman` is deliberately not here:
# it is a Generation-13 runtime object and the generation ceremony keeps it
# coherent, which the supervision suite checks against that ceremony's matrix
# rather than against a list kept here.
#
# Digests are of the reviewed repository sources these objects are installed
# from, and the mapping below names which source is which. Root executes and
# imports these by pathname, so a rename here would be a rename there -- which
# is why the mapping is data rather than a guess, and why the test holds the
# digests to the sources they name. A declaration that could drift from its own
# sources would be a compatibility check reporting agreement with itself.
HELPER_SOURCES: dict[str, str] = {
    "/usr/libexec/kyri-exec-transition":
        "provisioning/execution/kyri-exec-transition-entrypoint.py",
    "/usr/libexec/kyri-exec-worker.py":
        "provisioning/execution/kyri-exec-worker.py",
    "/usr/libexec/kyri-exec-reconcile":
        "provisioning/execution/kyri-exec-reconcile-entrypoint.py",
    "/usr/libexec/kyri-exec-reconcile-worker.py":
        "provisioning/execution/kyri-exec-reconcile-worker.py",
    "/usr/lib/kyri/python/kyri_exec_transition.py":
        "provisioning/execution/kyri-exec-transition.py",
    "/usr/lib/kyri/python/kyri_exec_transition_action.py":
        "provisioning/execution/kyri-exec-transition-action.py",
    "/usr/lib/kyri/python/kyri_exec_reconcile.py":
        "provisioning/execution/kyri-exec-reconcile.py",
    "/usr/lib/kyri/python/kyri_exec_quota.py":
        "provisioning/execution/kyri-exec-quota.py",
}

REQUIRED_HELPERS: tuple[RequiredHelper, ...] = (
    RequiredHelper(
        path="/usr/libexec/kyri-exec-transition",
        digest="0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1",
        purpose="the privileged launch entrypoint the supervisor starts"),
    RequiredHelper(
        path="/usr/libexec/kyri-exec-worker.py",
        digest="2d320630aca559c747522bb528f87172e747f30a182db0fec70e31eca272ddf5",
        purpose="the worker the launch transition execs"),
    RequiredHelper(
        path="/usr/libexec/kyri-exec-reconcile",
        digest="2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77",
        purpose="the privileged reconciliation entrypoint disposal proves through"),
    RequiredHelper(
        path="/usr/libexec/kyri-exec-reconcile-worker.py",
        digest="b0e3c047f689ad5d1e4ef2979f771ca4acdbc80cf8109df8a7cf59a790eb8d2a",
        purpose="the unprivileged half reconciliation execs"),
    RequiredHelper(
        path="/usr/lib/kyri/python/kyri_exec_transition.py",
        digest="de264c6490e08f6b7dc5f0bcddd15ffdde50278c183161fba04bf4cf1440f5a6",
        purpose="the policy module the launch and reconcile entrypoints load"),
    RequiredHelper(
        path="/usr/lib/kyri/python/kyri_exec_transition_action.py",
        digest="b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315",
        purpose="the action layer that performs the credential drop"),
    RequiredHelper(
        path="/usr/lib/kyri/python/kyri_exec_reconcile.py",
        digest="29175d5a71759336cc869007c83f0c13cb093023ea4bd77344b4f62cd4275a46",
        purpose="the reconciliation implementation the reconcile worker execs for"),
    RequiredHelper(
        path="/usr/lib/kyri/python/kyri_exec_quota.py",
        digest="54a9b15c6c6e3b785218d75c91b896f0723d3bf2051ebfca1351c84aa9855ca7",
        purpose="the quota module the launch entrypoint loads"),
)


def _digest_of(path: str) -> Any:
    """The installed object's digest, or nothing if it cannot be read.

    Bounded, and read through a descriptor rather than by name twice. An
    object too large to be one of these is not one of these.
    """
    try:
        handle = os.open(path, _READ_FLAGS)
    except OSError:
        return None
    try:
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(handle, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > MAXIMUM_HELPER_BYTES:
                return None
            digest.update(chunk)
    except OSError:
        return None
    finally:
        os.close(handle)
    return digest.hexdigest()


def compatibility(required: Any = REQUIRED_HELPERS) -> Compatibility:
    """What is installed where this runtime's helpers should be.

    Four states rather than a boolean per object, because an operator fixing
    this needs to know which problem they have: a helper that is absent needs
    installing, one that is stale needs the ceremony re-run, and one that is
    unreadable is a different fault entirely.

    Compatible means every required object is present and byte-exact. There is
    no partial credit: a supervision path is only as current as the object in it
    that is furthest behind.
    """
    states: list[HelperState] = []
    for helper in required:
        observed = _digest_of(helper.path)
        if observed is None:
            state = STATE_ABSENT if not os.path.exists(helper.path) \
                else STATE_UNREADABLE
        elif observed == helper.digest:
            state = STATE_CURRENT
        else:
            state = STATE_STALE
        states.append(HelperState(path=helper.path, state=state,
                                  expected=helper.digest, observed=observed,
                                  purpose=helper.purpose))
    verdict = COMPATIBLE if all(s.state == STATE_CURRENT for s in states) \
        else INCOMPATIBLE
    return Compatibility(verdict=verdict, helpers=tuple(states))
