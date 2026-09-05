#!/usr/bin/env python3
"""Privileged per-`CINV` output quota establishment. **Not installed by anything.**

This file is the source of one fixed privileged operation. Installing it, owning
it as root, and writing the sudoers drop-in that reaches it are gates G2 and G3,
and none of that happens here or in any test.

**One ioctl, and nothing else.** The operation sets a project ID and the
inheritance flag on one already-open directory descriptor, using
`FS_IOC_FSSETXATTR` through `fcntl.ioctl` and `struct`. There is no
`xfs_quota`, no `quotactl`, no `ctypes`, no subprocess, and no shell. That was
the point of choosing this mechanism: widening the root helper into an
external-command runner would have cost more than the quota is worth.

**The limits are provisioned, not set here.** `xfs_quota -x -c 'limit -p -d
bhard=… ihard=…'` establishes the *default* project limits once, at G4, by an
operator. Every project that inherits them therefore needs no runtime authority
to set a limit at all — the runtime only says *which project this tree belongs
to*, and the filesystem already knows what a project may have. Removing
`quotactl` from the runtime path this way is what keeps the privileged surface
to a single ioctl.

**Nothing is supplied by a caller.** Not a path, not a project ID, not a limit.
The argument is one `CINV`, validated by the same grammar the rest of the
runtime uses; the directory is reached descriptor-relative from a compiled-in
root; and the project ID is derived. There is no parameter for a caller to aim.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §34.
"""

from __future__ import annotations

import fcntl
import os
import struct
import sys

# Compiled in, exactly as the transition helper's roots are. A pathname that
# arrived as an argument would be the whole attack.
HANDOFF_ROOT = "/data/kyri/capability-handoff"
QUOTA_SUBTREE = "out"

PROJECT_ID_BASE = 1_000_000

# include/uapi/linux/fs.h. FS_IOC_FSGETXATTR/FSSETXATTR carry `struct fsxattr`:
# u32 fsx_xflags, u32 fsx_extsize, u32 fsx_nextents, u32 fsx_projid,
# u32 fsx_cowextsize, then 8 reserved bytes.
FS_IOC_FSGETXATTR = 0x801C581F
FS_IOC_FSSETXATTR = 0x401C5820
FSXATTR_FORMAT = "=IIIII8s"
FS_XFLAG_PROJINHERIT = 0x00000200

_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

# The handoff parent is `0711` by design: traverse to a named child, no
# enumeration of siblings. It is opened here only to anchor the `openat` below,
# and `openat` needs search rather than read, so it asks for `O_PATH`.
#
# This one runs as root -- `quota.apply` is called before `drop_privilege` --
# so `O_RDONLY` succeeded here where the same flags refused in the worker after
# the drop. It was latent rather than broken. It is corrected anyway: the
# descriptor's use is identical, and a latent instance of a defect that has
# already cost two checkpoints should not be left waiting for the ordering to
# change. The `CINV` child below keeps `_DIR_FLAGS` -- it is `0555`, it grants
# read, and it is read.
_ANCHOR_FLAGS = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_DIGITS = frozenset("0123456789")

USAGE = "usage: kyri-exec-quota CINV-nnnnnn"


def validate_cinv(value: str) -> str:
    """The one accepted argument shape, checked before it is used."""
    if (not isinstance(value, str) or len(value) != 11
            or not value.startswith("CINV-") or set(value[5:]) - _DIGITS):
        raise SystemExit(f"{USAGE}\nnot a CINV identity")
    return value


def project_id(cinv: str) -> int:
    """Derived, never allocated, and never zero.

    Must agree exactly with ``tools/capability/execution/quota.py``; the two are
    kept identical rather than one importing the other, because this file runs
    as root and importing the runtime package would give root a reason to read
    from a tree the runtime identity can write.
    """
    derived = PROJECT_ID_BASE + int(cinv[5:])
    if derived <= PROJECT_ID_BASE or derived > PROJECT_ID_BASE + 999_999:
        raise SystemExit("the derived project ID is outside the reserved range")
    return derived


class QuotaRefused(Exception):
    """The project could not be established, or could not be proven."""


def decide(current_xflags: int, current_projid: int, project: int) -> int:
    """The xflags to write, or refuse. Pure, so the decision is testable.

    An existing assignment to a *different* project is refused rather than
    overwritten: the tree would already be accounted somewhere, and taking it
    over would silently move somebody else's usage onto this invocation.
    """
    if current_projid not in (0, project):
        raise QuotaRefused(
            f"the directory already carries project {current_projid}")
    return current_xflags | FS_XFLAG_PROJINHERIT


def confirm(original_xflags: int, observed_xflags: int, observed_projid: int,
            project: int) -> None:
    """Verify the read-back, or refuse. Pure, and deliberately strict.

    A successful setter call is not evidence. What is checked is what the
    filesystem now reports: the exact project, inheritance actually set, and
    every unrelated flag exactly as it was — a setter that cleared something
    else would have quietly changed the file's behaviour.
    """
    if observed_projid != project:
        raise QuotaRefused(
            f"the project read back as {observed_projid}, expected {project}")
    if not observed_xflags & FS_XFLAG_PROJINHERIT:
        raise QuotaRefused("inheritance did not read back as set")
    if observed_xflags & ~FS_XFLAG_PROJINHERIT != original_xflags & ~FS_XFLAG_PROJINHERIT:
        raise QuotaRefused("unrelated inode flags were altered")


def _get(descriptor: int) -> tuple[int, ...]:
    packed = fcntl.ioctl(descriptor, FS_IOC_FSGETXATTR,
                         struct.pack(FSXATTR_FORMAT, 0, 0, 0, 0, 0, b"\0" * 8))
    return struct.unpack(FSXATTR_FORMAT, packed)


def establish(descriptor: int, project: int) -> None:
    """Set the project and inheritance on one open directory, then prove it.

    Read, modify, write, read again. Inheritance is what makes this one-shot:
    the directory is empty now, and the filesystem accounts everything created
    beneath it afterwards, so nothing walks the tree and there is no second
    privileged pass to get wrong.
    """
    xflags, extsize, nextents, projid, cowextsize, pad = _get(descriptor)
    updated = decide(xflags, projid, project)
    fcntl.ioctl(descriptor, FS_IOC_FSSETXATTR,
                struct.pack(FSXATTR_FORMAT, updated, extsize, nextents,
                            project, cowextsize, pad))
    seen_xflags, _, _, seen_projid, _, _ = _get(descriptor)
    confirm(xflags, seen_xflags, seen_projid, project)


def apply(cinv: str) -> int:
    """Establish and prove the project for one `CINV`, returning its ID.

    The descriptor walk is deliberate: the handoff root is opened without
    following a link, then the `CINV` directory relative to it, then `out`
    relative to that. No pathname is assembled and re-resolved, so replacing a
    component after a check redirects nothing. `O_DIRECTORY` and `O_NOFOLLOW`
    are what refuse an `out` that is missing, a symlink, or not a directory.
    """
    identity = validate_cinv(cinv)
    project = project_id(identity)

    root = os.open(HANDOFF_ROOT, _ANCHOR_FLAGS)
    try:
        invocation = os.open(identity, _DIR_FLAGS, dir_fd=root)
    finally:
        os.close(root)
    try:
        leaf = os.open(QUOTA_SUBTREE, _DIR_FLAGS, dir_fd=invocation)
    finally:
        os.close(invocation)
    try:
        establish(leaf, project)
    finally:
        os.close(leaf)
    return project


def main(argv: list[str]) -> int:
    """Establish the project on exactly one `CINV`'s output leaf.

    Every failure below is raised before any credential drop, so a caller can
    state that nothing executed.
    """
    if len(argv) != 2:
        raise SystemExit(USAGE)
    apply(validate_cinv(argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
