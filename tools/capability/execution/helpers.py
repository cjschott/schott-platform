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
# Digests are of the reviewed repository sources these objects are installed
# from, and the mapping below names which source is which. Root executes these
# by pathname, so a rename here would be a rename there -- which is why the
# mapping is data rather than a guess, and why the test holds the digests to
# the sources they name. A declaration that could drift from its own sources
# would be a compatibility check reporting agreement with itself.
HELPER_SOURCES: dict[str, str] = {
    "/usr/libexec/kyri-exec-transition":
        "provisioning/execution/kyri-exec-transition-entrypoint.py",
    "/usr/libexec/kyri-exec-worker.py":
        "provisioning/execution/kyri-exec-worker.py",
    "/usr/libexec/kyri-exec-reconcile":
        "provisioning/execution/kyri-exec-reconcile-entrypoint.py",
    "/usr/libexec/kyri-exec-reconcile-worker.py":
        "provisioning/execution/kyri-exec-reconcile-worker.py",
}

REQUIRED_HELPERS: tuple[RequiredHelper, ...] = (
    RequiredHelper(
        path="/usr/libexec/kyri-exec-transition",
        digest="0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1",
        purpose="the privileged launch entrypoint the supervisor starts"),
    RequiredHelper(
        path="/usr/libexec/kyri-exec-worker.py",
        digest="6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd",
        purpose="the worker the launch transition execs"),
    RequiredHelper(
        path="/usr/libexec/kyri-exec-reconcile",
        digest="2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77",
        purpose="the privileged reconciliation entrypoint disposal proves through"),
    RequiredHelper(
        path="/usr/libexec/kyri-exec-reconcile-worker.py",
        digest="b0e3c047f689ad5d1e4ef2979f771ca4acdbc80cf8109df8a7cf59a790eb8d2a",
        purpose="the unprivileged half reconciliation execs"),
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
