#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the Capability Runtime (ENG-0005), increment A1.
#
# A1 is the persistence foundation and nothing else: a second immutable store,
# in its own plane, owing the Fabric nothing but its discipline. There is no
# invocation identity, no payload binding, no Fabric reader, no precondition,
# no package resolution, no staging, no coordinator, no interface, and above
# all NO ADAPTER — and this suite asserts none of them.
#
# NOTHING HERE EXECUTES A CAPABILITY. The first block below is a permanent
# architectural backstop proving the production package has gained no way to
# execute anything. A persistence increment must not acquire execution
# authority, and that is a security property rather than a matter of it not
# being written yet.
#
# Governed by:
#   docs/superpowers/specs/2026-08-10-capability-runtime-design.md
#   docs/superpowers/plans/2026-08-10-eng-0005-capability-runtime-implementation-plan.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAPABILITY="tools/capability"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

# ===========================================================================
# The no-execution backstop
# ===========================================================================
# This runs first and stays for the life of the Capability Runtime. It scans
# the production package for the surfaces through which capability code could
# be launched. Comments and docstrings are stripped before scanning, so the
# specification's own prose about what it refuses to do cannot trip it -- the
# scan is over code, which is what it is making a claim about.

assert_no_execution_surface() {
  local report
  report="$(python3 - "${ROOT}" "${CAPABILITY}" <<'SCANPY'
import ast
import io
import pathlib
import sys
import tokenize

root = pathlib.Path(sys.argv[1])
package = root / sys.argv[2]

# Import targets that would give this package a way to start something.
FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex",
}
# Attribute calls on os and friends that spawn or replace a process.
FORBIDDEN_ATTRS = {
    "system", "popen", "fork", "forkpty", "spawn", "spawnl", "spawnle",
    "spawnlp", "spawnlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe",
    "posix_spawn", "posix_spawnp", "execl", "execle", "execlp", "execlpe",
    "execv", "execve", "execvp", "execvpe", "startfile",
}
FORBIDDEN_NAMES = {"eval", "exec", "compile", "__import__"}
# Words that would name an execution seam even without a call.
FORBIDDEN_TEXT = ("adapter_registry", "register_adapter", "ADAPTERS = ",
                  "docker run", "podman run", "/bin/sh", "/bin/bash")

findings = []

if not package.is_dir():
    print("PACKAGE_ABSENT")
    raise SystemExit(0)

for path in sorted(package.rglob("*.py")):
    if "__pycache__" in path.parts:
        continue
    source = path.read_text(encoding="utf-8")
    name = path.relative_to(root)

    # Strip comments and docstrings: prose describing a refusal is not a
    # mechanism, and a scan that cannot tell the difference gets weakened.
    stripped = []
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type in (tokenize.COMMENT, tokenize.STRING):
            continue
        stripped.append(token.string)
    code_text = " ".join(stripped)

    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                    findings.append(f"{name}:{node.lineno} imports {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            if node.module and node.module.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"{name}:{node.lineno} imports from {node.module}")
        elif isinstance(node, ast.Call):
            target = node.func
            if isinstance(target, ast.Attribute) and target.attr in FORBIDDEN_ATTRS:
                findings.append(f"{name}:{node.lineno} calls .{target.attr}()")
            if isinstance(target, ast.Name) and target.id in FORBIDDEN_NAMES:
                findings.append(f"{name}:{node.lineno} calls {target.id}()")

    for phrase in FORBIDDEN_TEXT:
        if phrase in code_text:
            findings.append(f"{name} carries the execution seam '{phrase}'")

print("\n".join(findings) if findings else "CLEAN")
SCANPY
)"
  if [[ "${report}" == "PACKAGE_ABSENT" ]]; then
    fail "the capability runtime package does not exist yet"
  elif [[ "${report}" == "CLEAN" ]]; then
    pass "the capability runtime package contains no execution surface"
  else
    while IFS= read -r line; do
      fail "execution surface in the capability runtime: ${line}"
    done <<< "${report}"
  fi
}

assert_no_execution_surface

# The authorised production surface, and nothing beyond it: A1's store
# modules plus A2's pure identity and binding layer.
assert_file "${CAPABILITY}/__init__.py"
assert_file "${CAPABILITY}/errors.py"
assert_file "${CAPABILITY}/identifiers.py"
assert_file "${CAPABILITY}/store.py"
assert_file "${CAPABILITY}/invocation_identity.py"

if [[ -d "${ROOT}/${CAPABILITY}" ]]; then
  UNEXPECTED="$(find "${ROOT}/${CAPABILITY}" -maxdepth 1 -name '*.py' -printf '%f\n' 2>/dev/null \
    | grep -vxE '__init__\.py|errors\.py|identifiers\.py|store\.py|invocation_identity\.py' || true)"
  if [[ -z "${UNEXPECTED}" ]]; then
    pass "increment A1 adds no module beyond its authorised surface"
  else
    while IFS= read -r module; do
      fail "unauthorised module for increment A1: ${module}"
    done <<< "${UNEXPECTED}"
  fi
fi

# ===========================================================================
# A1 — the Capability Runtime immutable store
# ===========================================================================

STORE_OUTPUT="$(python3 - "${ROOT}" <<'STOREPY' 2>&1 || true
import os
import stat
import sys
import threading
from pathlib import Path
from tempfile import TemporaryDirectory

root = Path(sys.argv[1])
sys.path.insert(0, str(root))

failures = 0


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


def refuses(action, message):
    try:
        action()
    except CapabilityError:
        ok(message)
    except Exception as error:  # noqa: BLE001
        bad(f"{message} (raised {type(error).__name__}: {error})")
    else:
        bad(f"{message} (was accepted instead of refused)")


from tools.capability.errors import CapabilityError  # noqa: E402
from tools.capability.identifiers import (  # noqa: E402
    ID_FIELDS, PATTERNS, PREFIXES, RECORD_DIRS)
from tools.capability.store import CapabilityStore  # noqa: E402
from tools.common.immutable_store import DIR_MODE, FILE_MODE  # noqa: E402
from tools.fabric.store import FabricStore  # noqa: E402

UID = os.geteuid()
GID = os.getegid()

INVOCATION = "capability-invocation"
RESULT = "capability-result"


def opened(tmp, **overrides):
    fields = dict(expected_uid=UID, expected_gid=GID)
    fields.update(overrides)
    return CapabilityStore(Path(tmp) / "capability", **fields)


def inventory(base):
    entries = {}
    if not Path(base).exists():
        return entries
    for path in sorted(Path(base).rglob("*")):
        info = path.lstat()
        entries[str(path.relative_to(base))] = (
            stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode),
            info.st_uid, info.st_gid, info.st_ino, info.st_mtime_ns,
            info.st_size)
    return entries


# --- the two record kinds A1 owns, and no others ---------------------------
check(sorted(RECORD_DIRS) == [INVOCATION, RESULT],
      f"the store owns exactly two record kinds ({sorted(RECORD_DIRS)})")
check(sorted(PREFIXES.values()) == ["CINV", "CRES"],
      f"the identifier prefixes are CINV and CRES ({sorted(PREFIXES.values())})")
check(PATTERNS[INVOCATION].pattern == r"^CINV-[0-9]{6}$",
      "an invocation identity is CINV followed by six digits")
check(PATTERNS[RESULT].pattern == r"^CRES-[0-9]{6}$",
      "a result identity is CRES followed by six digits")
check(sorted(ID_FIELDS) == [INVOCATION, RESULT],
      "each kind names the field carrying its identity")

# --- store creation ---------------------------------------------------------
with TemporaryDirectory() as tmp:
    fields = dict(expected_uid=UID, expected_gid=GID)
    refuses(lambda: CapabilityStore(None, **fields),
            "a store with no root is refused")
    refuses(lambda: CapabilityStore("   ", **fields),
            "a store with a blank root is refused")
    try:
        CapabilityStore(Path(tmp) / "a", expected_uid=UID)
    except TypeError:
        ok("expected_gid is required rather than defaulted")
    except Exception as error:  # noqa: BLE001
        bad(f"expected_gid is required rather than defaulted ({type(error).__name__})")
    else:
        bad("expected_gid is required rather than defaulted (was accepted)")
    refuses(lambda: CapabilityStore(Path(tmp) / "b", expected_uid=True,
                                    expected_gid=GID),
            "a boolean masquerading as a uid is refused")
    refuses(lambda: CapabilityStore(Path(tmp) / "c", expected_uid=UID + 1,
                                    expected_gid=GID),
            "a root owned by someone else is refused")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability_root = Path(tmp) / "capability"

    check(capability_root.is_dir(), "the store root exists after opening")
    # The root's own mode comes from the ambient umask, exactly as it does for
    # the released Fabric store. What this store fixes is every directory it
    # creates inside the root -- and that the root is never world-writable.
    root_mode = stat.S_IMODE(capability_root.lstat().st_mode)
    check(not root_mode & stat.S_IWOTH,
          f"the store root is not world-writable ({oct(root_mode)})")
    for kind, directory in RECORD_DIRS.items():
        entry = capability_root / directory
        check(entry.is_dir(), f"the {kind} directory exists")
        check(stat.S_IMODE(entry.lstat().st_mode) == DIR_MODE,
              f"the {kind} directory is {oct(DIR_MODE)}")
    check((capability_root / "sequences").is_dir(), "the sequence directory exists")
    check(stat.S_IMODE((capability_root / "sequences").lstat().st_mode) == DIR_MODE,
          f"the sequence directory is {oct(DIR_MODE)}")

    # The critical section is the store's own, and it is a real lock.
    lock = capability_root / "sequences" / "invocation_identity.lock"
    check(lock.is_file(), "the store owns an invocation identity lock")
    check(stat.S_IMODE(lock.lstat().st_mode) == FILE_MODE,
          f"the invocation identity lock is {oct(FILE_MODE)}")
    check(lock.lstat().st_size == 0, "the lock carries no content")

    # Entering it disturbs nothing: it exists from initialisation onward.
    before = inventory(capability_root)
    with store.invocation_critical_section("inv-1"):
        pass
    check(inventory(capability_root) == before,
          "entering the critical section changes nothing")

    # An exception inside the section still releases it.
    try:
        with store.invocation_critical_section("inv-2"):
            raise RuntimeError("boom")
    except RuntimeError:
        pass
    released = threading.Event()

    def later():
        with store.invocation_critical_section("inv-3"):
            released.set()

    worker = threading.Thread(target=later, daemon=True)
    worker.start()
    check(released.wait(5), "the critical section is released after an exception")

# --- symlink and containment refusal ---------------------------------------
with TemporaryDirectory() as tmp:
    outside = Path(tmp) / "outside"
    outside.mkdir()
    linked = Path(tmp) / "capability"
    linked.symlink_to(outside)
    refuses(lambda: CapabilityStore(linked, expected_uid=UID, expected_gid=GID),
            "a symlinked store root is refused")

with TemporaryDirectory() as tmp:
    outside = Path(tmp) / "outside"
    outside.mkdir()
    capability_root = Path(tmp) / "capability"
    capability_root.mkdir(mode=DIR_MODE)
    for name in (*RECORD_DIRS.values(), "sequences"):
        if name != RECORD_DIRS[INVOCATION]:
            (capability_root / name).mkdir(mode=DIR_MODE)
    (capability_root / RECORD_DIRS[INVOCATION]).symlink_to(outside)
    refuses(lambda: CapabilityStore(capability_root, expected_uid=UID,
                                    expected_gid=GID),
            "a symlinked record directory is refused")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability_root = Path(tmp) / "capability"
    refuses(lambda: store.path_for(INVOCATION, "../escape"),
            "a traversing identity is refused")
    refuses(lambda: store.path_for(INVOCATION, "CINV-1"),
            "an identity of the wrong width is refused")
    refuses(lambda: store.path_for(INVOCATION, "CRES-000001"),
            "an identity carrying the wrong prefix is refused")
    refuses(lambda: store.path_for("capability-nonsense", "CINV-000001"),
            "an unknown record kind is refused")
    refuses(lambda: store.allocate_id("capability-nonsense"),
            "allocation for an unknown record kind is refused")

    outside = Path(tmp) / "outside"
    outside.mkdir()
    (outside / "secret.yaml").write_text("a: 1", encoding="utf-8")
    linked = capability_root / RECORD_DIRS[INVOCATION] / "CINV-000001.yaml"
    linked.symlink_to(outside / "secret.yaml")
    refuses(lambda: store.read_record(INVOCATION, "CINV-000001"),
            "a symlinked record is refused rather than followed")
    linked.unlink()

# --- identifier allocation --------------------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    invocations = [store.allocate_id(INVOCATION) for _ in range(4)]
    results = [store.allocate_id(RESULT) for _ in range(3)]
    check(invocations == ["CINV-000001", "CINV-000002", "CINV-000003",
                          "CINV-000004"],
          f"invocation identities are monotonic from one ({invocations})")
    check(results == ["CRES-000001", "CRES-000002", "CRES-000003"],
          f"result identities are monotonic from one ({results})")
    check(len(set(invocations + results)) == 7, "no identity is reused")
    check(all(PATTERNS[INVOCATION].match(i) for i in invocations),
          "every invocation identity matches its pattern")
    check(all(PATTERNS[RESULT].match(i) for i in results),
          "every result identity matches its pattern")

    # Allocation is monotonic even when nothing was written: an identity that
    # was handed out and never used is spent, not recycled.
    spent = store.allocate_id(INVOCATION)
    following = store.allocate_id(INVOCATION)
    check(spent == "CINV-000005" and following == "CINV-000006",
          f"an allocated-but-unwritten identity is not reused ({spent}, {following})")

    sequences = sorted(p.name for p in (Path(tmp) / "capability" / "sequences").glob("*.seq"))
    check(sequences == [f"{INVOCATION}.seq", f"{RESULT}.seq"],
          f"each kind keeps its own independent sequence ({sequences})")

# --- atomic immutable writes ------------------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability_root = Path(tmp) / "capability"
    identifier = store.allocate_id(INVOCATION)
    destination = store.path_for(INVOCATION, identifier)
    written = store.write_atomic(destination, {"invocation_record_id": identifier})
    check(written.is_file(), "a record is published")
    check(stat.S_IMODE(written.lstat().st_mode) == FILE_MODE,
          f"a published record is {oct(FILE_MODE)}")

    before = inventory(capability_root)
    refuses(lambda: store.write_atomic(destination, {"invocation_record_id": identifier}),
            "an occupied record path refuses rather than overwriting")
    check(inventory(capability_root) == before,
          "a refused overwrite leaves the occupying record untouched")

    # A pre-existing temporary is evidence of an interrupted write.
    temporary = destination.with_name(f".{destination.stem}.tmp")
    second = store.allocate_id(INVOCATION)
    second_destination = store.path_for(INVOCATION, second)
    second_temporary = second_destination.with_name(f".{second_destination.stem}.tmp")
    second_temporary.write_text("interrupted", encoding="utf-8")
    residue_before = inventory(capability_root)
    refuses(lambda: store.write_atomic(second_destination, {"invocation_record_id": second}),
            "a pre-existing temporary refuses rather than being truncated")
    check(inventory(capability_root) == residue_before,
          "the interrupted temporary keeps its bytes, mode, and inode")
    check(second_temporary.read_text(encoding="utf-8") == "interrupted",
          "residue is preserved rather than repaired")
    check(not temporary.exists(), "a completed write leaves no temporary of its own")

# --- reads ------------------------------------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    identifier = store.allocate_id(INVOCATION)
    store.write_atomic(store.path_for(INVOCATION, identifier),
                       {"invocation_record_id": identifier, "actor": "operator"})
    record = store.read_record(INVOCATION, identifier)
    check(record.get("invocation_record_id") == identifier,
          "a record reads back by its exact identity")
    refuses(lambda: store.read_record(INVOCATION, "CINV-999999"),
            "a record that is not there is refused as not found")
    refuses(lambda: store.read_record(RESULT, identifier),
            "reading an invocation as a result is refused")

    malformed = store.path_for(RESULT, "CRES-000001")
    malformed.write_text("{not: [valid", encoding="utf-8")
    refuses(lambda: store.read_record(RESULT, "CRES-000001"),
            "a malformed record refuses rather than yielding a partial value")
    malformed.write_text("- a\n- b\n", encoding="utf-8")
    refuses(lambda: store.read_record(RESULT, "CRES-000001"),
            "a record that is not a mapping is refused")
    malformed.unlink()

    mismatched = store.path_for(RESULT, "CRES-000002")
    mismatched.write_text("capability_result_id: CRES-000009\n", encoding="utf-8")
    refuses(lambda: store.read_record(RESULT, "CRES-000002"),
            "a record whose identity disagrees with its filename is refused")

# --- the store is not the Fabric store --------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    fabric = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)

    check(not isinstance(store, FabricStore),
          "the capability store is not a FabricStore")
    check(set(RECORD_DIRS) & set(FabricStore.record_dirs) == set(),
          "it shares no record kind with the Fabric")
    check(set(PREFIXES.values()) & set(FabricStore.id_prefixes.values()) == set(),
          "it shares no identifier prefix with the Fabric")
    check(store.root != fabric.root, "it has its own root")
    check(len(FabricStore.record_dirs) == 8,
          f"the Fabric still has exactly eight record kinds ({len(FabricStore.record_dirs)})")

    # It writes nothing into the Fabric, and holds no Fabric lock.
    fabric_before = inventory(fabric.root)
    identifier = store.allocate_id(INVOCATION)
    store.write_atomic(store.path_for(INVOCATION, identifier),
                       {"invocation_record_id": identifier})
    with store.invocation_critical_section("inv-boundary"):
        pass
    check(inventory(fabric.root) == fabric_before,
          "writing a capability record leaves the Fabric store byte-unchanged")

    # The two locks are different files, so neither blocks the other.
    capability_lock = store.root / "sequences" / "invocation_identity.lock"
    fabric_lock = fabric.root / "sequences" / "request_identity.lock"
    check(capability_lock != fabric_lock and capability_lock.exists(),
          "the capability lock is its own file")
    held = threading.Event()
    proceeded = threading.Event()

    def hold_capability():
        with store.invocation_critical_section("inv-held"):
            held.set()
            proceeded.wait(5)

    holder = threading.Thread(target=hold_capability, daemon=True)
    holder.start()
    check(held.wait(5), "the capability section can be held")

    entered_fabric = threading.Event()

    def enter_fabric():
        with fabric.request_critical_section("req-1"):
            entered_fabric.set()

    fabric_thread = threading.Thread(target=enter_fabric, daemon=True)
    fabric_thread.start()
    check(entered_fabric.wait(5),
          "the Fabric section is unaffected while the capability section is held")
    proceeded.set()
    holder.join(5)

    check("request_critical_section" not in
          (root / "tools" / "capability" / "store.py").read_text(encoding="utf-8"),
          "the capability store never enters the Fabric request lock")

# --- concurrency ------------------------------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    ROUNDS = 8
    CALLERS = 8
    allocated = {INVOCATION: [], RESULT: []}
    notice = threading.Lock()
    problems = []

    def allocate(kind):
        try:
            handle = CapabilityStore(store.root, expected_uid=UID, expected_gid=GID)
            identifier = handle.allocate_id(kind)
            handle.write_atomic(handle.path_for(kind, identifier),
                               {ID_FIELDS[kind]: identifier})
            with notice:
                allocated[kind].append(identifier)
        except BaseException as error:  # noqa: BLE001
            with notice:
                problems.append(f"{type(error).__name__}: {error}")

    for _ in range(ROUNDS):
        threads = [threading.Thread(target=allocate, args=(kind,))
                   for kind in (INVOCATION, RESULT)
                   for _ in range(CALLERS)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(30)
        if any(thread.is_alive() for thread in threads):
            problems.append("a concurrent allocator did not finish")
            break

    expected = ROUNDS * CALLERS
    check(not problems, f"concurrent allocation raises nothing ({problems[:2]})")
    for kind, prefix in ((INVOCATION, "CINV"), (RESULT, "CRES")):
        identities = allocated[kind]
        check(len(identities) == expected,
              f"every {prefix} caller allocated ({len(identities)}/{expected})")
        check(len(set(identities)) == len(identities),
              f"no {prefix} identity was handed out twice")
        numbers = sorted(int(i.split("-")[1]) for i in identities)
        check(numbers == list(range(1, expected + 1)),
              f"{prefix} identities are unique, monotonic, and dense")
        stored = sorted(p.stem for p in
                        (store.root / RECORD_DIRS[kind]).glob("*.yaml"))
        check(len(stored) == expected,
              f"every {prefix} record was published ({len(stored)}/{expected})")
        check(sorted(identities) == stored,
              f"no {prefix} record was overwritten by another caller")

# --- validation and counts --------------------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    identifier = store.allocate_id(INVOCATION)
    store.write_atomic(store.path_for(INVOCATION, identifier),
                       {"invocation_record_id": identifier})
    check(store.counts() == {INVOCATION: 1, RESULT: 0},
          f"counts report each kind ({store.counts()})")

    temporary = store.path_for(RESULT, "CRES-000001").with_name(".CRES-000001.tmp")
    temporary.write_text("interrupted", encoding="utf-8")
    before = inventory(store.root)
    findings = store.validate()
    check(any("tmp" in finding for finding in findings),
          f"residue is reported as a finding ({findings})")
    check(inventory(store.root) == before,
          "validation repairs nothing and changes nothing")
    check(tuple(store.validate()) == tuple(findings),
          "validation is deterministic across repeated runs")

# --- opening a store that is not there --------------------------------------
with TemporaryDirectory() as tmp:
    absent = Path(tmp) / "absent"
    reader = CapabilityStore.open_for_read(absent, expected_uid=UID,
                                           expected_gid=GID)
    check(not absent.exists(),
          "opening an absent store for read builds nothing")
    refuses(lambda: reader.read_record(INVOCATION, "CINV-000001"),
            "reading from an absent store is refused")


# ===========================================================================
# A2 — invocation identity and canonical payload binding
# ===========================================================================
# A Fabric selection governs a request class, not bytes. Two different payloads
# of one class produce identical governance, so a valid selection for one
# payload would otherwise buy execution of another. Binding closes that.
#
# This layer is pure. It reads no Fabric record, opens no store, enters no
# critical section, writes nothing, reads no clock, and consults no ambient
# state. Everything it needs is passed to it.

import hashlib as _hashlib  # noqa: E402

from tools.capability.invocation_identity import (  # noqa: E402
    CONFLICT, CONSUMED, DISTINCT, INVOCATION_ID_MAX_LENGTH, bind,
    canonical_bytes, compare_binding, payload_digest, validate_invocation_id)

BINDING = dict(invocation_id="inv-alpha", selection_id="CSEL-000001",
               instance_id="CINST-000001", capability_package_id="CPKG-0001",
               actor="operator:cschott")


def refuses_capability(action, message):
    """A refusal must be the runtime's own, not an incidental exception."""
    try:
        action()
    except CapabilityError:
        ok(message)
    except Exception as error:  # noqa: BLE001
        bad(f"{message} (raised {type(error).__name__}: {error})")
    else:
        bad(f"{message} (was accepted instead of refused)")


# --- invocation identity: opaque, caller-supplied, never parsed -------------
for value, description in (("inv-alpha", "an ordinary identity"),
                           ("a", "a single character"),
                           ("x" * INVOCATION_ID_MAX_LENGTH, "an identity at the limit"),
                           ("CINV-000001", "an identity that looks like a record id"),
                           ("~!@#$%^&*()_+", "printable punctuation"),
                           ("0123456789", "digits")):
    check(validate_invocation_id(value) == value,
          f"{description} is returned unchanged")

for value, description in ((None, "an absent identity"),
                           ("", "an empty identity"),
                           ("x" * (INVOCATION_ID_MAX_LENGTH + 1), "an over-long identity"),
                           ("has space", "an identity carrying a space"),
                           ("tab\there", "an identity carrying a tab"),
                           ("line\nbreak", "an identity carrying a newline"),
                           ("null\0byte", "an identity carrying a null byte"),
                           ("café", "an identity carrying non-ASCII"),
                           ("del\x7f", "an identity carrying a control character"),
                           (123, "a non-string identity"),
                           (b"bytes", "a bytes identity")):
    refuses_capability(lambda v=value: validate_invocation_id(v),
                       f"{description} is refused")

# It is never parsed: nothing about its shape carries meaning.
check(validate_invocation_id("CINV-999999") == "CINV-999999",
      "an identity is never parsed for structure")
source = (root / "tools" / "capability" / "invocation_identity.py").read_text(encoding="utf-8")
for token in ("startswith", "re.match", "re.compile", "split(", "int("):
    check(token not in source,
          f"the identity layer does not parse identities ({token})")

# --- canonical payload: accepted types -------------------------------------
for payload, expected, description in (
        ({}, b"{}", "an empty object"),
        ([], b"[]", "an empty array"),
        ("", b'""', "an empty string"),
        (None, b"null", "null"),
        (True, b"true", "true"),
        (False, b"false", "false"),
        (0, b"0", "zero"),
        (-1, b"-1", "a negative integer"),
        ({"a": 1, "b": 2}, b'{"a":1,"b":2}', "two sorted keys"),
        ({"b": 2, "a": 1}, b'{"a":1,"b":2}', "two keys sorted regardless of insertion"),
        ({"Z": 1, "a": 2}, b'{"Z":1,"a":2}', "keys ordered by code point, not case"),
        ({"a": {"y": 2, "x": 1}, "b": [1, 2, 3]},
         b'{"a":{"x":1,"y":2},"b":[1,2,3]}', "nested keys sorted, array order kept"),
        ({"café": "naïve"}, '{"café":"naïve"}'.encode("utf-8"),
         "non-ASCII emitted literally rather than escaped"),
        ({"k": [True, False, None, 0, -1]}, b'{"k":[true,false,null,0,-1]}',
         "mixed scalars")):
    check(canonical_bytes(payload) == expected,
          f"{description} canonicalises exactly ({canonical_bytes(payload)!r})")

check(b" " not in canonical_bytes({"a": 1, "b": [1, 2]}),
      "the canonical form carries no insignificant whitespace")
check(not canonical_bytes({"a": 1}).endswith(b"\n"),
      "the canonical form carries no trailing newline")

# A boolean is not an integer, however Python models it.
check(canonical_bytes(True) != canonical_bytes(1),
      "true and 1 are distinct")
check(canonical_bytes(False) != canonical_bytes(0),
      "false and 0 are distinct")
check(canonical_bytes({"a": True}) != canonical_bytes({"a": 1}),
      "a boolean member is distinct from an integer member")

# --- canonical payload: ambiguity refused -----------------------------------
class _Custom:
    pass


for payload, description in (
        (1.0, "a float"),
        (0.1, "a fractional float"),
        (float("nan"), "NaN"),
        (float("inf"), "positive infinity"),
        (float("-inf"), "negative infinity"),
        ({1: "a"}, "a non-string mapping key"),
        ({None: "a"}, "a null mapping key"),
        ({(1, 2): "a"}, "a tuple mapping key"),
        ({"a": (1, 2)}, "a tuple value"),
        ({"a": {1, 2}}, "a set value"),
        ({"a": frozenset({1})}, "a frozenset value"),
        ({"a": b"bytes"}, "a bytes value"),
        ({"a": bytearray(b"x")}, "a bytearray value"),
        ({"a": _Custom()}, "a custom object"),
        ({"a": complex(1, 2)}, "a complex number"),
        (_Custom(), "a custom object at the root"),
        ({"a": [1, 2.5]}, "a float nested in an array"),
        ({"a": {"b": {"c": 1.5}}}, "a float nested deeply")):
    refuses_capability(lambda p=payload: canonical_bytes(p),
                       f"{description} is refused rather than approximated")

# --- digest: known-answer vectors, computed independently -------------------
for payload, expected, description in (
        ({}, "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
         "an empty object"),
        ([], "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
         "an empty array"),
        (None, "74234e98afe7498fb5daf1f36ac2d78acc339464f950703b8c019892f982b90b",
         "null"),
        (True, "b5bea41b6c623f7c09f1bf24dcae58ebab3c0cdd90ad966bc43a45b44867e12b",
         "true"),
        (0, "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9",
         "zero"),
        ({"b": 2, "a": 1},
         "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777",
         "two keys"),
        ({"a": {"y": 2, "x": 1}, "b": [1, 2, 3]},
         "e1ca855256d6ce15c2d389babfb8f209659a9cf625428bb2eeb07b06d5fa80ea",
         "a nested object"),
        ({"café": "naïve"},
         "8d9bcca95360c226e5d7f0039e45a492b075f4180982edfef731a03e92e4c626",
         "a non-ASCII object")):
    check(payload_digest(payload) == f"sha256:{expected}",
          f"the digest of {description} matches its known answer")

check(payload_digest({}).startswith("sha256:"),
      "a digest carries the released sha256 prefix")
check(len(payload_digest({})) == len("sha256:") + 64,
      "a digest carries sixty-four hexadecimal characters")

# --- binding: the payload alone is not enough -------------------------------
base = bind(payload={"text": "summarise"}, **BINDING)
check(base.startswith("sha256:"), "a binding is a sha256 digest")
check(base == bind(payload={"text": "summarise"}, **BINDING),
      "the same payload and the same binding produce the same digest")
check(base != payload_digest({"text": "summarise"}),
      "a binding is not merely the payload's own digest")

for field in ("invocation_id", "selection_id", "instance_id",
              "capability_package_id", "actor"):
    altered = dict(BINDING)
    altered[field] = altered[field] + "-other"
    check(bind(payload={"text": "summarise"}, **altered) != base,
          f"changing {field} changes the binding")

check(bind(payload={"text": "translate"}, **BINDING) != base,
      "changing the payload changes the binding")
check(bind(payload={"text": "summarise", "extra": None}, **BINDING) != base,
      "adding a payload key changes the binding")

# Domain separation: moving text between fields must not collide.
left = bind(payload={}, invocation_id="ab", selection_id="c",
            instance_id="d", capability_package_id="e", actor="f")
right = bind(payload={}, invocation_id="a", selection_id="bc",
             instance_id="d", capability_package_id="e", actor="f")
check(left != right,
      "text moved between binding fields does not collide")

# Every binding field is validated, and none is optional.
for field in ("selection_id", "instance_id", "capability_package_id", "actor"):
    for value, description in ((None, "absent"), ("", "empty"),
                               ("has space", "carrying a space"),
                               (123, "not a string")):
        altered = dict(BINDING)
        altered[field] = value
        refuses_capability(lambda a=altered: bind(payload={}, **a),
                           f"a {description} {field} is refused")

# --- duplicate and conflicting identity, as a pure comparison ---------------
check(compare_binding(base, base) == CONSUMED,
      "an identity presented again with the same binding is consumed")
check(compare_binding(base, bind(payload={"text": "translate"}, **BINDING)) == CONFLICT,
      "an identity presented again with a different binding conflicts")
check(CONSUMED == "invocation_identity_consumed",
      f"the consumed outcome is named as accepted ({CONSUMED})")
check(CONFLICT == "invocation_identity_conflict",
      f"the conflicting outcome is named as accepted ({CONFLICT})")
check(compare_binding(None, base) == DISTINCT,
      "an identity never seen before is distinct")
for bad_digest in ("", "sha256:short", "deadbeef", "SHA256:" + "a" * 64,
                   "sha256:" + "g" * 64, 123):
    refuses_capability(lambda d=bad_digest: compare_binding(d, base),
                       f"a malformed stored digest is refused ({bad_digest!r})")

# --- purity: no state, no store, no clock, no Fabric ------------------------
for token, description in (
        ("import os", "the operating system"),
        ("open(", "the filesystem"),
        ("Path(", "a filesystem path"),
        ("datetime", "a clock"),
        ("time.", "a clock"),
        ("random", "a random source"),
        ("environ", "the environment"),
        ("tools.fabric", "the fabric"),
        ("tools.trust", "trust"),
        ("health", "health"),
        ("critical_section", "a critical section"),
        ("CapabilityStore", "the store")):
    check(token not in source,
          f"the identity layer reaches {description} by no mechanism")

# Determinism across processes: the canonical form must not depend on a hash
# seed, so the digest is recomputed in a fresh interpreter with a different one.
import subprocess as _subprocess  # noqa: E402  (test harness only, never production)
probe = (
    "import sys; sys.path.insert(0, %r)\n"
    "from tools.capability.invocation_identity import payload_digest\n"
    "print(payload_digest({'b': 2, 'a': 1, 'z': {'q': 1, 'p': 2}}))\n"
) % str(root)
seeded = _subprocess.run([sys.executable, "-c", probe], capture_output=True,
                         text=True, env={**os.environ, "PYTHONHASHSEED": "12345"})
check(seeded.stdout.strip() == payload_digest({"b": 2, "a": 1, "z": {"q": 1, "p": 2}}),
      "the digest is identical under a different interpreter hash seed")

# --- generated determinism sweep --------------------------------------------
# Many logical payloads, each built in several insertion orders. Deterministic
# generation, so a failure is reproducible rather than a lucky seed.
def shapes():
    keys = ["a", "b", "Z", "café", "", "0", "z" * 8]
    values = [None, True, False, 0, -1, 42, "", "text", "naïve", [], {},
              [1, 2, 3], ["a", None, True], {"n": 1}]
    for depth in range(3):
        for index, value in enumerate(values):
            body = {keys[i % len(keys)]: values[(i + index) % len(values)]
                    for i in range(1 + index % 5)}
            for _ in range(depth):
                body = {"nested": body, "sibling": value}
            yield body


generated = 0
mismatches = 0
canonical_seen = {}
collisions = 0
for shape in shapes():
    generated += 1
    forward = canonical_bytes(shape)
    reversed_build = canonical_bytes(
        {key: shape[key] for key in reversed(list(shape))})
    if forward != reversed_build:
        mismatches += 1
    if payload_digest(shape) != f"sha256:{_hashlib.sha256(forward).hexdigest()}":
        mismatches += 1
    previous = canonical_seen.setdefault(forward, shape)
    if previous is not shape and previous != shape:
        collisions += 1

check(generated >= 40, f"the determinism sweep covered enough shapes ({generated})")
check(mismatches == 0,
      f"every generated payload canonicalises identically in any order ({mismatches})")
check(collisions == 0,
      f"no two distinct logical payloads share canonical bytes ({collisions})")
print(f"PASS: determinism sweep — {generated} generated payloads, "
      f"{mismatches} mismatches, {collisions} canonical collisions")
print(f"__FAILURES__={failures}")
STOREPY
)"

printf '%s\n' "${STORE_OUTPUT}" | grep -v '^__FAILURES__=' || true
STORE_FAILURES="$(printf '%s\n' "${STORE_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${STORE_FAILURES}" ]]; then
  fail "capability runtime store validation did not report a result"
else
  FAILURES=$((FAILURES + STORE_FAILURES))
fi

if (( FAILURES > 0 )); then
  printf '\nCapability runtime validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi
printf '\nCapability runtime validation passed.\n'
