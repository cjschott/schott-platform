"""Per-invocation output containment policy for ENG-0005.

**Policy only. Nothing here sets a quota.** Establishing one needs root, and the
privileged operation lives in `provisioning/execution/kyri-exec-quota.py`, which
nothing installs. This module holds the two things that must be identical on
both sides of that boundary — how a project identity is derived and what limits
it carries — so the privileged side computes nothing of its own.

**The identity is derived, never allocated.** A `CINV` is already unique and
already never reused, so a second allocator would be a second thing to keep
monotonic, to detect rollback in, and to fail closed on. The project ID is a
pure function of the identity: `1_000_000 + n`. Zero is never produced, because
project 0 is the filesystem's default and assigning a tree to it would silently
mean *unlimited* rather than *this limit*.

**The limits are a write-time envelope, not the acceptance policy.** §11 accepts
16 MiB and 256 entries; these bound what a workload may *write* while running,
at twice that. The gap is deliberate: a capability that writes a temporary file
and renames it over its result is doing something ordinary, and a write-time
limit equal to the acceptance limit would fail it for good behaviour. What the
quota prevents is the case §11 cannot — a thirty-second workload consuming
gigabytes or millions of inodes before anything gets to judge its output.

**Scoped to `out/` alone.** Not the handoff tree: §8 permits a package of 64 MiB
and 1,024 entries, so a quota over the whole tree would refuse packages the
package contract already accepted. The writable leaf is the only part an
adversary controls.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §34.
"""

from __future__ import annotations

from typing import Any

from . import state as state_module

# The reserved project-ID range. The base keeps every derived identity clear of
# project 0 and of whatever else on the host may already use low numbers.
PROJECT_ID_BASE = 1_000_000
PROJECT_ID_MINIMUM = PROJECT_ID_BASE + 1
PROJECT_ID_MAXIMUM = PROJECT_ID_BASE + 999_999

# The v1 write-time envelope: twice the §11 acceptance policy.
BLOCK_HARD_BYTES = 32 * 1024 * 1024
INODE_HARD = 512

# The one directory a project may ever be established on, relative to the
# per-`CINV` handoff root. Named here so both sides agree, and so the
# privileged operation has a constant to compare against rather than a
# parameter to trust.
QUOTA_SUBTREE = "out"


class QuotaPolicyError(ValueError):
    """The requested project identity is not one this policy can derive."""


def project_id(cinv: Any) -> int:
    """The XFS project ID for ``cinv``, derived and never allocated.

    The identity is validated with the same grammar every other component uses,
    so a value that is not a `CINV` cannot become a number here — which matters
    because this number is the only thing standing between one invocation's
    quota and another's.
    """
    identity = state_module.validate_cinv(cinv)
    derived = PROJECT_ID_BASE + int(identity[5:])
    if not PROJECT_ID_MINIMUM <= derived <= PROJECT_ID_MAXIMUM:
        raise QuotaPolicyError(
            f"{identity} derives a project ID outside the reserved range")
    return derived


def cinv_for(project: Any) -> str:
    """The `CINV` a project ID was derived from, or refuse.

    The inverse exists so an operator reading a quota report can get back to the
    invocation without a lookup table that could disagree with the derivation.
    """
    if not isinstance(project, int) or isinstance(project, bool):
        raise QuotaPolicyError("a project ID must be an integer")
    if not PROJECT_ID_MINIMUM <= project <= PROJECT_ID_MAXIMUM:
        raise QuotaPolicyError(f"{project} is outside the reserved range")
    return f"CINV-{project - PROJECT_ID_BASE:06d}"
