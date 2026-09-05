#!/usr/bin/env bash
set -Eeuo pipefail

# Governed roots are traversal anchors, and a helper refusal must survive.
#
# UNPRIVILEGED AND ISOLATED. No sudo, no privileged helper, no Podman, no
# container, no production path. Fixtures only.
#
# WHAT THIS EXISTS FOR
# ====================
# G11-BB hit the same defect twice, at two different boundaries, and the second
# one cost a whole checkpoint to find because the message that explained it was
# thrown away.
#
#   1. The worker opened /data/kyri/capability-handoff O_RDONLY|O_DIRECTORY and
#      died after the credential drop.       (fixed, own suite)
#   2. The reconcile worker opened /etc/kyri the same way, through
#      `SystemBackend.open_directory`, and died the same way:
#
#        refused: the execution authority directory is unusable:
#        [Errno 13] Permission denied: '/etc/kyri'
#
# Both directories are `0711` BY DESIGN -- traverse to a named child, no
# enumeration of siblings. `/etc/kyri` is `root:root 0711` with
# `execution-identity.json` at `0444`: the file is world-readable, the directory
# is not listable, and that is the shape the deployment intends.
#
# THE SAME AUTHORITY IS READ TWO WAYS, AND ONLY ONE WAS WRONG
# ===========================================================
# `tools/capability/execution/identity.py` opens the *file* by path with
# `O_RDONLY|O_NOFOLLOW|O_CLOEXEC` and needs only traverse -- which is why the
# worker reads the identity happily while the reconcile worker could not.
# `kyri-exec-transition-action.py` opened the *directory* first, to anchor a
# descriptor-relative read. The anchoring is right; asking for read was not.
#
# WHY ONE CHANGE FIXES THREE CALL SITES
# =====================================
# `SystemBackend.open_directory` is the only filesystem seam in the privileged
# backend, and all three of its callers -- the deployment authority read, the
# execution root, the handoff root -- use the descriptor solely as `dir_fd`.
# `_open_invocation` fstats the CHILD, never the root, and nothing in either
# privileged module calls `listdir` or `scandir`. So the seam asks for `O_PATH`.
#
# THE PROPERTIES THIS SUITE HOLDS
# ===============================
#   * A read-mode open of a traverse-only authority directory is refused.
#   * An O_PATH anchor succeeds, and openat reaches the named authority file.
#   * The anchor still cannot enumerate siblings -- the property that makes
#     0711 worth having, and the one a permissive fix would destroy.
#   * A sibling authority file is not discoverable through the anchor without
#     already knowing its name.
#   * The launcher carries a helper's refusal text into its own refusal,
#     bounded, single-line and printable -- and still refuses.

cd "$(dirname "$0")/.."

python3 - <<'PYTEST'
import importlib.util
import os
import shutil
import sys
import tempfile

failures = []


def check(label, condition):
    print(f"{'ok  ' if condition else 'FAIL'}  {label}")
    if not condition:
        failures.append(label)


def load(path, name):
    """Import a hyphenated privileged file by path, as its own module.

    Registered in `sys.modules` before execution because `dataclasses` resolves
    a class's module through it while the decorator runs.
    """
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


work = tempfile.mkdtemp()
try:
    # --- the production shape of /etc/kyri ---------------------------------
    etc = os.path.join(work, "kyri")
    os.makedirs(etc)
    for name in ("execution-identity.json", "coordinator-identity.json"):
        with open(os.path.join(etc, name), "w") as handle:
            handle.write('{"schema_version":1}\n')
        os.chmod(os.path.join(etc, name), 0o444)
    # Traverse-only. `0111` removes read from the owner exactly as `0711`
    # removes it from a non-owner; this suite may not become uid 999.
    os.chmod(etc, 0o111)

    check("the fixture authority directory is traverse-only",
          (os.stat(etc).st_mode & 0o777) == 0o111)
    check("the authority file itself is world-readable",
          (os.stat(os.path.join(etc, "execution-identity.json")).st_mode
           & 0o777) == 0o444)

    dir_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
    anchor_flags = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

    # --- 1. the production failure, reproduced -----------------------------
    refused = None
    try:
        handle = os.open(etc, dir_flags)
        os.close(handle)
    except PermissionError as error:
        refused = error
    check("O_RDONLY|O_DIRECTORY on the authority directory is refused",
          refused is not None)

    # --- 2. the anchor reaches the named authority file --------------------
    root = os.open(etc, anchor_flags)
    try:
        check("O_PATH anchor of the authority directory succeeds", True)
        member = os.open("execution-identity.json",
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                         dir_fd=root)
        try:
            body = os.read(member, 4096)
            check("openat reaches execution-identity.json through the anchor",
                  body.startswith(b'{"schema_version"'))
        finally:
            os.close(member)

        # --- 3. and siblings stay non-enumerable ---------------------------
        listed = None
        try:
            listed = os.listdir(root)
        except OSError:
            pass
        check("the authority directory still cannot be enumerated",
              listed is None)

        # Knowing a name still works -- that is traverse, not enumeration.
        sibling = os.open("coordinator-identity.json",
                          os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                          dir_fd=root)
        os.close(sibling)
        check("a sibling is reachable by name but was never listed", True)
    finally:
        os.close(root)

    # --- 4. the privileged backend asks for the anchor ---------------------
    action = load("provisioning/execution/kyri-exec-transition-action.py",
                  "kyri_exec_transition_action_undertest")
    check("the privileged backend declares an O_PATH anchor",
          getattr(action, "_ANCHOR_FLAGS", None)
          == (os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY))
    opened = action.SystemBackend().open_directory(etc)
    try:
        check("SystemBackend.open_directory succeeds on a traverse-only root",
              True)
        named = os.open("execution-identity.json",
                        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=opened)
        os.close(named)
        check("and its descriptor anchors an openat", True)
        still = None
        try:
            still = os.listdir(opened)
        except OSError:
            pass
        check("and still cannot enumerate", still is None)
    finally:
        os.close(opened)

    # --- 5. the launcher carries a helper refusal --------------------------
    launcher = load("provisioning/execution/kyri-exec-launcher.py",
                    "kyri_exec_launcher_undertest")

    real = (b"refused: the execution authority directory is unusable: "
            b"[Errno 13] Permission denied: '/etc/kyri'\n")
    excerpt = launcher._excerpt(real)
    check("a real refusal survives into the excerpt",
          "Permission denied" in excerpt and "/etc/kyri" in excerpt)
    check("the excerpt is one line", "\n" not in excerpt and "\r" not in excerpt)

    noisy = b"\x1b[31mred\x1b[0m\x00\x07 refused: bad\n\nthing\n"
    clean = launcher._excerpt(noisy)
    check("control characters are stripped",
          all(" " <= character <= "~" for character in clean))
    check("and the message still reads", "refused: bad thing" in clean)

    bounded = launcher._excerpt(b"x" * 100000)
    check("an enormous stderr is bounded",
          len(bounded) <= launcher.MAXIMUM_REFUSAL_EXCERPT + 3)
    check("an empty stderr yields no excerpt", launcher._excerpt(b"") == "")
    check("a non-stream yields no excerpt", launcher._excerpt(None) == "")

    # It must still refuse -- the excerpt is diagnostic, never structure.
    class Done:
        stdout = b""
        stderr = real

    class FakeRun:
        def __init__(self, done):
            self.done = done

        def __call__(self, *args, **kwargs):
            return self.done

    original = launcher.subprocess.run
    launcher.subprocess.run = FakeRun(Done())
    try:
        instance = launcher.HelperLauncher()
        try:
            instance.reconcile("CINV-000001")
            check("the launcher still refuses an unreadable report", False)
        except launcher.LauncherRefused as error:
            check("the launcher still refuses an unreadable report", True)
            check("and its refusal now names the cause",
                  "Permission denied" in str(error)
                  and "no readable report" in str(error))
    finally:
        launcher.subprocess.run = original
finally:
    shutil.rmtree(work, ignore_errors=True)

print()
if failures:
    print(f"{len(failures)} assertion(s) failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("authority anchor and launcher diagnostics: all assertions hold")
PYTEST
