"""What the runtime's own mount sources turn out to be.

**One question, asked of the filesystem.** `ObservedProfile.sockets` records
whether the container was given a socket. Podman reports no such field, so the
only other way to fill it is from the expected profile -- which always says
there are none. Verification would then confirm "no sockets" by consulting the
claim that there are no sockets, which is not evidence about anything. This
module asks the filesystem instead, and the filesystem can answer "socket".

**It lives here rather than in `lifecycle`, and that is deliberate.** The
lifecycle module is held to a clock rule and an ambient-authority rule: it may
name Podman but may not read the environment, the clock, or the filesystem. A
socket check needs `stat`, so putting it there would have meant widening a
security backstop to fit one function. The function moved instead. This module
is the only place in the execution package that looks at a mount source, and
`stat` is the only thing it does.

**Nothing here decides which paths were authorised.** That judgement belongs to
the execution path that materialised them. This reports the *type* of what is
actually at each source the runtime named, and refuses anything it cannot
classify. A source that is not the kind of object the worker left there is a
refusal, not something to resolve.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §12
and §17.
"""

from __future__ import annotations

import os
import stat as stat_module
from typing import Any


class MountEvidenceUnreadable(ValueError):
    """A reported mount source could not be classified.

    Raised rather than answered "not a socket". An unexaminable source is not
    an absent socket, and only one of those is safe to act on.
    """


def observed_sockets(reported_mounts: Any) -> tuple[str, ...]:
    """Which of the runtime's reported mount sources are Unix sockets.

    **No-follow, and no second look.** Each source is examined without
    following symlinks, because a source the worker verified and something
    later replaced with a link is exactly the case where following it would
    report the harmless thing it points at. A symlink is refused outright
    rather than resolved: a source that is not the object the execution path
    left there is a refusal at this layer.

    **Every uncertainty is a refusal.** A missing source, an unreadable one, a
    malformed one, or a type this does not recognise raises rather than being
    skipped past. "I could not tell what that was" must never be delivered as
    "there were no sockets".

    ``tmpfs`` carries no host object, so there is no source to examine. That is
    a property of the mount type rather than a gap, and demanding one would
    refuse the governed configuration.
    """
    found: list[str] = []
    for entry in reported_mounts:
        if not isinstance(entry, dict):
            raise MountEvidenceUnreadable(
                "the runtime reported a mount entry this cannot read")
        if entry.get("Type") == "tmpfs":
            continue
        source = entry.get("Source")
        if not isinstance(source, str) or not source.startswith("/"):
            raise MountEvidenceUnreadable(
                "a reported mount source is not an absolute path")
        try:
            # `stat` with follow_symlinks=False rather than `lstat`: identical
            # semantics, and explicit at the call site about not following.
            info = os.stat(source, follow_symlinks=False)
        except OSError as error:
            raise MountEvidenceUnreadable(
                f"a reported mount source could not be examined: {error}"
            ) from None
        mode = info.st_mode
        if stat_module.S_ISSOCK(mode):
            found.append(source)
        elif stat_module.S_ISLNK(mode):
            raise MountEvidenceUnreadable(
                "a reported mount source is a symbolic link; it is not the "
                "object the execution path verified")
        elif not (stat_module.S_ISREG(mode) or stat_module.S_ISDIR(mode)):
            raise MountEvidenceUnreadable(
                "a reported mount source is neither a regular file nor a "
                "directory")
    return tuple(found)


__all__ = ["MountEvidenceUnreadable", "observed_sockets"]
