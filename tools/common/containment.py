"""One answer to one question: is this name inside that directory?

Four call sites carried the same six lines — resolve both sides, refuse
anything that is not strictly beneath the approved directory. Six lines are
easy to copy and easy to copy *almost* correctly, and the failure is silent:
a containment check that accepts one path too many looks exactly like one that
does not, until someone supplies the path.

**Containment is decided after full resolution.** `..` is not stripped, it is
resolved; a symlink is not inspected, it is followed and then judged by where
it actually lands. Comparing before resolution would be comparing the name a
caller chose rather than the file it names.

**Strictly beneath, never equal.** The approved directory itself is not a file
inside the approved directory, and a caller asking for `.` is asking for
something it was not offered.

**The comparison is over path components, never over text.** `/approved` is not
a prefix of `/approvedbar` here, though it is as a string — which is the bug
this shape exists to avoid.

**Existence is not containment.** A path that is not there is still answered,
because whether an absent file is an error depends on what the caller wanted
it for. That decision, the error type, and the message all stay with the
caller, along with whether `~` in the approved directory means anything: this
answers containment and nothing else.

Nothing here touches the filesystem. It reads paths; it creates, changes, and
removes nothing, including the approved directory itself.
"""

from __future__ import annotations

from pathlib import Path


def contained_path(approved_directory: Path | str, name: str) -> Path | None:
    """The resolved path of `name` inside `approved_directory`, or `None`.

    `None` means refused: the name resolves to the directory itself, or beside
    it, or outside it. A returned path is the fully resolved one, so a caller
    opens the file that was checked rather than the name that was offered.
    """
    approved = Path(approved_directory).resolve(strict=False)
    candidate = (approved / name).resolve(strict=False)
    if candidate == approved or approved not in candidate.parents:
        return None
    return candidate
