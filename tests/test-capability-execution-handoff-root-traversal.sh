#!/usr/bin/env bash
set -Eeuo pipefail

# The handoff root is traverse-only, and the worker must reach its child
# without reading it.
#
# UNPRIVILEGED AND ISOLATED. No sudo, no privileged helper, no Podman, no
# container, no production path. Everything below happens in a throwaway
# fixture owned by the invoking user.
#
# WHAT THIS EXISTS FOR
# ====================
# G11-BB Stage 3 crossed the privileged transition and then died here:
#
#   File "/usr/libexec/kyri-exec-worker.py", line 378, in main
#     handoff_fd = os.open(worker.HANDOFF_ROOT, _DIR_FLAGS)
#   PermissionError: [Errno 13] Permission denied: '/data/kyri/capability-handoff'
#
# `_DIR_FLAGS` is `O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY`, and
# `O_RDONLY` on a directory asks for *read* — the permission the governed mode
# deliberately withholds.
#
# THE MODE IS NOT THE DEFECT
# ==========================
# `0711` on the handoff parent is governed, in three places, and is deliberate:
#
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md §13
#     | /data/kyri/capability-handoff/ | cschott:cschott | 0711 | traverse only |
#     "the worker must traverse to a named child because rootless Podman
#      resolves bind-mount sources as the execution identity, and must not
#      enumerate siblings"
#
#   docs/superpowers/specs/2026-08-11-execution-transition-boundary.md §8.1
#   provisioning/execution/README.md
#     "Create with these owners and modes exactly; none of them inherits a mode
#      by convention."
#
# So production is correct and the worker is wrong. Widening to 0755/0750, or
# changing owner or group, would destroy the no-enumeration property the design
# names — it must not be the fix.
#
# WHAT THE ROOT DESCRIPTOR IS ACTUALLY FOR
# ========================================
# It is only ever a `dir_fd`. Every use is `os.open(name, ..., dir_fd=root_fd)`:
#
#   tools/capability/execution/worker.py:385    verify_handoff
#   tools/capability/execution/worker.py:603    verify_execution
#   tools/capability/execution/snapshot.py:352  materialise
#
# Nothing enumerates it — the `scandir` calls in `snapshot.py` walk the package
# subtree and the snapshot directory, never the handoff root. `openat` needs
# only search permission on the directory, which `0711` grants, so an `O_PATH`
# descriptor is sufficient and is what the governed mode is shaped for.
#
# THE TWO PROPERTIES THIS SUITE HOLDS
# ===================================
#   * A traverse-only parent REFUSES the read-mode open. This is the production
#     failure, reproduced exactly.
#   * An `O_PATH` parent reaches the named child AND still cannot be
#     enumerated. The fix must preserve the second half; a fix that made the
#     parent readable would pass the first assertion and destroy the property.
#
# Ownership differs from production by necessity: this suite may not become
# uid 999. The permission *semantics* are identical — the fixture removes read
# from the owner (`0111`) exactly as `0711` removes it from `kyri-capability`,
# which reaches the directory as "other".

WORK="$(mktemp -d)"
cleanup() { chmod -R u+rwX "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"; }
trap cleanup EXIT

ROOT="${WORK}/capability-handoff"
CINV="CINV-000042"

mkdir -p "${ROOT}/${CINV}/package" "${ROOT}/${CINV}/out"
printf 'payload\n'  > "${ROOT}/${CINV}/payload"
printf 'profile\n'  > "${ROOT}/${CINV}/profile"
printf 'entry\n'    > "${ROOT}/${CINV}/package/main.py"

# The production shape, mode for mode.
chmod 0444 "${ROOT}/${CINV}/payload" "${ROOT}/${CINV}/profile" \
           "${ROOT}/${CINV}/package/main.py"
chmod 0555 "${ROOT}/${CINV}/package" "${ROOT}/${CINV}"
chmod 0700 "${ROOT}/${CINV}/out"
chmod 0111 "${ROOT}"

FIXTURE_ROOT="${ROOT}" FIXTURE_CINV="${CINV}" python3 - <<'PY'
import os
import sys

ROOT = os.environ["FIXTURE_ROOT"]
CINV = os.environ["FIXTURE_CINV"]

# Copied from provisioning/execution/kyri-exec-worker.py:78 verbatim.
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

failures = []


def check(label, condition):
    print(f"{'ok  ' if condition else 'FAIL'}  {label}")
    if not condition:
        failures.append(label)


mode = os.stat(ROOT).st_mode & 0o777
check(f"the fixture parent is traverse-only ({mode:04o})", mode == 0o111)

# --- 1. the production failure, reproduced -------------------------------
#
# This is the assertion that fails against the installed worker's own flags.
refused = None
try:
    fd = os.open(ROOT, _DIR_FLAGS)
    os.close(fd)
except PermissionError as error:
    refused = error
check("O_RDONLY|O_DIRECTORY on a traverse-only parent is refused",
      refused is not None)

# --- 2. O_PATH reaches the named child -----------------------------------
#
# What the governed mode is shaped for: traverse to a named child.
root_fd = None
try:
    root_fd = os.open(ROOT, os.O_PATH | os.O_CLOEXEC | os.O_NOFOLLOW
                      | os.O_DIRECTORY)
except OSError as error:
    check(f"O_PATH open of a traverse-only parent succeeds ({error})", False)

if root_fd is not None:
    try:
        check("O_PATH open of a traverse-only parent succeeds", True)

        child = None
        try:
            child = os.open(CINV, _DIR_FLAGS, dir_fd=root_fd)
        except OSError as error:
            check(f"openat(root_fd, CINV) reaches the child ({error})", False)

        if child is not None:
            try:
                names = sorted(os.listdir(child))
                check("openat(root_fd, CINV) reaches the child", True)
                check("the child is readable, as 0555 intends",
                      names == ["out", "package", "payload", "profile"])
            finally:
                os.close(child)

        # --- 3. and the parent still cannot be enumerated ----------------
        #
        # The half a permissive fix would silently destroy. An O_PATH
        # descriptor cannot be read at all, so this holds by construction
        # rather than by permission.
        enumerated = None
        try:
            enumerated = os.listdir(root_fd)
        except OSError:
            pass
        check("the parent still cannot be enumerated", enumerated is None)
    finally:
        os.close(root_fd)

print()
if failures:
    print(f"{len(failures)} assertion(s) failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("handoff root traversal: all assertions hold")
PY
