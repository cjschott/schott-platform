#!/usr/bin/python3 -IB
"""`kyri-health-ingest`: ingest one approved Health envelope.

ENG-0006-H18. Installed as `/usr/libexec/kyri-health-ingest`, `root:root
0555`, by `provisioning/health/install-health-runtime.sh`. Runs as the
`kyri-health` service identity, which owns the store:

    sudo -u kyri-health /usr/libexec/kyri-health-ingest <request_id>

One argument and no path: the statement is `<request_id>.json` in the
root-owned approval directory, opened by `tools.health.ingest` through
`trusted_source` with trusted UID 0. The process must be exactly
`kyri-health`: its effective UID and GID, and no other group.

Output: the `IngestResult` as one JSON line on stdout; one line to the
journal. Exit 0 accepted or replayed, 1 refused, 2 the helper or the store
refused, 3 committed-unverified (the record exists and freezes its subject).
"""

from __future__ import annotations

import json
import os
import pwd
import stat
import sys
import syslog
from typing import NoReturn

HELPER = "kyri-health-ingest"

# Compiled in. Every other way of arriving at these values is something a
# caller can influence; the installer pins this file's bytes.
LIBRARY_ROOT = "/usr/lib/kyri/health"
LIBRARY_OWNER = 0
# The library's ancestry is checked up to and including this directory.
ANCESTRY_ROOT = "/"
SERVICE_USER = "kyri-health"
STORE_ROOT = "/var/lib/kyri/health"                  # prod-path-reference
APPROVAL_ROOT = "/var/lib/kyri/health-approvals"     # prod-path-reference
# Every approval statement is root's. The service identity is never root, so
# the own-UID fixture opt-in is never needed and is compiled off.
TRUSTED_UID = 0
ALLOW_OWN_UID_FIXTURE = False

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


def _groups() -> list[int]:
    return os.getgroups()


def _require_identity(operator) -> None:
    try:
        account = pwd.getpwnam(SERVICE_USER)
    except KeyError:
        _refuse("identity-absent")
    refusal = operator.identity_refusal(
        expected_uid=account.pw_uid, expected_gid=account.pw_gid,
        euid=os.geteuid(), egid=os.getegid(), groups=_groups())
    if refusal is not None:
        _refuse(refusal)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        _refuse("usage", stage="arguments")
    os.chdir("/")
    operator = _load()
    _require_identity(operator)
    status, result = operator.ingest_command(
        argv[1], store_root=STORE_ROOT, approval_root=APPROVAL_ROOT,
        trusted_uid=TRUSTED_UID, allow_own_uid_fixture=ALLOW_OWN_UID_FIXTURE)
    print(json.dumps(result, sort_keys=True))
    _log(" ".join(f"{key}={result.get(key)}" for key in
                  ("status", "stage", "reason", "envelope_id", "approval_digest")),
         refused=status != 0)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
