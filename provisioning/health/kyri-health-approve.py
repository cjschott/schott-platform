#!/usr/bin/python3 -IB
"""`kyri-health-approve`: publish one reviewed Health approval statement.

ENG-0006-H18. Installed as `/usr/libexec/kyri-health-approve`, `root:root
0555`, by `provisioning/health/install-health-runtime.sh`. Run by the operator,
from a login session that hosts no agent, under their own password `sudo`. No
sudoers rule names it.

    sha256sum candidate.json
    sudo /usr/libexec/kyri-health-approve <request_id> <sha256> < candidate.json

It refuses without a controlling terminal and when stdin is a terminal. It
reads the candidate once, bounded, and hands it to
`tools.health.operator.publish_statement`, which refuses a digest other than
the one given, any statement ingestion would refuse before the store, and any
confirmation other than the digest's first twelve hex digits typed on
`/dev/tty`. It never replaces a published statement and never opens the
Health store.

Root is observed, not asserted: the effective UID must be 0.

Output: one JSON line on stdout; one line to the journal. Exit 0 when the
statement is published (or already published, byte-identical), 1 when it is
refused, 2 when the helper itself refuses.
"""

from __future__ import annotations

import dataclasses
import json
import os
import stat
import sys
import syslog
from typing import NoReturn

HELPER = "kyri-health-approve"

# Compiled in. Every other way of arriving at these values is something a
# caller can influence; the installer pins this file's bytes.
LIBRARY_ROOT = "/usr/lib/kyri/health"
LIBRARY_OWNER = 0
# The library's ancestry is checked up to and including this directory.
ANCESTRY_ROOT = "/"
APPROVAL_ROOT = "/var/lib/kyri/health-approvals"     # prod-path-reference
# The publisher is the trusted UID: a statement root did not create is one
# ingestion refuses.
TRUSTED_UID = 0
TTY = "/dev/tty"

# --- bootstrap: identical in all three Health helpers ------------------------
#
# Root-owned code only. The library is imported from LIBRARY_ROOT and from
# nowhere else, after every ancestor of it and every object beneath it has
# been checked to be a real directory or regular file owned by LIBRARY_OWNER
# and writable by no one else. `-I` already keeps the working directory, the
# PYTHON* variables and the user site off the search path, and `-B` writes no
# bytecode into the tree being checked.


def _refuse(reason: str, stage: str = "helper") -> NoReturn:
    print(json.dumps({"status": "refused", "stage": stage, "reason": reason},
                     sort_keys=True))
    _log(f"refused stage={stage} reason={reason}", refused=True)
    sys.exit(2)


def _log(message: str, *, refused: bool = False) -> None:
    syslog.openlog(HELPER, 0, syslog.LOG_USER)
    syslog.syslog(syslog.LOG_WARNING if refused else syslog.LOG_NOTICE, message)
    syslog.closelog()


def _trusted(path: str, *, directory: bool) -> bool:
    try:
        entry = os.lstat(path)
    except OSError:
        return False
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    return kind(entry.st_mode) and entry.st_uid == LIBRARY_OWNER \
        and not entry.st_mode & (stat.S_IWGRP | stat.S_IWOTH)


def _trusted_library() -> bool:
    path = LIBRARY_ROOT
    while True:
        if not _trusted(path, directory=True):
            return False
        if path == ANCESTRY_ROOT or path == os.path.dirname(path):
            break
        path = os.path.dirname(path)
    for here, directories, files in os.walk(LIBRARY_ROOT, followlinks=False):
        for name in directories:
            if not _trusted(os.path.join(here, name), directory=True):
                return False
        for name in files:
            if not _trusted(os.path.join(here, name), directory=False):
                return False
    return True


def _load():
    """`tools.health.operator` from the installed library, or refuse."""
    if not _trusted_library():
        _refuse("library-untrusted")
    sys.dont_write_bytecode = True
    sys.path.insert(0, LIBRARY_ROOT)
    try:
        import tools.health.operator as operator
    except ImportError:
        _refuse("library-unimportable")
    boundary = os.path.realpath(LIBRARY_ROOT) + os.sep
    for module in ("tools", "tools.common", "tools.health", "tools.health.operator",
                   "tools.health.ingest", "tools.health.store"):
        origin = getattr(sys.modules.get(module), "__file__", None) or ""
        if not os.path.realpath(origin).startswith(boundary):
            _refuse("library-outside-root")
    return operator

# --- end bootstrap -----------------------------------------------------------


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        _refuse("usage", stage="arguments")
    if os.geteuid() != TRUSTED_UID:
        _refuse("not-root")
    os.chdir("/")
    operator = _load()
    try:
        terminal = open(TTY, "r+b", buffering=0)
    except OSError:
        _refuse("no-controlling-terminal")
    if os.isatty(0):
        _refuse("candidate-not-redirected")
    raw = sys.stdin.buffer.read(operator.MAXIMUM_STATEMENT_BYTES + 1)

    def confirm(rendered: str) -> str:
        terminal.write(rendered.encode("utf-8"))
        terminal.write(f"type the first {operator.CONFIRMATION_DIGITS} hex digits "
                       "of the digest to publish: ".encode("ascii"))
        return terminal.readline().decode("utf-8", "replace")

    with terminal:
        result = operator.publish_statement(
            raw, request_id=argv[1], expected_sha256=argv[2],
            approval_root=APPROVAL_ROOT, trusted_uid=TRUSTED_UID, confirm=confirm)
    print(json.dumps(dataclasses.asdict(result), sort_keys=True))
    refused = result.status == "refused"
    _log(f"request={argv[1]} status={result.status} reason={result.reason} "
         f"digest={result.digest} by={os.environ.get('SUDO_USER', '-')}",
         refused=refused)
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
