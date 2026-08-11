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
# Fabric is consumed, never commanded. A3 introduced read-only evidence
# access, so "no Fabric import" advanced to an allow-list: exactly the
# read-only inspection surface, and nothing that decides, mutates, or
# allocates. An allow-list rather than a blacklist, so a new Fabric module
# is forbidden by default instead of forbidden only once someone remembers
# to name it.
ALLOWED_FABRIC_IMPORTS = {"tools.fabric.inspection", "..fabric.inspection"}
# Named individually because each is a different way the same line gets
# crossed. These are the released decision and mutation surfaces.
FORBIDDEN_FABRIC_SYMBOLS = (
    "admission", "selection", "eligibility", "trust_adapter",
    "select_candidate", "evaluate_eligibility", "admit_instance",
    "admit_subject", "declare_capability", "declare_contract",
    "declare_package", "register_advertisement", "create_route",
    "withdraw_subject", "refresh_subject", "withdraw_instance",
    "retire_instance", "request_critical_section", "allocate_id",
    "write_atomic", "write_record", "FabricStore",
)
# Attribute calls on os and friends that spawn or replace a process.
FORBIDDEN_ATTRS = {
    "system", "popen", "fork", "forkpty", "spawn", "spawnl", "spawnle",
    "spawnlp", "spawnlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe",
    "posix_spawn", "posix_spawnp", "execl", "execle", "execlp", "execlpe",
    "execv", "execve", "execvp", "execvpe", "startfile",
}
FORBIDDEN_NAMES = {"eval", "exec", "compile", "__import__"}
# The only production modules permitted to mutate the filesystem.
# mutation.py joined the set at ENG-0005 T5: it is the accepted CMUT durability
# substrate and the first write-capable execution module. Its writes are bounded
# far more tightly than this guard can express -- closed target identities,
# descriptor-relative only, create-once -- and that is asserted by
# tests/test-capability-execution-mutation.sh rather than here.
WRITE_OWNING_MODULES = {"store.py", "package_resolution.py", "evidence.py",
                        "mutation.py", "state.py", "handoff.py"}
# Authority planes this package may never reach, by import or by symbol.
FORBIDDEN_PLANES = ("tools.trust", "..trust", "TrustStore", "TrustGateway",
                    "trust_adapter", "tools.health", "..health",
                    "scheduler", "placement", "clustering", "failover",
                    "liveness", "readiness", "heartbeat", "adaptive_routing")
# Words that would name an execution seam even without a call.
FORBIDDEN_TEXT = ("adapter_registry", "register_adapter", "ADAPTERS = ",
                  "docker run", "podman run", "/bin/sh", "/bin/bash",
                  "request_critical_section")

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
    # Tokens are joined with spaces, which turns `os.write` into `os . write`
    # and silently defeated every dotted check below -- the mutation guard had
    # never matched a single one. Attribute spellings are rejoined so those
    # checks test what they claim to. Found at ENG-0005 T5.
    code_text = " ".join(stripped).replace(" . ", ".")

    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                    findings.append(f"{name}:{node.lineno} imports {alias.name}")
                if "fabric" in alias.name and alias.name not in ALLOWED_FABRIC_IMPORTS:
                    findings.append(f"{name}:{node.lineno} imports {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            if node.module and node.module.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"{name}:{node.lineno} imports from {node.module}")
            spelled = "." * node.level + (node.module or "")
            # Only the Fabric package is governed here. A sibling capability
            # module whose name merely contains "fabric" is not a Fabric import,
            # and flagging it would push the real check toward being loosened.
            reaches_fabric = (spelled.startswith("..fabric")
                              or spelled.startswith("tools.fabric"))
            if reaches_fabric and spelled not in ALLOWED_FABRIC_IMPORTS:
                findings.append(f"{name}:{node.lineno} imports from {spelled}")
            for alias in node.names:
                if alias.name in FORBIDDEN_FABRIC_SYMBOLS:
                    findings.append(
                        f"{name}:{node.lineno} imports the decision surface {alias.name}")
        elif isinstance(node, ast.Call):
            target = node.func
            if isinstance(target, ast.Attribute) and target.attr in FORBIDDEN_ATTRS:
                findings.append(f"{name}:{node.lineno} calls .{target.attr}()")
            if isinstance(target, ast.Name) and target.id in FORBIDDEN_NAMES:
                findings.append(f"{name}:{node.lineno} calls {target.id}()")

    for phrase in FORBIDDEN_TEXT:
        if phrase in code_text:
            findings.append(f"{name} carries the execution seam '{phrase}'")

    for plane in FORBIDDEN_PLANES:
        if plane in code_text:
            findings.append(f"{name} reaches another authority plane ('{plane}')")

    # Filesystem mutation is permitted in exactly two modules: the store, which
    # is a store, and package staging, which must write the verified copy.
    # Everywhere else in the package it is forbidden, so "A4 stages bytes" does
    # not become "the runtime may write anywhere".
    # Filesystem mutation belongs to three modules and is denied everywhere
    # else. A new module is read-only by default: escaping this guard takes an
    # authorised change to the set, not merely a filename nobody listed.
    if path.name not in WRITE_OWNING_MODULES:
        for mutator in ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "os.write",
                        "os.rename", "os.replace", "os.link", "os.unlink",
                        "os.mkdir", "os.chmod", "os.chown", "write_text",
                        "write_bytes", "shutil", "tempfile"):
            if mutator in code_text:
                findings.append(
                    f"{name} may not mutate the filesystem ({mutator})")

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

# The twelve modules Track A built. Named so their absence is a failure, not
# a silently smaller package.
for module in __init__ errors identifiers store invocation_identity \
              fabric_evidence package_resolution records evidence \
              inspection coordinator cli; do
  assert_file "${CAPABILITY}/${module}.py"
done

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

# ===========================================================================
# A3 — Fabric evidence reader and execution-precondition evaluator
# ===========================================================================
# The authority bridge, and it only ever crosses in one direction. Fabric has
# already decided what may run and where; this verifies that the invocation a
# caller claims corresponds to that decision, as recorded, and refuses when it
# does not. It never searches for an alternative that would work.
#
# It reads through C8's inspection surface and nothing else, so admission,
# selection, eligibility, and the trust adapter are not merely unused -- they
# are unreachable.

from datetime import datetime as _datetime, timedelta as _timedelta, timezone as _timezone  # noqa: E402

from tools.capability.fabric_evidence import (  # noqa: E402
    REASON_CAPABILITY_ABSENT, REASON_CONTRACT_ABSENT, REASON_EFFECT_CLASS,
    REASON_INCOHERENT, REASON_INSTANCE_ABSENT, REASON_INSTANCE_MISMATCH,
    REASON_NOT_ADMITTED, REASON_PACKAGE_ABSENT, REASON_PACKAGE_MISMATCH,
    REASON_SELECTION_ABSENT, REASON_SELECTION_REFUSED, REASON_SUPERSEDED,
    REASON_UNREADABLE, REASON_WINDOW, verify_selected_evidence)
from tools.fabric.store import FabricStore as _FabricStore  # noqa: E402

_NOW = _datetime(2026, 8, 10, 12, 0, 0, tzinfo=_timezone(_timedelta(hours=-5)))
_OPENED = _NOW - _timedelta(days=1)
_EXPIRES = _NOW + _timedelta(days=30)


def _chain(tmp, **overrides):
    """One authoritative, already-selected Fabric chain, written as records."""
    fabric_root = Path(tmp) / "fabric"
    store = _FabricStore(fabric_root, expected_uid=UID, expected_gid=GID)
    records = {
        "capability-definition": {
            "capability_id": "CAPDEF-0001", "name": "summarise",
            "description": "Condense a document.", "effect_class": "read-only",
            "contract_ids": ["CCON-0001"], "kind": "capability-definition"},
        "capability-contract": {
            "contract_id": "CCON-0001", "capability_id": "CAPDEF-0001",
            "contract_version": "1.0.0", "effect_class": "read-only",
            "determinism_class": "deterministic", "kind": "capability-contract"},
        "capability-package": {
            "capability_package_id": "CPKG-0001", "capability_id": "CAPDEF-0001",
            "contract_id": "CCON-0001", "package_version": "1.0.0",
            "artifact_reference": "file:summarise.py",
            "manifest_reference": "file:summarise.manifest.json",
            "kind": "capability-package"},
        "capability-instance": {
            "instance_id": "CINST-000001", "capability_id": "CAPDEF-0001",
            "capability_package_id": "CPKG-0001", "contract_id": "CCON-0001",
            "capability_host_id": "CHOST-0001", "lifecycle_state": "admitted",
            "admitted_at": _OPENED.isoformat(), "admitted_until": _EXPIRES.isoformat(),
            "admission_decision_id": "CINST-000000", "kind": "capability-instance"},
        "capability-selection": {
            "selection_id": "CSEL-000001", "selected_instance_id": "CINST-000001",
            "selection_reason": "first-eligible-in-declared-order",
            "selected_at": _NOW.isoformat(), "route_id": "CROUTE-0001",
            "route_version": 1, "kind": "capability-selection"},
    }
    for kind, changes in overrides.items():
        if changes is None:
            records.pop(kind, None)
        else:
            records[kind].update(changes)
    for kind, record in records.items():
        identity = record[
            {"capability-definition": "capability_id",
             "capability-contract": "contract_id",
             "capability-package": "capability_package_id",
             "capability-instance": "instance_id",
             "capability-selection": "selection_id"}[kind]]
        store.write_atomic(store.path_for(kind, identity), record)
    return fabric_root


def _verify(fabric_root, **overrides):
    asked = dict(selection_id="CSEL-000001", instance_id="CINST-000001",
                 capability_package_id="CPKG-0001", evaluated_at=_NOW)
    asked.update(overrides)
    return verify_selected_evidence(fabric_root, expected_uid=UID,
                                    expected_gid=GID, **asked)


def _fabric_inventory(base):
    entries = {}
    for path in sorted(Path(base).rglob("*")):
        info = path.lstat()
        entries[str(path.relative_to(base))] = (
            stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), info.st_uid,
            info.st_gid, info.st_ino, info.st_mtime_ns, info.st_size,
            path.read_bytes() if stat.S_ISREG(info.st_mode) else b"")
    return entries


# --- the exact valid chain --------------------------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    verdict = _verify(fabric_root)
    check(verdict.supported, f"an exact selected chain supports preparation ({verdict.reason})")
    check(verdict.reason is None, "a supported verdict names no refusal")
    check(verdict.selection_id == "CSEL-000001", "the verdict carries the selection")
    check(verdict.instance_id == "CINST-000001", "the verdict carries the instance")
    check(verdict.capability_package_id == "CPKG-0001", "the verdict carries the package")
    check(verdict.contract_id == "CCON-0001", "the verdict carries the contract")
    check(verdict.capability_id == "CAPDEF-0001", "the verdict carries the capability")
    check(verdict.effect_class == "read-only", "the verdict carries the effect class")
    check(verdict.artifact_reference == "file:summarise.py",
          "the verdict carries the package artefact reference for A4")
    check(verdict.manifest_reference == "file:summarise.manifest.json",
          "the verdict carries the package manifest reference for A4")

    # A supported verdict is not an execution, and carries nothing executable.
    for absent in ("command", "argv", "environment", "adapter", "network",
                   "staged_path", "process", "executable"):
        check(not hasattr(verdict, absent),
              f"a verdict carries no {absent}")
    check(verdict == _verify(fabric_root), "verification is deterministic")

    # Verifying mutates the Fabric store in no respect.
    before = _fabric_inventory(fabric_root)
    _verify(fabric_root)
    _verify(fabric_root, instance_id="CINST-000009")
    _verify(fabric_root, selection_id="CSEL-000009")
    check(_fabric_inventory(fabric_root) == before,
          "verification leaves the fabric store byte-identical")
    check(sorted(p.name for p in (fabric_root / "sequences").glob("*.seq")) ==
          sorted(p.name for p in (fabric_root / "sequences").glob("*.seq")),
          "verification advances no identifier sequence")
    check(not list(fabric_root.rglob(".*.tmp")),
          "verification leaves no temporary artefact")

# --- missing evidence, one record at a time --------------------------------
for kind, expected, description in (
        ("capability-selection", REASON_SELECTION_ABSENT, "the selection"),
        ("capability-instance", REASON_INSTANCE_ABSENT, "the instance"),
        ("capability-package", REASON_PACKAGE_ABSENT, "the package"),
        ("capability-contract", REASON_CONTRACT_ABSENT, "the contract"),
        ("capability-definition", REASON_CAPABILITY_ABSENT, "the capability")):
    with TemporaryDirectory() as tmp:
        fabric_root = _chain(tmp, **{kind: None})
        verdict = _verify(fabric_root)
        check(not verdict.supported and verdict.reason == expected,
              f"absent {description} refuses as {expected} ({verdict.reason})")

# --- identity mismatch ------------------------------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    verdict = _verify(fabric_root, instance_id="CINST-000002")
    check(not verdict.supported and verdict.reason == REASON_INSTANCE_MISMATCH,
          f"a claimed instance the selection did not choose refuses ({verdict.reason})")
    verdict = _verify(fabric_root, capability_package_id="CPKG-0002")
    check(not verdict.supported and verdict.reason == REASON_PACKAGE_MISMATCH,
          f"a claimed package the instance does not bind refuses ({verdict.reason})")

with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp, **{"capability-instance": {"contract_id": "CCON-0009"}})
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason in (REASON_CONTRACT_ABSENT, REASON_INCOHERENT),
          f"an instance naming an absent contract refuses ({verdict.reason})")

with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp, **{"capability-package": {"contract_id": "CCON-0009"}})
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason == REASON_INCOHERENT,
          f"a package bound to another contract refuses ({verdict.reason})")

with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp, **{"capability-contract": {"capability_id": "CAPDEF-0009"}})
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason == REASON_INCOHERENT,
          f"a contract bound to another capability refuses ({verdict.reason})")

# --- a selection that chose nothing ----------------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp, **{"capability-selection": {"selected_instance_id": None,
                                                          "refusal_reason": "no-eligible-candidate"}})
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason == REASON_SELECTION_REFUSED,
          f"a recorded refusal executes nothing ({verdict.reason})")

# --- lifecycle and window ---------------------------------------------------
for state, expected, description in (
        ("withdrawn", REASON_NOT_ADMITTED, "a withdrawn instance"),
        ("retired", REASON_NOT_ADMITTED, "a retired instance"),
        ("", REASON_NOT_ADMITTED, "an instance with no lifecycle state")):
    with TemporaryDirectory() as tmp:
        fabric_root = _chain(tmp, **{"capability-instance": {"lifecycle_state": state}})
        verdict = _verify(fabric_root)
        check(not verdict.supported and verdict.reason == expected,
              f"{description} refuses as {expected} ({verdict.reason})")

with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp, **{"capability-instance": {"superseded_by": "CINST-000002"}})
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason == REASON_SUPERSEDED,
          f"a superseded instance is not the head and refuses ({verdict.reason})")

for opened, expires, instant, description in (
        (_OPENED, _NOW - _timedelta(days=1), _NOW, "an expired admission window"),
        (_NOW + _timedelta(days=1), _EXPIRES, _NOW, "a window not yet open")):
    with TemporaryDirectory() as tmp:
        fabric_root = _chain(tmp, **{"capability-instance": {
            "admitted_at": opened.isoformat(), "admitted_until": expires.isoformat()}})
        verdict = _verify(fabric_root, evaluated_at=instant)
        check(not verdict.supported and verdict.reason == REASON_WINDOW,
              f"{description} refuses as {REASON_WINDOW} ({verdict.reason})")

with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp, **{"capability-instance": {"admitted_until": "not-a-time"}})
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason == REASON_WINDOW,
          f"an unreadable admission window refuses rather than being guessed ({verdict.reason})")

# --- effect class -----------------------------------------------------------
for effect, supported, description in (
        ("read-only", True, "read-only"),
        ("computational", True, "computational"),
        ("content-generating", True, "content-generating"),
        ("side-effecting", False, "side-effecting"),
        ("", False, "an absent effect class"),
        ("invented", False, "an effect class outside the vocabulary")):
    with TemporaryDirectory() as tmp:
        fabric_root = _chain(tmp, **{"capability-contract": {"effect_class": effect}})
        verdict = _verify(fabric_root)
        if supported:
            check(verdict.supported, f"{description} is executable ({verdict.reason})")
        else:
            check(not verdict.supported and verdict.reason == REASON_EFFECT_CLASS,
                  f"{description} refuses as {REASON_EFFECT_CLASS} ({verdict.reason})")

# --- malformed records and an unusable store -------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    (fabric_root / "capability-selections" / "CSEL-000001.yaml").write_text(
        "{not: [valid", encoding="utf-8")
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason is not None,
          f"a malformed record refuses without a traceback ({verdict.reason})")

with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    (fabric_root / "capability-instances" / "CINST-000001.yaml").write_text(
        "- a\n- b\n", encoding="utf-8")
    verdict = _verify(fabric_root)
    check(not verdict.supported, "a record that is not a mapping refuses")

with TemporaryDirectory() as tmp:
    verdict = _verify(Path(tmp) / "absent")
    check(not verdict.supported and verdict.reason == REASON_UNREADABLE,
          f"an absent fabric store refuses as {REASON_UNREADABLE} ({verdict.reason})")
    check(not (Path(tmp) / "absent").exists(),
          "verifying against an absent store builds nothing")

with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    verdict = _verify(fabric_root, selection_id="../escape")
    check(not verdict.supported,
          "a traversing claimed identity refuses")
    verdict = _verify(fabric_root, selection_id="CINST-000001")
    check(not verdict.supported,
          "a claimed selection carrying another kind's prefix refuses")

# --- symlink containment ----------------------------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    outside = Path(tmp) / "outside"
    outside.mkdir()
    (outside / "planted.yaml").write_text(
        "selection_id: CSEL-000002\nselected_instance_id: CINST-000001\n"
        "kind: capability-selection\n", encoding="utf-8")
    (fabric_root / "capability-selections" / "CSEL-000002.yaml").symlink_to(
        outside / "planted.yaml")
    verdict = _verify(fabric_root, selection_id="CSEL-000002")
    check(not verdict.supported,
          f"a symlinked record cannot smuggle evidence in from outside ({verdict.reason})")

# --- no fallback: the critical authority test -------------------------------
# One claimed chain that refuses, and a perfectly good alternative sitting
# beside it. A runtime that found the alternative would be selecting.
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp, **{"capability-instance": {"lifecycle_state": "withdrawn"}})
    store = _FabricStore(fabric_root, expected_uid=UID, expected_gid=GID)
    store.write_atomic(store.path_for("capability-instance", "CINST-000002"), {
        "instance_id": "CINST-000002", "capability_id": "CAPDEF-0001",
        "capability_package_id": "CPKG-0001", "contract_id": "CCON-0001",
        "capability_host_id": "CHOST-0001", "lifecycle_state": "admitted",
        "admitted_at": _OPENED.isoformat(), "admitted_until": _EXPIRES.isoformat(),
        "admission_decision_id": "CINST-000000", "kind": "capability-instance"})
    store.write_atomic(store.path_for("capability-selection", "CSEL-000002"), {
        "selection_id": "CSEL-000002", "selected_instance_id": "CINST-000002",
        "selection_reason": "first-eligible-in-declared-order",
        "selected_at": _NOW.isoformat(), "route_id": "CROUTE-0001",
        "route_version": 1, "kind": "capability-selection"})
    verdict = _verify(fabric_root)
    check(not verdict.supported and verdict.reason == REASON_NOT_ADMITTED,
          f"the claimed chain refuses on its own terms ({verdict.reason})")
    check(verdict.instance_id is None or verdict.instance_id == "CINST-000001",
          "the refusal never names the alternative instance")
    check("CINST-000002" not in str(verdict),
          "a refused verification does not discover the healthy alternative")
    check("CSEL-000002" not in str(verdict),
          "a refused verification does not discover another selection")

# --- the decision surfaces are not merely unused; they are unreachable ------
_evidence_source = (root / "tools" / "capability" / "fabric_evidence.py").read_text(encoding="utf-8")
for token, description in (
        ("select_candidate", "C6 selection"),
        ("evaluate_eligibility", "C5 eligibility"),
        ("fabric.admission", "the C4 admission module"),
        ("import admission", "the C4 admission module by name"),
        ("admit_instance", "instance admission"),
        ("withdraw_instance", "withdrawal"),
        ("retire_instance", "retirement"),
        ("create_route", "route mutation"),
        ("trust_adapter", "the trust adapter"),
        ("TrustStore", "the trust store"),
        ("request_critical_section", "the fabric request lock"),
        ("allocate_id", "identifier allocation"),
        ("write_atomic", "a fabric write"),
        ("write_record", "a fabric record write"),
        ("FabricStore", "the fabric store itself"),
        ("health", "health")):
    check(token not in _evidence_source,
          f"the evidence reader reaches {description} by no mechanism")

check("from ..fabric.inspection import" in _evidence_source
      or "from ..fabric import inspection" in _evidence_source,
      "the evidence reader consumes fabric through the inspection surface only")

# Structural, not textual: run a real verification with every forbidden
# decision function replaced by something that raises if called.
import tools.fabric.admission as _admission_module  # noqa: E402
import tools.fabric.eligibility as _eligibility_module  # noqa: E402
import tools.fabric.selection as _selection_module  # noqa: E402
import tools.fabric.store as _fabric_store_module  # noqa: E402


def _explode(*args, **kwargs):
    raise AssertionError("a forbidden fabric decision surface was called")


_tripwires = [
    (_selection_module, "select_candidate"),
    (_eligibility_module, "evaluate_eligibility"),
    (_admission_module, "admit_instance"),
    (_admission_module, "admit_subject"),
    (_admission_module, "withdraw_instance"),
    (_admission_module, "retire_instance"),
    (_admission_module, "create_route"),
    (_fabric_store_module.FabricStore, "write_atomic"),
    (_fabric_store_module.FabricStore, "allocate_id"),
    (_fabric_store_module.FabricStore, "request_critical_section"),
]
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    _originals = [(owner, name, getattr(owner, name)) for owner, name in _tripwires]
    for owner, name in _tripwires:
        setattr(owner, name, _explode)
    try:
        armed = _verify(fabric_root)
        refused = _verify(fabric_root, instance_id="CINST-000002")
        tripped = None
    except AssertionError as error:
        armed = refused = None
        tripped = str(error)
    finally:
        for owner, name, original in _originals:
            setattr(owner, name, original)
    check(tripped is None,
          f"no forbidden fabric decision surface is called during verification ({tripped})")
    check(armed is not None and armed.supported,
          "verification still succeeds with every decision surface armed to explode")
    check(refused is not None and not refused.supported,
          "refusal still works with every decision surface armed to explode")

# --- A3 creates no durable capability evidence ------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = _chain(tmp)
    capability_store = CapabilityStore(Path(tmp) / "capability",
                                       expected_uid=UID, expected_gid=GID)
    before = inventory(capability_store.root)
    _verify(fabric_root)
    _verify(fabric_root, instance_id="CINST-000002")
    check(inventory(capability_store.root) == before,
          "verification writes no capability runtime record")
    check(capability_store.counts() == {"capability-invocation": 0,
                                        "capability-result": 0},
          "verification allocates no invocation or result identity")

# ===========================================================================
# Deferred E — the descriptor-safe trusted-source primitive
# ===========================================================================
# Reading a file you do not control is a different problem from writing one you
# do. Containment answers "is this name inside that directory?", which is
# necessary and not sufficient: between resolving a name and opening it, whoever
# can write the directory gets a turn. So this opens once, without following a
# final link, and then asks the descriptor what it got -- never the path again.
#
# It reads. It creates nothing, changes nothing, and removes nothing.

from tools.common.trusted_source import (  # noqa: E402
    TrustedSourceError, open_trusted_regular_file)


def refuses_source(action, message):
    try:
        handle = action()
    except TrustedSourceError:
        ok(message)
    except Exception as error:  # noqa: BLE001
        bad(f"{message} (raised {type(error).__name__}: {error})")
    else:
        os.close(handle)
        bad(f"{message} (was accepted instead of refused)")


def _trusted_tree(tmp, content=b"artifact bytes\n"):
    """An approved root satisfying the source contract, and one file in it."""
    approved = Path(tmp) / "approved"
    approved.mkdir(mode=0o755)
    nested = approved / "nested"
    nested.mkdir(mode=0o755)
    target = nested / "artifact.bin"
    target.write_bytes(content)
    target.chmod(0o644)
    return approved, target


def _read_all(handle):
    chunks = []
    while True:
        chunk = os.read(handle, 4096)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


# --- the valid case ---------------------------------------------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    handle = open_trusted_regular_file(approved, "nested/artifact.bin",
                                       expected_uid=UID)
    try:
        check(isinstance(handle, int), "a descriptor is returned, not a path")
        check(_read_all(handle) == b"artifact bytes\n",
              "the descriptor yields the file's bytes")
        opened = os.fstat(handle)
        actual = target.lstat()
        check(opened.st_ino == actual.st_ino and opened.st_dev == actual.st_dev,
              "the descriptor is bound to the file that was checked")
    finally:
        os.close(handle)

    handle = open_trusted_regular_file(approved, "nested/artifact.bin",
                                       expected_uid=UID, require_single_link=True)
    os.close(handle)
    ok("a single-linked file is accepted when link count is required")

    # Bounded reads: the caller says how much it is willing to read.
    handle = open_trusted_regular_file(approved, "nested/artifact.bin",
                                       expected_uid=UID, maximum_bytes=5)
    try:
        check(os.fstat(handle).st_size > 5,
              "the bound is not a claim about the file's size")
    finally:
        os.close(handle)
    refuses_source(lambda: open_trusted_regular_file(
        approved, "nested/artifact.bin", expected_uid=UID, maximum_bytes=3,
        refuse_oversize=True),
        "a file larger than the supplied bound refuses before it is read")

# --- containment: traversal, escape, prefix ---------------------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    outside = Path(tmp) / "outside"
    outside.mkdir(mode=0o755)
    (outside / "secret.bin").write_bytes(b"secret\n")
    sibling = Path(tmp) / "approvedbar"
    sibling.mkdir(mode=0o755)
    (sibling / "x.bin").write_bytes(b"x\n")

    for name, description in (
            ("../outside/secret.bin", "a traversing name"),
            ("nested/../../outside/secret.bin", "a traversal through a child"),
            (str(outside / "secret.bin"), "an absolute path outside the root"),
            ("../approvedbar/x.bin", "a sibling sharing the root's name prefix"),
            (str(sibling / "x.bin"), "an absolute sibling sharing the prefix"),
            (".", "the approved root itself"),
            ("", "an empty name"),
            ("nested", "a directory as the final target"),
            ("missing.bin", "a file that is not there"),
            ("nodir/missing.bin", "a parent that is not there")):
        refuses_source(lambda n=name: open_trusted_regular_file(
            approved, n, expected_uid=UID), f"{description} is refused")

# --- symlinks, at every position -------------------------------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    outside = Path(tmp) / "outside"
    outside.mkdir(mode=0o755)
    (outside / "secret.bin").write_bytes(b"secret\n")

    (approved / "nested" / "link-outside").symlink_to(outside / "secret.bin")
    (approved / "nested" / "link-inside").symlink_to(target)
    (approved / "linkdir").symlink_to(outside)
    for name, description in (
            ("nested/link-outside", "a final component symlinked out of the root"),
            ("nested/link-inside", "a final component symlinked inside the root"),
            ("linkdir/secret.bin", "a symlinked parent directory")):
        refuses_source(lambda n=name: open_trusted_regular_file(
            approved, n, expected_uid=UID), f"{description} is refused")

with TemporaryDirectory() as tmp:
    outside = Path(tmp) / "elsewhere"
    outside.mkdir(mode=0o755)
    (outside / "artifact.bin").write_bytes(b"x\n")
    linked_root = Path(tmp) / "approved"
    linked_root.symlink_to(outside)
    refuses_source(lambda: open_trusted_regular_file(
        linked_root, "artifact.bin", expected_uid=UID),
        "a symlinked approved root is refused")

# --- ownership --------------------------------------------------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    for uid, description in ((UID + 1, "a file owned by another uid"),
                             (0, "a file expected to be root-owned")):
        refuses_source(lambda u=uid: open_trusted_regular_file(
            approved, "nested/artifact.bin", expected_uid=u),
            f"{description} is refused")
    refuses_source(lambda: open_trusted_regular_file(
        approved, "nested/artifact.bin", expected_uid=None),
        "an absent expected uid is refused rather than defaulted")
    refuses_source(lambda: open_trusted_regular_file(
        approved, "nested/artifact.bin", expected_uid="1000"),
        "a non-integer expected uid is refused")
    refuses_source(lambda: open_trusted_regular_file(
        approved, "nested/artifact.bin", expected_uid=True),
        "a boolean masquerading as a uid is refused")

# --- writability, at every position ----------------------------------------
for position, mode, description in (
        ("root", 0o775, "a group-writable approved root"),
        ("root", 0o757, "a world-writable approved root"),
        ("parent", 0o775, "a group-writable parent directory"),
        ("parent", 0o757, "a world-writable parent directory"),
        ("file", 0o664, "a group-writable file"),
        ("file", 0o646, "a world-writable file")):
    with TemporaryDirectory() as tmp:
        approved, target = _trusted_tree(tmp)
        if position == "root":
            approved.chmod(mode)
        elif position == "parent":
            (approved / "nested").chmod(mode)
        else:
            target.chmod(mode)
        refuses_source(lambda: open_trusted_regular_file(
            approved, "nested/artifact.bin", expected_uid=UID),
            f"{description} is refused")

with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    approved.chmod(0o755)
    (approved / "nested").chmod(0o755)
    target.chmod(0o644)
    handle = open_trusted_regular_file(approved, "nested/artifact.bin", expected_uid=UID)
    os.close(handle)
    ok("group and other may read and traverse; they may not write")

# --- file type --------------------------------------------------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    fifo = approved / "nested" / "pipe"
    os.mkfifo(fifo, 0o644)
    refuses_source(lambda: open_trusted_regular_file(
        approved, "nested/pipe", expected_uid=UID), "a FIFO is refused")
    check(fifo.exists(), "the refused FIFO is left alone")

    import socket as _socket  # noqa: E402  (test harness only, never production)
    sock = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    try:
        sock.bind(str(approved / "nested" / "sock"))
        (approved / "nested" / "sock").chmod(0o644)
        refuses_source(lambda: open_trusted_regular_file(
            approved, "nested/sock", expected_uid=UID), "a unix socket is refused")
    finally:
        sock.close()

    for device, description in (("/dev/null", "a character device"),):
        if Path(device).exists():
            refuses_source(lambda d=device: open_trusted_regular_file(
                Path("/dev"), Path(d).name, expected_uid=0),
                f"{description} is refused")

# --- hard links -------------------------------------------------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    alias = approved / "nested" / "alias.bin"
    os.link(target, alias)
    check(target.lstat().st_nlink == 2, "the fixture really created a second link")
    refuses_source(lambda: open_trusted_regular_file(
        approved, "nested/artifact.bin", expected_uid=UID, require_single_link=True),
        "a file with a second hard link is refused when a single link is required")
    handle = open_trusted_regular_file(approved, "nested/artifact.bin", expected_uid=UID)
    os.close(handle)
    ok("the link-count rule is the caller's to require, not a silent default")

# --- the race the primitive exists to close --------------------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp, content=b"ORIGINAL\n")
    handle = open_trusted_regular_file(approved, "nested/artifact.bin", expected_uid=UID)
    try:
        # The pathname now names entirely different bytes. Anything reading by
        # path would see them; a descriptor cannot.
        replacement = approved / "nested" / "replacement.bin"
        replacement.write_bytes(b"SUBSTITUTED\n")
        replacement.chmod(0o644)
        os.replace(replacement, target)
        check(target.read_bytes() == b"SUBSTITUTED\n",
              "the fixture really replaced the pathname's contents")
        check(_read_all(handle) == b"ORIGINAL\n",
              "the descriptor still yields the bytes that were validated")
        os.lseek(handle, 0, os.SEEK_SET)
        check(_read_all(handle) == b"ORIGINAL\n",
              "re-reading the descriptor yields the same validated bytes")
    finally:
        os.close(handle)

# --- the primitive creates, changes, and removes nothing -------------------
with TemporaryDirectory() as tmp:
    approved, target = _trusted_tree(tmp)
    (approved / "nested" / "link-outside").symlink_to(Path(tmp) / "nowhere")

    def source_inventory(base):
        entries = {}
        for path in sorted(Path(base).rglob("*")):
            info = path.lstat()
            entries[str(path.relative_to(base))] = (
                stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode),
                info.st_uid, info.st_gid, info.st_ino, info.st_mtime_ns,
                info.st_size)
        return entries

    before = source_inventory(tmp)
    for name in ("nested/artifact.bin", "../escape", "missing.bin", "nested",
                 "nested/link-outside", "", "."):
        try:
            handle = open_trusted_regular_file(approved, name, expected_uid=UID)
            os.close(handle)
        except TrustedSourceError:
            pass
    check(source_inventory(tmp) == before,
          "opening and refusing creates, changes, and removes nothing")

    absent_root = Path(tmp) / "never"
    refuses_source(lambda: open_trusted_regular_file(
        absent_root, "x.bin", expected_uid=UID),
        "an absent approved root is refused")
    check(not absent_root.exists(), "an absent approved root stays absent")

# --- the primitive never writes ---------------------------------------------
_source_module = (root / "tools" / "common" / "trusted_source.py").read_text(encoding="utf-8")
# The mechanisms, not the English. The invariant is that this module cannot
# write; forbidding the word would also forbid "writable", which is the
# vocabulary the module is built out of.
for token, description in (("O_WRONLY", "a write mode"), ("O_RDWR", "a read-write mode"),
                           ("O_CREAT", "a creation flag"), ("O_TRUNC", "a truncation flag"),
                           ("O_APPEND", "an append flag"),
                           ("os.chmod", "a mode change"), ("os.chown", "an owner change"),
                           ("os.unlink", "a deletion"), ("os.remove", "a removal"),
                           ("os.rmdir", "a directory removal"),
                           ("os.mkdir", "a directory creation"),
                           ("os.makedirs", "a directory tree creation"),
                           ("os.rename", "a rename"), ("os.replace", "a replacement"),
                           ("os.write", "a write"), ("os.truncate", "a truncation"),
                           (".write(", "a write call"), (".write_text(", "a text write"),
                           (".write_bytes(", "a byte write"), ("shutil", "a copy tool")):
    check(token not in _source_module,
          f"the trusted-source primitive contains no {description}")
check("O_NOFOLLOW" in _source_module,
      "the final component is opened without following a link")
check("fstat" in _source_module,
      "validation is performed on the descriptor rather than the path")

# ===========================================================================
# A4 — executable package resolution, integrity, and content-addressed staging
# ===========================================================================
# Turning a governed package into verified bytes, or refusing. The source path
# is discovery input; the staged object is what a future adapter may receive,
# and the two are connected by exactly one descriptor.
#
# Nothing here executes, imports, or loads an artefact. It is read and hashed.

import hashlib as _hashlib2  # noqa: E402
import json as _json  # noqa: E402

from tools.capability.package_resolution import (  # noqa: E402
    ARTIFACT_MAXIMUM_BYTES, MANIFEST_MAXIMUM_BYTES, MANIFEST_SCHEMA_VERSION,
    REASON_ARTIFACT_OVERSIZE, REASON_ARTIFACT_UNREADABLE, REASON_GRAMMAR,
    REASON_MANIFEST_ABSENT, REASON_MANIFEST_IDENTITY, REASON_MANIFEST_MALFORMED,
    REASON_MANIFEST_SCHEMA, REASON_MANIFEST_UNREADABLE, REASON_STAGED_COLLISION,
    REASON_STAGED_UNUSABLE, REASON_STAGING_ROOT, REASON_SUBSTITUTION,
    resolve_and_stage_package, _bounded_digest_and_copy)
from tools.capability.fabric_evidence import EvidenceVerdict  # noqa: E402

_BYTES = b"the artifact bytes\n"
_DIGEST = "sha256:" + _hashlib2.sha256(_BYTES).hexdigest()


def _manifest(**overrides):
    body = {
        "schema_version": 1,
        "capability_package_id": "CPKG-0001",
        "contract_id": "CCON-0001",
        "capability_id": "CAPDEF-0001",
        "artifact_reference": "file:nested/artifact.bin",
        "artifact_sha256": _DIGEST,
    }
    for key, value in overrides.items():
        if value is _REMOVE:
            body.pop(key, None)
        else:
            body[key] = value
    return body


class _Remove:
    pass


_REMOVE = _Remove()


def _evidence(**overrides):
    fields = dict(supported=True, reason=None, selection_id="CSEL-000001",
                  instance_id="CINST-000001", capability_package_id="CPKG-0001",
                  contract_id="CCON-0001", capability_id="CAPDEF-0001",
                  effect_class="read-only",
                  artifact_reference="file:nested/artifact.bin",
                  manifest_reference="file:nested/artifact.manifest.json")
    fields.update(overrides)
    return EvidenceVerdict(**fields)


def _source(tmp, *, content=_BYTES, manifest=None, manifest_text=None):
    approved = Path(tmp) / "approved"
    approved.mkdir(mode=0o755, exist_ok=True)
    nested = approved / "nested"
    nested.mkdir(mode=0o755, exist_ok=True)
    artifact = nested / "artifact.bin"
    artifact.write_bytes(content)
    artifact.chmod(0o644)
    body = _json.dumps(_manifest() if manifest is None else manifest)
    (nested / "artifact.manifest.json").write_text(
        body if manifest_text is None else manifest_text, encoding="utf-8")
    (nested / "artifact.manifest.json").chmod(0o644)
    return approved, artifact


def _staging(tmp):
    staging = Path(tmp) / "staging"
    staging.mkdir(mode=0o700, exist_ok=True)
    return staging


def _stage(tmp, *, evidence=None, approved=None, staging=None, **overrides):
    asked = dict(evidence=evidence or _evidence(),
                 approved_artifact_root=approved,
                 trusted_source_uid=UID,
                 staging_root=staging,
                 coordinator_uid=UID)
    asked.update(overrides)
    return resolve_and_stage_package(**asked)


# --- the valid case ---------------------------------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    result = _stage(tmp, approved=approved, staging=staging)
    check(result.supported, f"a conforming package stages ({result.reason})")
    check(result.reason is None, "a supported result names no refusal")
    check(result.artifact_sha256 == _DIGEST, "the verified digest is returned")
    check(result.capability_package_id == "CPKG-0001", "the package identity is returned")
    check(result.manifest_version == MANIFEST_SCHEMA_VERSION,
          "the validated manifest version is returned")

    staged = Path(result.staged_path)
    check(staged.is_file(), "the staged artefact exists")
    check(staged.read_bytes() == _BYTES, "the staged bytes are the source bytes")
    check(staged.parent.name == "sha256-" + _DIGEST.split(":")[1],
          f"the staged identity derives from the verified digest ({staged.parent.name})")
    check(staged.name == "artifact", "the staged object has a fixed name")
    check(stat.S_IMODE(staged.lstat().st_mode) == 0o400,
          f"the staged artefact is 0400 ({oct(stat.S_IMODE(staged.lstat().st_mode))})")
    check(stat.S_IMODE(staged.parent.lstat().st_mode) == 0o700,
          f"the staged directory is 0700 ({oct(stat.S_IMODE(staged.parent.lstat().st_mode))})")
    check(staged.lstat().st_uid == UID, "the staged artefact is coordinator-owned")
    check(staged.lstat().st_nlink == 1, "the staged artefact carries a single link")
    check(not stat.S_IMODE(staged.lstat().st_mode) & 0o111,
          "the staged artefact is not executable")
    check(not stat.S_IMODE(staged.lstat().st_mode) & 0o066,
          "the staged artefact is not group- or world-accessible for writing")

    # The result carries preparation facts, and nothing that runs anything.
    for absent in ("command", "argv", "environment", "shell", "process", "pid",
                   "adapter", "image", "endpoint", "network", "secret", "result"):
        check(not hasattr(result, absent), f"the staged result carries no {absent}")

    # Nothing was written on the source side.
    def inventory_of(base):
        entries = {}
        for path in sorted(Path(base).rglob("*")):
            info = path.lstat()
            entries[str(path.relative_to(base))] = (
                stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), info.st_uid,
                info.st_ino, info.st_mtime_ns, info.st_size)
        return entries

    source_before = inventory_of(approved)
    again = _stage(tmp, approved=approved, staging=staging)
    check(again.supported and again.staged_path == result.staged_path,
          "identical content converges on the same staged identity")
    check(inventory_of(approved) == source_before,
          "staging writes nothing on the source side")
    check(len(list(staging.glob("sha256-*"))) == 1,
          "identical content produces exactly one staged object")

# --- artefact reference grammar --------------------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    for reference, description in (
            ("nested/artifact.bin", "a bare relative path"),
            ("/etc/hostname", "an absolute path"),
            ("file:/absolute/path", "an absolute path behind the scheme"),
            ("file://host/path", "an authority form"),
            ("oci://registry.invalid/x", "an oci reference"),
            ("http://example.invalid/x", "an http reference"),
            ("https://example.invalid/x", "an https reference"),
            ("docker://x", "a docker reference"),
            ("podman://x", "a podman reference"),
            ("file:../outside/x", "a traversing reference"),
            ("file:nested/../../outside/x", "a traversal through a child"),
            ("$(echo pwned)", "shell-like text"),
            ("file:", "an empty relative path"),
            ("", "an empty reference"),
            ("   ", "a whitespace-only reference"),
            ("FILE:nested/artifact.bin", "an uppercase scheme"),
            ("file:nested/\x00artifact.bin", "a reference carrying a null byte")):
        outcome = _stage(tmp, approved=approved, staging=staging,
                         evidence=_evidence(artifact_reference=reference))
        check(not outcome.supported and outcome.reason == REASON_GRAMMAR,
              f"{description} refuses as {REASON_GRAMMAR} ({outcome.reason})")

    outcome = _stage(tmp, approved=approved, staging=staging,
                     evidence=_evidence(manifest_reference=None))
    check(not outcome.supported and outcome.reason == REASON_MANIFEST_ABSENT,
          f"a package with no manifest reference refuses ({outcome.reason})")
    outcome = _stage(tmp, approved=approved, staging=staging,
                     evidence=_evidence(manifest_reference="oci://x"))
    check(not outcome.supported and outcome.reason == REASON_GRAMMAR,
          f"a manifest reference outside the grammar refuses ({outcome.reason})")

# --- trusted-source policy wiring ------------------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    outcome = _stage(tmp, approved=approved, staging=staging, trusted_source_uid=UID + 1)
    check(not outcome.supported and outcome.reason == REASON_MANIFEST_UNREADABLE,
          f"a wrong trusted source uid refuses ({outcome.reason})")
    for supplied, description in ((None, "an absent"), ("1000", "a non-integer"),
                                  (True, "a boolean")):
        outcome = _stage(tmp, approved=approved, staging=staging,
                         trusted_source_uid=supplied)
        check(not outcome.supported,
              f"{description} trusted source uid refuses rather than defaulting")

_resolution_source = (root / "tools" / "capability" / "package_resolution.py").read_text(encoding="utf-8")
check(_resolution_source.count("require_single_link=True") >= 2,
      "both source files are opened requiring a single link")
check("open_trusted_regular_file" in _resolution_source,
      "the reviewed trusted-source primitive is used")
for forbidden, description in (("os.getuid", "the running process"),
                               ("os.geteuid", "the effective process"),
                               ("getpass", "the login user"),
                               ("environ", "the environment"),
                               ("expanduser", "a home directory")):
    check(forbidden not in _resolution_source,
          f"the trusted uid is never taken from {description}")

# Every source-side open goes through the reviewed primitive. The module does
# open one path of its own -- the published staged object, to re-verify it --
# and that is coordinator-controlled, which is the whole distinction.
# Three occurrences and no more: the parameter, and the two primitive calls.
# A fourth would be the module doing something with the source root itself.
check(_resolution_source.count("approved_artifact_root") == 3,
      "the approved artefact root appears only as the parameter and its two "
      f"primitive calls ({_resolution_source.count('approved_artifact_root')})")
for call in ("open_trusted_regular_file(\n            approved_artifact_root, manifest_relative",
             "open_trusted_regular_file(\n            approved_artifact_root, artifact_relative"):
    check(call in _resolution_source,
          "both source files are opened through the reviewed primitive")
check(_resolution_source.count("os.open(") == 1,
      f"the module opens exactly one path of its own, the staged object "
      f"({_resolution_source.count('os.open(')})")
check("os.open(final" in _resolution_source,
      "the one direct open is of the coordinator-controlled staged object")

# --- source ownership, mode, type, and link policy -------------------------
for mutate, description in (
        (lambda a, t: (a / "nested").chmod(0o775), "a group-writable source directory"),
        (lambda a, t: (a / "nested").chmod(0o757), "a world-writable source directory"),
        (lambda a, t: t.chmod(0o664), "a group-writable artefact"),
        (lambda a, t: t.chmod(0o646), "a world-writable artefact"),
        (lambda a, t: (a / "nested" / "artifact.manifest.json").chmod(0o664),
         "a group-writable manifest"),
        (lambda a, t: os.link(t, a / "nested" / "alias.bin"), "an aliased artefact"),
        (lambda a, t: os.link(a / "nested" / "artifact.manifest.json",
                              a / "nested" / "alias.json"), "an aliased manifest"),
        (lambda a, t: (t.unlink(), t.symlink_to(a / "nested" / "other.bin")),
         "a symlinked artefact")):
    with TemporaryDirectory() as tmp:
        approved, artifact = _source(tmp)
        staging = _staging(tmp)
        (approved / "nested" / "other.bin").write_bytes(_BYTES)
        mutate(approved, artifact)
        outcome = _stage(tmp, approved=approved, staging=staging)
        check(not outcome.supported, f"{description} refuses ({outcome.reason})")

# --- manifest schema, field by field ---------------------------------------
with TemporaryDirectory() as tmp:
    staging = _staging(tmp)
    for overrides, expected, description in (
            ({"schema_version": _REMOVE}, REASON_MANIFEST_SCHEMA, "a missing schema_version"),
            ({"schema_version": 2}, REASON_MANIFEST_SCHEMA, "a future schema_version"),
            ({"schema_version": "1"}, REASON_MANIFEST_SCHEMA, "a string schema_version"),
            ({"schema_version": True}, REASON_MANIFEST_SCHEMA, "a boolean schema_version"),
            ({"capability_package_id": _REMOVE}, REASON_MANIFEST_SCHEMA, "a missing package identity"),
            ({"capability_package_id": 1}, REASON_MANIFEST_SCHEMA, "a non-string package identity"),
            ({"capability_package_id": "CPKG-0009"}, REASON_MANIFEST_IDENTITY, "a mismatched package identity"),
            ({"contract_id": _REMOVE}, REASON_MANIFEST_SCHEMA, "a missing contract identity"),
            ({"contract_id": "CCON-0009"}, REASON_MANIFEST_IDENTITY, "a mismatched contract identity"),
            ({"capability_id": _REMOVE}, REASON_MANIFEST_SCHEMA, "a missing capability identity"),
            ({"capability_id": "CAPDEF-0009"}, REASON_MANIFEST_IDENTITY, "a mismatched capability identity"),
            ({"artifact_reference": _REMOVE}, REASON_MANIFEST_SCHEMA, "a missing artefact reference"),
            ({"artifact_reference": "file:nested/other.bin"}, REASON_MANIFEST_IDENTITY,
             "a manifest naming another artefact"),
            ({"artifact_reference": "oci://x"}, REASON_MANIFEST_SCHEMA,
             "a manifest reference outside the grammar"),
            ({"artifact_sha256": _REMOVE}, REASON_MANIFEST_SCHEMA, "a missing digest"),
            ({"artifact_sha256": _DIGEST.upper()}, REASON_MANIFEST_SCHEMA, "an uppercase digest"),
            ({"artifact_sha256": "sha512:" + "a" * 128}, REASON_MANIFEST_SCHEMA, "another algorithm"),
            ({"artifact_sha256": "sha256:" + "a" * 63}, REASON_MANIFEST_SCHEMA, "a short digest"),
            ({"artifact_sha256": " " + _DIGEST}, REASON_MANIFEST_SCHEMA, "a digest with whitespace"),
            ({"artifact_sha256": "sha256:" + "g" * 64}, REASON_MANIFEST_SCHEMA, "a non-hex digest"),
            ({"unexpected": "field"}, REASON_MANIFEST_SCHEMA, "an unknown seventh field")):
        with TemporaryDirectory() as inner:
            approved, artifact = _source(inner, manifest=_manifest(**overrides))
            (approved / "nested" / "other.bin").write_bytes(b"other\n")
            outcome = _stage(inner, approved=approved, staging=_staging(inner))
            check(not outcome.supported and outcome.reason == expected,
                  f"{description} refuses as {expected} ({outcome.reason})")

    for text, description in (("{not json", "malformed JSON"),
                              ("[1, 2]", "a JSON array"),
                              ('"text"', "a JSON string"),
                              ("null", "JSON null"),
                              ("", "an empty manifest")):
        with TemporaryDirectory() as inner:
            approved, artifact = _source(inner, manifest_text=text)
            outcome = _stage(inner, approved=approved, staging=_staging(inner))
            check(not outcome.supported and outcome.reason == REASON_MANIFEST_MALFORMED,
                  f"{description} refuses as {REASON_MANIFEST_MALFORMED} ({outcome.reason})")

# --- digest verification ----------------------------------------------------
for content, description in ((b"", "an empty artefact"),
                             (b"\x00\x01\x02\xff", "binary bytes"),
                             (b"x" * 200000, "a multi-chunk artefact")):
    with TemporaryDirectory() as tmp:
        digest = "sha256:" + _hashlib2.sha256(content).hexdigest()
        approved, artifact = _source(tmp, content=content,
                                     manifest=_manifest(artifact_sha256=digest))
        outcome = _stage(tmp, approved=approved, staging=_staging(tmp))
        check(outcome.supported and outcome.artifact_sha256 == digest,
              f"{description} verifies against its known digest ({outcome.reason})")
        check(Path(outcome.staged_path).read_bytes() == content,
              f"{description} stages byte-for-byte")

for content, description in ((_BYTES[:-1], "a truncated artefact"),
                             (_BYTES + b"x", "an appended artefact"),
                             (b"T" + _BYTES[1:], "a one-byte mutation")):
    with TemporaryDirectory() as tmp:
        approved, artifact = _source(tmp, content=content)
        outcome = _stage(tmp, approved=approved, staging=_staging(tmp))
        check(not outcome.supported and outcome.reason == REASON_SUBSTITUTION,
              f"{description} refuses as {REASON_SUBSTITUTION} ({outcome.reason})")
        check(not list(_staging(tmp).glob("sha256-*")),
              f"{description} stages nothing")

# --- bounds -----------------------------------------------------------------
check(MANIFEST_MAXIMUM_BYTES == 65536, f"the manifest bound is 65536 ({MANIFEST_MAXIMUM_BYTES})")
check(ARTIFACT_MAXIMUM_BYTES == 268435456, f"the artefact bound is 268435456 ({ARTIFACT_MAXIMUM_BYTES})")

with TemporaryDirectory() as tmp:
    # A valid manifest padded to exactly the bound, and one byte beyond it.
    for size, supported, description in ((MANIFEST_MAXIMUM_BYTES, True, "a manifest at the bound"),
                                         (MANIFEST_MAXIMUM_BYTES + 1, False, "a manifest one byte over")):
        with TemporaryDirectory() as inner:
            base = _json.dumps(_manifest(), separators=(",", ":"))
            padding = size - len(base) - len('{"":,}') - 1
            text = '{"' + " " * 0 + base[1:-1] + "}"
            text = base[:-1] + "," + '"x"' + ":" + '"' + "p" * max(padding - 6, 0) + '"' + "}"
            text = text + " " * max(0, size - len(text))
            approved, artifact = _source(inner, manifest_text=text[:size])
            outcome = _stage(inner, approved=approved, staging=_staging(inner))
            # Padding makes the schema closed-invalid; what is proven here is
            # which refusal the size produces, not that padding is legal.
            if supported:
                check(outcome.reason != REASON_MANIFEST_UNREADABLE,
                      f"{description} is read rather than refused for size ({outcome.reason})")
            else:
                check(outcome.reason == REASON_MANIFEST_UNREADABLE,
                      f"{description} refuses before it is read ({outcome.reason})")

with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    # A sparse file: the size bound refuses on the descriptor's own report,
    # before a quarter of a gigabyte is ever read.
    os.truncate(artifact, ARTIFACT_MAXIMUM_BYTES + 1)
    outcome = _stage(tmp, approved=approved, staging=_staging(tmp))
    check(not outcome.supported and outcome.reason == REASON_ARTIFACT_OVERSIZE,
          f"an artefact one byte over the bound refuses ({outcome.reason})")
    check(not list(_staging(tmp).glob("sha256-*")), "an oversized artefact stages nothing")

# The bound is enforced while reading, not only from the reported size.
with TemporaryDirectory() as tmp:
    probe = Path(tmp) / "probe.bin"
    probe.write_bytes(b"0123456789A")
    handle = os.open(probe, os.O_RDONLY)
    try:
        refused = False
        try:
            _bounded_digest_and_copy(handle, None, 10)
        except Exception:  # noqa: BLE001
            refused = True
        check(refused, "the copy refuses once more than the bound would be consumed")
    finally:
        os.close(handle)

# --- staging root contract --------------------------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    for mutate, description in (
            (lambda s: s.chmod(0o770), "a group-writable staging root"),
            (lambda s: s.chmod(0o707), "a world-writable staging root")):
        staging = _staging(tmp)
        mutate(staging)
        outcome = _stage(tmp, approved=approved, staging=staging)
        check(not outcome.supported and outcome.reason == REASON_STAGING_ROOT,
              f"{description} refuses ({outcome.reason})")
        staging.chmod(0o700)

    outcome = _stage(tmp, approved=approved, staging=staging, coordinator_uid=UID + 1)
    check(not outcome.supported and outcome.reason == REASON_STAGING_ROOT,
          f"a staging root owned by another uid refuses ({outcome.reason})")

with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    outside = Path(tmp) / "elsewhere"
    outside.mkdir(mode=0o700)
    linked = Path(tmp) / "staging-link"
    linked.symlink_to(outside)
    outcome = _stage(tmp, approved=approved, staging=linked)
    check(not outcome.supported and outcome.reason == REASON_STAGING_ROOT,
          f"a symlinked staging root refuses ({outcome.reason})")

with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    outcome = _stage(tmp, approved=approved, staging=Path(tmp) / "absent")
    check(not outcome.supported and outcome.reason == REASON_STAGING_ROOT,
          f"an absent staging root refuses rather than being created ({outcome.reason})")
    check(not (Path(tmp) / "absent").exists(), "an absent staging root stays absent")

# --- an existing final object ----------------------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    first = _stage(tmp, approved=approved, staging=staging)
    staged = Path(first.staged_path)
    original = staged.lstat()

    reused = _stage(tmp, approved=approved, staging=staging)
    check(reused.supported and Path(reused.staged_path).lstat().st_ino == original.st_ino,
          "identical bytes reuse the existing staged object rather than republishing")

    # Same digest identity, different bytes: fail closed, never repair.
    staged.chmod(0o600)
    staged.write_bytes(b"substituted\n")
    staged.chmod(0o400)
    before = (staged.lstat().st_ino, staged.read_bytes())
    outcome = _stage(tmp, approved=approved, staging=staging)
    check(not outcome.supported and outcome.reason == REASON_STAGED_COLLISION,
          f"a staged object whose bytes do not match its digest refuses ({outcome.reason})")
    check((staged.lstat().st_ino, staged.read_bytes()) == before,
          "the incoherent staged object is neither replaced nor repaired")

for mutate, description in (
        (lambda p: p.chmod(0o444), "a staged object with a widened mode"),
        (lambda p: p.chmod(0o600), "a staged object that became writable"),
        (lambda p: (p.unlink(), p.symlink_to("/etc/hostname")), "a staged object replaced by a symlink"),
        (lambda p: (p.unlink(), p.mkdir()), "a staged object replaced by a directory")):
    with TemporaryDirectory() as tmp:
        approved, artifact = _source(tmp)
        staging = _staging(tmp)
        first = _stage(tmp, approved=approved, staging=staging)
        staged = Path(first.staged_path)
        staged.parent.chmod(0o700)
        mutate(staged)
        outcome = _stage(tmp, approved=approved, staging=staging)
        check(not outcome.supported and outcome.reason in
              (REASON_STAGED_UNUSABLE, REASON_STAGED_COLLISION),
              f"{description} refuses ({outcome.reason})")

# --- temporary residue ------------------------------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    first = _stage(tmp, approved=approved, staging=staging)
    staged = Path(first.staged_path)
    # An interrupted publication's residue: present, and never mistaken for
    # content or removed by a later run.
    residue = staging / ".interrupted.tmp"
    residue.write_bytes(b"partial")
    residue.chmod(0o400)
    residue_before = (residue.lstat().st_ino, residue.read_bytes())
    again = _stage(tmp, approved=approved, staging=staging)
    check(again.supported, "residue does not block an otherwise valid staging")
    check(residue.exists(), "residue is left where it was found")
    check((residue.lstat().st_ino, residue.read_bytes()) == residue_before,
          "residue is neither reused nor rewritten")
    check(Path(again.staged_path) == staged,
          "residue does not become the staged object")

# --- no execution, whatever the bytes look like ----------------------------
with TemporaryDirectory() as tmp:
    marker = Path(tmp) / "marker"
    hostile = (
        "import pathlib\n"
        f"pathlib.Path({str(marker)!r}).write_text('imported')\n"
        "print('executed')\n"
    ).encode("utf-8")
    digest = "sha256:" + _hashlib2.sha256(hostile).hexdigest()
    approved, artifact = _source(tmp, content=hostile,
                                 manifest=_manifest(artifact_sha256=digest))
    outcome = _stage(tmp, approved=approved, staging=_staging(tmp))
    check(outcome.supported, f"an artefact that would run if imported still stages ({outcome.reason})")
    check(not marker.exists(),
          "the artefact was read and hashed, never imported or executed")
    check(Path(outcome.staged_path).read_bytes() == hostile,
          "hostile-looking bytes are staged unchanged, as data")

# --- the source-replacement race -------------------------------------------
# A4 must obtain artefact bytes only from the descriptor the primitive opened.
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    substitute = approved / "nested" / "substitute.bin"
    substitute.write_bytes(b"SUBSTITUTED BYTES\n")
    substitute.chmod(0o644)

    import tools.capability.package_resolution as _a4  # noqa: E402
    _original_open = _a4.open_trusted_regular_file
    swapped = {"count": 0}

    def _swapping_open(*args, **kwargs):
        handle = _original_open(*args, **kwargs)
        # Once the artefact is open, the pathname is replaced. Anything
        # reopening it would read the substitute; a descriptor cannot.
        if swapped["count"] == 1:
            os.replace(substitute, artifact)
        swapped["count"] += 1
        return handle

    _a4.open_trusted_regular_file = _swapping_open
    try:
        outcome = _stage(tmp, approved=approved, staging=staging)
    finally:
        _a4.open_trusted_regular_file = _original_open

    check(artifact.read_bytes() == b"SUBSTITUTED BYTES\n",
          "the fixture really replaced the source pathname mid-operation")
    check(outcome.supported, f"the operation completes from its descriptor ({outcome.reason})")
    check(outcome.artifact_sha256 == _DIGEST,
          "the digest is of the bytes that were opened, not the bytes now at the path")
    check(Path(outcome.staged_path).read_bytes() == _BYTES,
          "the staged bytes are the verified bytes, not the substituted ones")

# --- concurrent staging of identical content -------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    CALLERS = 12
    outcomes = []
    notice = threading.Lock()

    def stage_once():
        try:
            outcome = _stage(tmp, approved=approved, staging=staging)
        except BaseException as error:  # noqa: BLE001
            outcome = error
        with notice:
            outcomes.append(outcome)

    workers = [threading.Thread(target=stage_once) for _ in range(CALLERS)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join(60)
    alive = [w for w in workers if w.is_alive()]
    supported = [o for o in outcomes if getattr(o, "supported", False)]
    finals = sorted(staging.glob("sha256-*"))
    check(not alive, f"no concurrent staging caller deadlocked ({len(alive)} alive)")
    check(len(supported) == CALLERS,
          f"every concurrent caller staged successfully ({len(supported)}/{CALLERS})")
    check(len({o.staged_path for o in supported}) == 1,
          "every caller resolved to the same staged identity")
    check(len(finals) == 1, f"exactly one final staged object exists ({len(finals)})")
    check(Path(supported[0].staged_path).read_bytes() == _BYTES,
          "the single final object holds the verified bytes")
    check(stat.S_IMODE(Path(supported[0].staged_path).lstat().st_mode) == 0o400,
          "the final object kept its mode under contention")

# --- A4 writes only into staging -------------------------------------------
with TemporaryDirectory() as tmp:
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    capability_store = CapabilityStore(Path(tmp) / "capability",
                                       expected_uid=UID, expected_gid=GID)
    store_before = inventory(capability_store.root)
    fabric_root = _chain(tmp)
    fabric_before = _fabric_inventory(fabric_root)
    _stage(tmp, approved=approved, staging=staging)
    _stage(tmp, approved=approved, staging=staging,
           evidence=_evidence(artifact_reference="oci://x"))
    check(inventory(capability_store.root) == store_before,
          "staging writes no capability runtime record")
    check(capability_store.counts() == {"capability-invocation": 0,
                                        "capability-result": 0},
          "staging allocates no invocation or result identity")
    check(_fabric_inventory(fabric_root) == fabric_before,
          "staging leaves the fabric store byte-identical")

# ===========================================================================
# A5 — durable invocation decisions, replay, and conflict
# ===========================================================================
# One opaque invocation_id, one authoritative binding, for ever. Establishing
# that has to be a single serialized act: looking up outside the lock and
# writing inside it is a race with a different shape, not a smaller one.
#
# Nothing here executes. A5 records that a preparation was decided.

from tools.capability.package_resolution import StagedArtifact  # noqa: E402
from tools.capability.records import (  # noqa: E402
    INVOCATION_FIELDS, RESULT_FIELDS, RECORD_SCHEMA_VERSION)
from tools.capability.evidence import (  # noqa: E402
    OUTCOME_PREPARED, OUTCOME_REFUSED, STATUS_CONFLICT, STATUS_CONSUMED,
    STATUS_PREPARED, STATUS_REFUSED, REASON_CORRUPT_EVIDENCE,
    REASON_INVOCATION_INPUT, record_invocation)

_WHEN = _datetime(2026, 8, 11, 9, 0, 0, tzinfo=_timezone(_timedelta(hours=-5)))


def _prepared_inputs(tmp, *, invocation_id="inv-alpha", payload=None,
                     actor="operator:cschott", **binding_overrides):
    """One fully verified invocation, ready to be decided durably."""
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    evidence = _evidence()
    staged = _stage(tmp, approved=approved, staging=staging, evidence=evidence)
    body = {"text": "summarise"} if payload is None else payload
    binding = dict(invocation_id=invocation_id, selection_id=evidence.selection_id,
                   instance_id=evidence.instance_id,
                   capability_package_id=evidence.capability_package_id,
                   actor=actor)
    binding.update(binding_overrides)
    return dict(
        invocation_id=invocation_id,
        binding_digest=bind(payload=body, **binding),
        payload_digest=payload_digest(body),
        evidence=evidence, staged=staged, actor=binding["actor"],
        request_id="req-alpha", requested_at=_WHEN)


def _decide(store, inputs, **overrides):
    asked = dict(inputs)
    asked.update(overrides)
    return record_invocation(store, **asked)


def _opened_capability(tmp, name="capability"):
    return CapabilityStore(Path(tmp) / name, expected_uid=UID, expected_gid=GID)


# --- record schemas are closed and versioned -------------------------------
check(RECORD_SCHEMA_VERSION == 1, f"records carry schema version 1 ({RECORD_SCHEMA_VERSION})")
for field in ("invocation_record_id", "invocation_id", "request_id", "selection_id",
              "instance_id", "capability_package_id", "contract_id", "capability_id",
              "actor", "payload_digest", "binding_digest", "effect_class",
              "artifact_digest", "requested_at", "kind", "schema_version", "evidence"):
    check(field in INVOCATION_FIELDS, f"the invocation record carries {field}")
for field in ("capability_result_id", "invocation_record_id", "attempt_number",
              "outcome_class", "reason", "recorded_at", "kind", "schema_version",
              "evidence"):
    check(field in RESULT_FIELDS, f"the result record carries {field}")
for forbidden in ("payload", "command", "argv", "environment", "secret", "adapter",
                  "manifest_bytes", "artifact_bytes", "stdout", "stderr"):
    check(forbidden not in INVOCATION_FIELDS and forbidden not in RESULT_FIELDS,
          f"no record carries {forbidden}")

# --- first accepted invocation ---------------------------------------------
with TemporaryDirectory() as tmp:
    store = _opened_capability(tmp)
    inputs = _prepared_inputs(tmp)
    decision = _decide(store, inputs)

    check(decision.status == STATUS_PREPARED,
          f"a first verified invocation is prepared ({decision.status} {decision.reason})")
    check(decision.reason is None, "a prepared decision names no refusal")
    check(decision.invocation_record_id is not None, "a CINV identity is allocated")
    check(decision.result_record_id is None,
          "an accepted preparation allocates no result record")
    check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
          f"exactly one record is written ({store.counts()})")

    written = store.read_record("capability-invocation", decision.invocation_record_id)
    check(written["invocation_id"] == "inv-alpha", "the opaque identity is persisted")
    check(written["binding_digest"] == inputs["binding_digest"], "the binding digest is persisted")
    check(written["payload_digest"] == inputs["payload_digest"], "the payload digest is persisted")
    check(written["request_id"] == "req-alpha", "the fabric request identity is persisted")
    check(written["selection_id"] == "CSEL-000001", "the selection is persisted")
    check(written["instance_id"] == "CINST-000001", "the instance is persisted")
    check(written["capability_package_id"] == "CPKG-0001", "the package is persisted")
    check(written["contract_id"] == "CCON-0001", "the contract is persisted")
    check(written["capability_id"] == "CAPDEF-0001", "the capability is persisted")
    check(written["actor"] == "operator:cschott", "the actor is persisted")
    check(written["effect_class"] == "read-only", "the effect class is persisted")
    check(written["artifact_digest"] == inputs["staged"].artifact_sha256,
          "the verified artefact digest is persisted")
    check(written["evidence"]["outcome"] == OUTCOME_PREPARED,
          f"the record states its own outcome ({written['evidence']['outcome']})")
    check(set(written) == set(INVOCATION_FIELDS),
          f"the record carries exactly its schema ({sorted(set(written) ^ set(INVOCATION_FIELDS))})")
    check("summarise" not in str(written),
          "the payload body is nowhere in the record, only its digest")

# --- exact replay -----------------------------------------------------------
with TemporaryDirectory() as tmp:
    store = _opened_capability(tmp)
    inputs = _prepared_inputs(tmp)
    first = _decide(store, inputs)
    before = inventory(store.root)

    replayed = _decide(store, inputs)
    check(replayed.status == STATUS_CONSUMED,
          f"presenting the same identity and binding is consumed ({replayed.status})")
    check(replayed.reason == "invocation_identity_consumed",
          f"the consumed reason is the accepted one ({replayed.reason})")
    check(replayed.invocation_record_id == first.invocation_record_id,
          "replay returns the original authoritative record")
    check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
          f"replay allocates and writes nothing ({store.counts()})")
    check(inventory(store.root) == before,
          "replay leaves the evidence store byte-identical")

    # Replay returns the stored decision; it does not reconsult authority.
    import tools.capability.evidence as _a5  # noqa: E402
    import tools.capability.fabric_evidence as _a3mod  # noqa: E402
    import tools.capability.package_resolution as _a4mod  # noqa: E402

    def _explode_authority(*args, **kwargs):
        raise AssertionError("authority was reconsulted during exact replay")

    _saved = [(_a3mod, "verify_selected_evidence", _a3mod.verify_selected_evidence),
              (_a4mod, "resolve_and_stage_package", _a4mod.resolve_and_stage_package)]
    for owner, name, _ in _saved:
        setattr(owner, name, _explode_authority)
    try:
        armed = _decide(store, inputs)
        tripped = None
    except AssertionError as error:
        armed = None
        tripped = str(error)
    finally:
        for owner, name, original in _saved:
            setattr(owner, name, original)
    check(tripped is None, f"exact replay reconsults no authority surface ({tripped})")
    check(armed is not None and armed.status == STATUS_CONSUMED,
          "exact replay still answers from stored evidence with authority armed")

# --- conflicting reuse ------------------------------------------------------
for changed, description in (("payload", "a different payload"),
                             ("actor", "a different actor"),
                             ("selection_id", "a different selection"),
                             ("instance_id", "a different instance"),
                             ("capability_package_id", "a different package")):
    with TemporaryDirectory() as tmp:
        store = _opened_capability(tmp)
        inputs = _prepared_inputs(tmp)
        first = _decide(store, inputs)
        before = inventory(store.root)

        if changed == "payload":
            other = _prepared_inputs(tmp, payload={"text": "translate"})
        else:
            other = _prepared_inputs(tmp, **{changed: "OTHER-000009"})
        other["invocation_id"] = "inv-alpha"
        # Rebuild the binding under the same opaque identity.
        conflicting = _decide(store, dict(inputs, binding_digest=other["binding_digest"]))
        check(conflicting.status == STATUS_CONFLICT,
              f"{description} under one identity conflicts ({conflicting.status})")
        check(conflicting.reason == "invocation_identity_conflict",
              f"the conflict reason is the accepted one ({conflicting.reason})")
        check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
              f"a conflict allocates nothing ({store.counts()})")
        check(inventory(store.root) == before,
              "a conflict leaves the original record byte-identical")

# --- refusal persistence ----------------------------------------------------
with TemporaryDirectory() as tmp:
    # An input refusal cannot form the authoritative key, so it records nothing.
    store = _opened_capability(tmp)
    inputs = _prepared_inputs(tmp)
    for bad_id, description in (("", "an empty identity"), ("has space", "an unsafe identity"),
                                (None, "an absent identity")):
        outcome = _decide(store, inputs, invocation_id=bad_id)
        check(outcome.status == STATUS_REFUSED and outcome.reason == REASON_INVOCATION_INPUT,
              f"{description} refuses without persistence ({outcome.reason})")
    check(store.counts() == {"capability-invocation": 0, "capability-result": 0},
          f"an input refusal writes nothing ({store.counts()})")

for spoil, expected_kind, description in (
        (lambda i: dict(i, evidence=EvidenceVerdict(False, "instance-not-admitted")),
         "instance-not-admitted", "a refused fabric evidence"),
        (lambda i: dict(i, staged=StagedArtifact(False, "substitution-detected")),
         "substitution-detected", "a refused package verification")):
    with TemporaryDirectory() as tmp:
        store = _opened_capability(tmp)
        inputs = spoil(_prepared_inputs(tmp))
        outcome = _decide(store, inputs)
        check(outcome.status == STATUS_REFUSED,
              f"{description} refuses ({outcome.status})")
        check(outcome.reason == expected_kind,
              f"{description} carries the upstream reason ({outcome.reason})")
        check(outcome.invocation_record_id is not None,
              f"{description} still consumes its invocation identity")
        check(outcome.result_record_id is not None,
              f"{description} persists a refusal record")
        check(store.counts() == {"capability-invocation": 1, "capability-result": 1},
              f"{description} writes exactly two records ({store.counts()})")
        cinv = store.read_record("capability-invocation", outcome.invocation_record_id)
        cres = store.read_record("capability-result", outcome.result_record_id)
        check(cinv["evidence"]["outcome"] == OUTCOME_REFUSED,
              "the invocation record states that it was refused")
        check(cres["invocation_record_id"] == outcome.invocation_record_id,
              "the result record links to its invocation")
        check(cres["outcome_class"] == "refused",
              f"the result outcome class is refused ({cres['outcome_class']})")
        check(cres["reason"] == expected_kind, "the result names the refusal reason")
        check(cres["attempt_number"] == 1, "the first attempt is numbered one")
        check(set(cres) == set(RESULT_FIELDS), "the result carries exactly its schema")

        # A refused invocation consumes its identity: going forward is a new one.
        again = _decide(store, inputs)
        check(again.status in (STATUS_CONSUMED, STATUS_CONFLICT),
              f"a refused identity is not silently retryable ({again.status})")
        check(store.counts() == {"capability-invocation": 1, "capability-result": 1},
              "presenting a refused identity again writes nothing further")

# --- corruption -------------------------------------------------------------
def _corrupt(store, record_id, mutation):
    path = store.path_for("capability-invocation", record_id)
    body = _yaml_load(path.read_text(encoding="utf-8"))
    mutation(body)
    path.chmod(0o600)
    path.write_text(_yaml_dump(body), encoding="utf-8")
    path.chmod(0o400)


import yaml as _yaml  # noqa: E402
_yaml_load = _yaml.safe_load


def _yaml_dump(body):
    return _yaml.safe_dump(body, sort_keys=True, default_flow_style=False)


for mutation, description in (
        (lambda b: b.__setitem__("binding_digest", "not-a-digest"), "a malformed binding digest"),
        (lambda b: b.__setitem__("payload_digest", "sha256:short"), "a malformed payload digest"),
        (lambda b: b.__setitem__("invocation_id", ""), "a malformed opaque identity"),
        (lambda b: b.__setitem__("kind", "capability-result"), "a wrong record kind"),
        (lambda b: b.__setitem__("schema_version", 2), "an unknown schema version"),
        (lambda b: b.__setitem__("unexpected", "field"), "an unknown field"),
        (lambda b: b.pop("binding_digest"), "a missing binding digest")):
    with TemporaryDirectory() as tmp:
        store = _opened_capability(tmp)
        inputs = _prepared_inputs(tmp)
        first = _decide(store, inputs)
        _corrupt(store, first.invocation_record_id, mutation)
        outcome = _decide(store, inputs)
        check(outcome.status == STATUS_REFUSED and outcome.reason == REASON_CORRUPT_EVIDENCE,
              f"{description} in stored evidence refuses deterministically ({outcome.reason})")
        check(store.counts()["capability-invocation"] == 1,
              f"{description} is not repaired and nothing is added")

with TemporaryDirectory() as tmp:
    # Two authoritative records for one opaque identity is corruption, not a
    # question about which one to prefer.
    store = _opened_capability(tmp)
    inputs = _prepared_inputs(tmp)
    first = _decide(store, inputs)
    duplicate = store.allocate_id("capability-invocation")
    body = store.read_record("capability-invocation", first.invocation_record_id)
    body["invocation_record_id"] = duplicate
    store.write_atomic(store.path_for("capability-invocation", duplicate), body)
    outcome = _decide(store, inputs)
    check(outcome.status == STATUS_REFUSED and outcome.reason == REASON_CORRUPT_EVIDENCE,
          f"two authoritative records for one identity refuse ({outcome.reason})")

# --- interruption between the two records ----------------------------------
with TemporaryDirectory() as tmp:
    store = _opened_capability(tmp)
    inputs = dict(_prepared_inputs(tmp),
                  evidence=EvidenceVerdict(False, "instance-not-admitted"))
    original_write = CapabilityStore.write_atomic
    calls = {"count": 0}

    def _fail_second_write(self, destination, payload):
        calls["count"] += 1
        if calls["count"] == 2:
            raise OSError("interrupted before the result record")
        return original_write(self, destination, payload)

    CapabilityStore.write_atomic = _fail_second_write
    try:
        interrupted = None
        try:
            _decide(store, inputs)
        except OSError:
            interrupted = True
    finally:
        CapabilityStore.write_atomic = original_write

    check(interrupted, "the fixture really interrupted the second write")
    check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
          f"the invocation record survives an interrupted refusal ({store.counts()})")
    surviving = store.list_records("capability-invocation")[0]
    check(surviving["evidence"]["outcome"] == OUTCOME_REFUSED,
          "the surviving record already states it was refused, so it cannot read as prepared")
    check(surviving["invocation_id"] == "inv-alpha",
          "the interrupted invocation is attributable to its identity")

    # The identity is consumed by the interrupted attempt; nothing is repaired.
    after = _decide(store, inputs)
    check(after.status in (STATUS_CONSUMED, STATUS_CONFLICT),
          f"an interrupted invocation is not silently retryable ({after.status})")
    check(store.counts()["capability-result"] == 0,
          "the missing result record is not manufactured on a later presentation")

with TemporaryDirectory() as tmp:
    # An identity allocated and never written is spent, never recycled.
    store = _opened_capability(tmp)
    spent = store.allocate_id("capability-invocation")
    inputs = _prepared_inputs(tmp)
    decision = _decide(store, inputs)
    check(decision.invocation_record_id != spent,
          f"an allocated-but-unwritten identity is not reused ({decision.invocation_record_id})")

# --- the critical section is entered exactly once --------------------------
_evidence_module_source = (root / "tools" / "capability" / "evidence.py").read_text(encoding="utf-8")
check(_evidence_module_source.count("invocation_critical_section") == 1,
      f"the decision enters its critical section exactly once "
      f"({_evidence_module_source.count('invocation_critical_section')})")
check("request_critical_section" not in _evidence_module_source,
      "the fabric request lock is never acquired")

with TemporaryDirectory() as tmp:
    # Lock contention, proven by event rather than by elapsed time.
    store = _opened_capability(tmp)
    inputs = _prepared_inputs(tmp)

    class _WatchingStore(CapabilityStore):
        def __init__(self, *args, **kwargs):
            self.reached = threading.Event()
            self.release = threading.Event()
            self.hold = False
            super().__init__(*args, **kwargs)

        def invocation_critical_section(self, invocation_id):
            outer = super().invocation_critical_section(invocation_id)

            class _Section:
                def __enter__(inner):
                    outer.__enter__()
                    if self.hold:
                        self.reached.set()
                        self.release.wait(20)
                    return None

                def __exit__(inner, *exc):
                    return outer.__exit__(*exc)

            return _Section()

    holder = _WatchingStore(store.root, expected_uid=UID, expected_gid=GID)
    holder.hold = True
    outcomes = {}

    def hold_section():
        outcomes["holder"] = _decide(holder, inputs)

    first = threading.Thread(target=hold_section, daemon=True)
    first.start()
    check(holder.reached.wait(20), "the first caller holds the capability critical section")

    second_store = _opened_capability(tmp)
    entered = threading.Event()

    def contend():
        outcomes["second"] = _decide(second_store, inputs)
        entered.set()

    second = threading.Thread(target=contend, daemon=True)
    second.start()
    check(not entered.wait(1.5),
          "the second caller cannot decide while the first holds the section")
    holder.release.set()
    first.join(20)
    second.join(20)
    check(entered.is_set(), "the second caller proceeds once the section is released")
    statuses = sorted(o.status for o in outcomes.values())
    check(statuses == sorted([STATUS_PREPARED, STATUS_CONSUMED]),
          f"one caller prepared and the other observed its durable state ({statuses})")
    check(store.counts()["capability-invocation"] == 1,
          "contention produced exactly one authoritative record")

# --- concurrent exact and conflicting reuse --------------------------------
for variant, description in (("exact", "exact reuse"), ("conflicting", "conflicting reuse")):
    rounds = 8
    callers = 8
    anomalies = []
    for index in range(rounds):
        with TemporaryDirectory() as tmp:
            store = _opened_capability(tmp)
            base = _prepared_inputs(tmp, invocation_id=f"inv-race-{index}")
            other = _prepared_inputs(tmp, invocation_id=f"inv-race-{index}",
                                     payload={"text": "translate"})
            results = []
            notice = threading.Lock()

            def race(slot):
                handle = _opened_capability(tmp)
                asked = base if (variant == "exact" or slot % 2 == 0) else \
                    dict(base, binding_digest=other["binding_digest"])
                try:
                    outcome = _decide(handle, asked)
                except BaseException as error:  # noqa: BLE001
                    outcome = error
                with notice:
                    results.append(outcome)

            threads = [threading.Thread(target=race, args=(slot,)) for slot in range(callers)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(30)
            if any(t.is_alive() for t in threads):
                anomalies.append(f"round {index}: a caller did not finish")
                break
            statuses = [getattr(r, "status", repr(r)) for r in results]
            prepared = [s for s in statuses if s == STATUS_PREPARED]
            records = store.counts()["capability-invocation"]
            if len(prepared) != 1 or records != 1:
                anomalies.append(f"round {index}: prepared={len(prepared)} records={records}")
            if variant == "exact" and any(s == STATUS_CONFLICT for s in statuses):
                anomalies.append(f"round {index}: exact reuse produced a conflict")
            if variant == "conflicting" and not any(s == STATUS_CONFLICT for s in statuses):
                anomalies.append(f"round {index}: conflicting reuse produced no conflict")
    check(not anomalies,
          f"concurrent {description}: one authoritative binding every round ({anomalies[:2]})")

# --- neither the fabric nor the staged artefact is touched -----------------
with TemporaryDirectory() as tmp:
    store = _opened_capability(tmp)
    inputs = _prepared_inputs(tmp)
    fabric_root = _chain(tmp)
    fabric_before = _fabric_inventory(fabric_root)
    staged = Path(inputs["staged"].staged_path)
    staged_before = (staged.lstat().st_ino, staged.lstat().st_mode,
                     staged.lstat().st_uid, staged.read_bytes())
    residue = staged.parent.parent / ".staging-residue.tmp"
    residue.write_bytes(b"partial")
    residue_before = (residue.lstat().st_ino, residue.read_bytes())

    _decide(store, inputs)
    _decide(store, inputs)
    _decide(store, dict(inputs, binding_digest=bind(payload={"x": 1},
                                                    invocation_id="inv-alpha",
                                                    selection_id="CSEL-000001",
                                                    instance_id="CINST-000001",
                                                    capability_package_id="CPKG-0001",
                                                    actor="operator:cschott")))
    check(_fabric_inventory(fabric_root) == fabric_before,
          "recording a decision leaves the fabric store byte-identical")
    check((staged.lstat().st_ino, staged.lstat().st_mode, staged.lstat().st_uid,
           staged.read_bytes()) == staged_before,
          "the staged artefact is untouched by evidence persistence")
    check((residue.lstat().st_ino, residue.read_bytes()) == residue_before,
          "A4 staging residue is not cleaned by A5")

# --- no mutable index namespace --------------------------------------------
with TemporaryDirectory() as tmp:
    store = _opened_capability(tmp)
    _decide(store, _prepared_inputs(tmp))
    present = sorted(p.name for p in store.root.iterdir())
    check(present == ["capability-invocations", "capability-results", "sequences"],
          f"the store grew no new namespace ({present})")
    for forbidden in ("requests", "replay", "index", "ledger", "mapping", "cache"):
        check(not (store.root / forbidden).exists(),
              f"no {forbidden} namespace exists")

# ===========================================================================
# A6 — inspection, validation, and the interface that refuses
# ===========================================================================
# An operator surface over everything A1-A5 built, and a place where the
# absence of an adapter becomes visible: preparation succeeds, and then the
# interface says the one thing it can honestly say.
#
# Exit codes are coarse on purpose -- 0 success, 1 governed negative, 2 the
# request itself was unusable -- and the JSON carries the precise state.

import subprocess as _sub  # noqa: E402  (test harness only, never production)

from tools.capability.cli import (  # noqa: E402
    EXIT_DENIED, EXIT_SUCCESS, EXIT_USAGE, PAYLOAD_MAXIMUM_BYTES, main)
from tools.capability.coordinator import (  # noqa: E402
    REASON_NO_ADAPTER, prepare_invocation)
from tools.capability.inspection import (  # noqa: E402
    FINDING_DUPLICATE_IDENTITY, FINDING_INTERRUPTED_REFUSAL,
    FINDING_ORPHAN_RESULT, FINDING_OUTCOME_MISMATCH, inspect_records,
    validate_store)


def _run(argv):
    """The interface, invoked in-process, with its output captured."""
    import io
    import contextlib
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(argv)
    return code, out.getvalue(), err.getvalue()


def _payload_root(tmp, name="payload.json", text='{"text":"summarise"}'):
    root = Path(tmp) / "payloads"
    root.mkdir(mode=0o755, exist_ok=True)
    target = root / name
    target.write_text(text, encoding="utf-8")
    target.chmod(0o644)
    return root, target


def _invoke_args(tmp, *, approved, staging, fabric_root, payload_root,
                 capability_root, invocation_id="inv-cli", payload="payload.json",
                 **overrides):
    args = {
        "--store-root": str(capability_root),
        "--expected-uid": str(UID), "--expected-gid": str(GID),
        "--fabric-root": str(fabric_root),
        "--fabric-expected-uid": str(UID), "--fabric-expected-gid": str(GID),
        "--approved-artifact-root": str(approved),
        "--trusted-source-uid": str(UID),
        "--staging-root": str(staging), "--coordinator-uid": str(UID),
        "--approved-payload-root": str(payload_root),
        "--payload-source-uid": str(UID), "--payload-file": payload,
        "--invocation-id": invocation_id,
        "--selection-id": "CSEL-000001",
        "--instance-id": "CINST-000001",
        "--package-id": "CPKG-0001",
        "--actor": "operator:cschott",
        "--request-id": "req-alpha",
        "--requested-at": _WHEN.isoformat(),
    }
    args.update(overrides)
    argv = ["invoke"]
    for flag, value in args.items():
        if value is not None:
            argv.extend([flag, value])
    return argv


def _world(tmp):
    """A fabric chain, a verified package, a staging root, and a payload."""
    fabric_root = _chain(tmp, **{"capability-package": {
        "artifact_reference": "file:nested/artifact.bin",
        "manifest_reference": "file:nested/artifact.manifest.json"}})
    approved, artifact = _source(tmp)
    staging = _staging(tmp)
    payload_root, _ = _payload_root(tmp)
    capability_root = Path(tmp) / "capability"
    _opened_capability(tmp)
    return dict(fabric_root=fabric_root, approved=approved, staging=staging,
                payload_root=payload_root, capability_root=capability_root)


# --- the command inventory, and nothing beyond it --------------------------
code, out, err = _run(["--help"])
check(code in (EXIT_SUCCESS, EXIT_USAGE), "the interface offers help")
for command in ("invoke", "inspect", "validate"):
    check(command in out, f"the interface offers {command}")
for forbidden in ("retry", "cancel", "list-adapters", "run", "execute", "start"):
    check(f" {forbidden} " not in out.replace(",", " "),
          f"the interface offers no {forbidden} command")

check((EXIT_SUCCESS, EXIT_DENIED, EXIT_USAGE) == (0, 1, 2),
      f"the exit codes are 0/1/2 ({EXIT_SUCCESS}/{EXIT_DENIED}/{EXIT_USAGE})")
check(PAYLOAD_MAXIMUM_BYTES == 1048576,
      f"the payload bound is 1 MiB ({PAYLOAD_MAXIMUM_BYTES})")

# --- exit 0: sound inspect and validate ------------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    store = _opened_capability(tmp)
    code, out, err = _run(["inspect", "--store-root", str(world["capability_root"]),
                           "--expected-uid", str(UID), "--expected-gid", str(GID)])
    check(code == EXIT_SUCCESS, f"a sound inspect exits 0 ({code} {err[:60]})")
    report = _json.loads(out)
    check(report["status"] == "reported", "inspect reports its status")
    check(report["records"] == [], "an empty store reports no records")

    code, out, err = _run(["validate", "--store-root", str(world["capability_root"]),
                           "--expected-uid", str(UID), "--expected-gid", str(GID)])
    check(code == EXIT_SUCCESS, f"a sound validate exits 0 ({code})")
    check(_json.loads(out)["findings"] == [], "a sound store reports no findings")

# --- exit 1: the interface reaches the boundary and refuses ----------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    code, out, err = _run(_invoke_args(tmp, **world))
    check(code == EXIT_DENIED, f"a prepared invocation with no adapter exits 1 ({code} {err[:80]})")
    result = _json.loads(out)
    check(result["reason"] == REASON_NO_ADAPTER,
          f"the interface names the missing adapter ({result['reason']})")
    check(result["reason"] == "no_authorised_adapter",
          "the reason literal is the accepted one")
    check(result["status"] == "prepared",
          f"the durable decision is a preparation ({result['status']})")
    check(result["invocation_record_id"] is not None, "a CINV identity is reported")

    store = _opened_capability(tmp)
    check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
          f"the durable shape is one CINV and no CRES ({store.counts()})")
    cinv = store.read_record("capability-invocation", result["invocation_record_id"])
    check(cinv["evidence"]["outcome"] == OUTCOME_PREPARED,
          f"the record stays execution-prepared ({cinv['evidence']['outcome']})")
    check(cinv["invocation_id"] == "inv-cli", "the opaque identity is durable")

    # Consumed even though the preparation succeeded.
    code, out, err = _run(_invoke_args(tmp, **world))
    check(code == EXIT_DENIED, "presenting the identity again exits 1")
    check(_json.loads(out)["status"] == "consumed",
          f"the identity is consumed ({_json.loads(out)['status']})")
    check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
          "a consumed replay writes nothing further")

    # A different binding under the same identity conflicts.
    other_root, _ = _payload_root(tmp, name="other.json", text='{"text":"translate"}')
    code, out, err = _run(_invoke_args(tmp, **world, payload="other.json"))
    check(code == EXIT_DENIED and _json.loads(out)["status"] == "conflict",
          f"a different payload under one identity conflicts ({_json.loads(out)['status']})")

    # A new identity prepares again.
    code, out, err = _run(_invoke_args(tmp, **world, invocation_id="inv-cli-2"))
    check(code == EXIT_DENIED and _json.loads(out)["status"] == "prepared",
          "a new identity prepares again")
    check(store.counts()["capability-invocation"] == 2, "the new identity has its own record")

# --- exit 1: governed refusals ---------------------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    # A3 refusal: the claimed selection is not there.
    code, out, err = _run(_invoke_args(tmp, **world, **{"--selection-id": "CSEL-000009"}))
    check(code == EXIT_DENIED, "an unverifiable selection exits 1")
    check(_json.loads(out)["reason"] == "selection-not-found",
          f"the A3 reason is carried through ({_json.loads(out)['reason']})")

with TemporaryDirectory() as tmp:
    world = _world(tmp)
    # A4 refusal: the artefact no longer matches its manifest.
    artifact = world["approved"] / "nested" / "artifact.bin"
    artifact.chmod(0o644)
    artifact.write_bytes(b"substituted\n")
    artifact.chmod(0o644)
    code, out, err = _run(_invoke_args(tmp, **world))
    check(code == EXIT_DENIED, "a substituted artefact exits 1")
    check(_json.loads(out)["reason"] == "substitution-detected",
          f"the A4 reason is carried through ({_json.loads(out)['reason']})")

with TemporaryDirectory() as tmp:
    world = _world(tmp)
    code, out, err = _run(["inspect", "--store-root", str(world["capability_root"]),
                           "--expected-uid", str(UID), "--expected-gid", str(GID),
                           "--kind", "capability-invocation",
                           "--identifier", "CINV-999999"])
    check(code == EXIT_DENIED, f"a valid query for a missing record exits 1 ({code})")
    check(_json.loads(out)["status"] == "not-found", "the missing record is reported")

# --- exit 2: the request itself is unusable --------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    store = _opened_capability(tmp)
    for argv, description in (
            (["nonsense"], "an unknown command"),
            ([], "no command at all"),
            (["invoke"], "invoke with no arguments"),
            (["inspect", "--store-root", str(world["capability_root"])],
             "a missing required argument"),
            (["inspect", "--store-root", str(world["capability_root"]),
              "--expected-uid", "not-a-number", "--expected-gid", str(GID)],
             "a malformed uid")):
        code, out, err = _run(argv)
        check(code == EXIT_USAGE, f"{description} exits 2 ({code})")
        check("Traceback" not in out + err, f"{description} shows no traceback")

    for override, description in (
            ({"--payload-file": "../escape.json"}, "a traversing payload name"),
            ({"--payload-file": "missing.json"}, "an absent payload file"),
            ({"--payload-source-uid": str(UID + 1)}, "a payload owned by another uid"),
            ({"--approved-payload-root": str(Path(tmp) / "absent")}, "an unusable payload root"),
            ({"--store-root": str(world["payload_root"] / "payload.json" / "deep")},
             "a runtime root beneath a regular file")):
        code, out, err = _run(_invoke_args(tmp, **world, **override))
        check(code == EXIT_USAGE, f"{description} exits 2 ({code})")
    check(store.counts() == {"capability-invocation": 0, "capability-result": 0},
          f"no interface failure persists evidence ({store.counts()})")

with TemporaryDirectory() as tmp:
    world = _world(tmp)
    store = _opened_capability(tmp)
    outside = Path(tmp) / "outside"
    outside.mkdir(mode=0o755)
    (outside / "planted.json").write_text('{"text":"planted"}', encoding="utf-8")
    (world["payload_root"] / "linked.json").symlink_to(outside / "planted.json")
    code, out, err = _run(_invoke_args(tmp, **world, payload="linked.json"))
    check(code == EXIT_USAGE, f"a symlinked payload exits 2 ({code})")
    check(store.counts()["capability-invocation"] == 0,
          "a symlinked payload consumes no invocation identity")

# --- payload parsing: duplicate keys, at any depth -------------------------
for text, description in (('{"a":1,"a":2}', "a duplicate key at the top level"),
                          ('{"outer":{"a":1,"a":2}}', "a duplicate key nested once"),
                          ('{"o":{"p":{"a":1,"a":2}}}', "a duplicate key nested twice"),
                          ('{"list":[{"a":1,"a":2}]}', "a duplicate key inside an array"),
                          ('{"a":1} {"b":2}', "a trailing second document"),
                          ('{"a":', "malformed JSON"),
                          ('', "an empty payload")):
    with TemporaryDirectory() as tmp:
        world = _world(tmp)
        store = _opened_capability(tmp)
        (world["payload_root"] / "payload.json").chmod(0o644)
        (world["payload_root"] / "payload.json").write_text(text, encoding="utf-8")
        code, out, err = _run(_invoke_args(tmp, **world))
        check(code == EXIT_USAGE, f"{description} exits 2 ({code})")
        check(store.counts() == {"capability-invocation": 0, "capability-result": 0},
              f"{description} persists nothing and consumes no identity")

# --- payload formatting equivalence and distinction ------------------------
_digests = {}
for label, text in (("compact", '{"a":1,"b":[1,2],"c":{"d":"x"}}'),
                    ("spaced", '{ "a" : 1 , "b" : [ 1 , 2 ] , "c" : { "d" : "x" } }'),
                    ("indented", '{\n  "b": [1, 2],\n  "a": 1,\n  "c": {"d": "x"}\n}'),
                    ("reordered", '{"c":{"d":"x"},"b":[1,2],"a":1}')):
    with TemporaryDirectory() as tmp:
        world = _world(tmp)
        (world["payload_root"] / "payload.json").chmod(0o644)
        (world["payload_root"] / "payload.json").write_text(text, encoding="utf-8")
        code, out, err = _run(_invoke_args(tmp, **world))
        _digests[label] = _json.loads(out)["payload_digest"]
check(len(set(_digests.values())) == 1,
      f"equivalent textual payloads bind identically ({_digests})")

_distinct = {}
for label, text in (("integer", '{"a":1}'), ("string", '{"a":"1"}'),
                    ("boolean", '{"a":true}'), ("order", '{"a":[1,2]}'),
                    ("order2", '{"a":[2,1]}'), ("nested", '{"a":{"b":1}}')):
    with TemporaryDirectory() as tmp:
        world = _world(tmp)
        (world["payload_root"] / "payload.json").chmod(0o644)
        (world["payload_root"] / "payload.json").write_text(text, encoding="utf-8")
        code, out, err = _run(_invoke_args(tmp, **world))
        _distinct[label] = _json.loads(out)["payload_digest"]
check(len(set(_distinct.values())) == len(_distinct),
      f"distinct logical payloads bind differently ({len(set(_distinct.values()))}/{len(_distinct)})")

# --- payload bound ----------------------------------------------------------
for size, expected, description in ((PAYLOAD_MAXIMUM_BYTES, EXIT_DENIED, "a payload at the bound"),
                                    (PAYLOAD_MAXIMUM_BYTES + 1, EXIT_USAGE, "a payload one byte over")):
    with TemporaryDirectory() as tmp:
        world = _world(tmp)
        filler = '{"a":"' + "p" * (size - len('{"a":""}') - 1) + '"}'
        filler = filler + " " * max(0, size - len(filler))
        (world["payload_root"] / "payload.json").chmod(0o644)
        (world["payload_root"] / "payload.json").write_text(filler[:size], encoding="utf-8")
        code, out, err = _run(_invoke_args(tmp, **world))
        check(code == expected, f"{description} exits {expected} ({code})")

# --- the payload descriptor race -------------------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    original = '{"text":"ORIGINAL"}'
    (world["payload_root"] / "payload.json").chmod(0o644)
    (world["payload_root"] / "payload.json").write_text(original, encoding="utf-8")
    substitute = world["payload_root"] / "substitute.json"
    substitute.write_text('{"text":"SUBSTITUTED"}', encoding="utf-8")
    substitute.chmod(0o644)

    import tools.capability.cli as _a6cli  # noqa: E402
    _original_open = _a6cli.open_trusted_regular_file

    def _swapping(*args, **kwargs):
        handle = _original_open(*args, **kwargs)
        os.replace(substitute, world["payload_root"] / "payload.json")
        return handle

    _a6cli.open_trusted_regular_file = _swapping
    try:
        code, out, err = _run(_invoke_args(tmp, **world))
    finally:
        _a6cli.open_trusted_regular_file = _original_open

    check((world["payload_root"] / "payload.json").read_text(encoding="utf-8")
          == '{"text":"SUBSTITUTED"}',
          "the fixture really replaced the payload pathname")
    expected_digest = payload_digest({"text": "ORIGINAL"})
    check(_json.loads(out)["payload_digest"] == expected_digest,
          "the parsed payload is the one that was opened, not the one now at the path")

# --- inspection matrix ------------------------------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    _run(_invoke_args(tmp, **world))
    store = _opened_capability(tmp)
    identity = store.list_records("capability-invocation")[0]["invocation_record_id"]

    code, out, err = _run(["inspect", "--store-root", str(world["capability_root"]),
                           "--expected-uid", str(UID), "--expected-gid", str(GID),
                           "--kind", "capability-invocation", "--identifier", identity])
    check(code == EXIT_SUCCESS, "inspecting one record exits 0")
    reported = _json.loads(out)["records"]
    check(len(reported) == 1 and reported[0]["invocation_record_id"] == identity,
          "the named record is reported")
    check(_run(["inspect", "--store-root", str(world["capability_root"]),
                "--expected-uid", str(UID), "--expected-gid", str(GID)])[1]
          == _run(["inspect", "--store-root", str(world["capability_root"]),
                   "--expected-uid", str(UID), "--expected-gid", str(GID)])[1],
          "inspection output is deterministic")

    code, out, err = _run(["inspect", "--store-root", str(world["capability_root"]),
                           "--expected-uid", str(UID), "--expected-gid", str(GID),
                           "--kind", "capability-nonsense"])
    check(code == EXIT_USAGE, f"an unknown record kind exits 2 ({code})")

    # Inspection reruns no authority and mutates nothing.
    before = inventory(store.root)
    fabric_before = _fabric_inventory(world["fabric_root"])
    _saved = [(_a3mod, "verify_selected_evidence", _a3mod.verify_selected_evidence),
              (_a4mod, "resolve_and_stage_package", _a4mod.resolve_and_stage_package)]
    for owner, name, _ in _saved:
        setattr(owner, name, _explode_authority)
    try:
        _run(["inspect", "--store-root", str(world["capability_root"]),
              "--expected-uid", str(UID), "--expected-gid", str(GID)])
        _run(["validate", "--store-root", str(world["capability_root"]),
              "--expected-uid", str(UID), "--expected-gid", str(GID)])
        tripped = None
    except AssertionError as error:
        tripped = str(error)
    finally:
        for owner, name, original in _saved:
            setattr(owner, name, original)
    check(tripped is None, f"inspection and validation rerun no authority ({tripped})")
    check(inventory(store.root) == before,
          "inspection and validation leave the runtime store byte-identical")
    check(_fabric_inventory(world["fabric_root"]) == fabric_before,
          "inspection and validation leave the fabric store byte-identical")

# --- validation matrix ------------------------------------------------------
def _seed(tmp, records):
    store = _opened_capability(tmp)
    for kind, body in records:
        identity = body["invocation_record_id"] if kind == "capability-invocation" \
            else body["capability_result_id"]
        store.write_atomic(store.path_for(kind, identity), body)
    return store


def _cinv(identity, *, invocation_id="inv-a", outcome=OUTCOME_PREPARED):
    return {
        "invocation_record_id": identity, "invocation_id": invocation_id,
        "request_id": "req-1", "selection_id": "CSEL-000001",
        "instance_id": "CINST-000001", "capability_package_id": "CPKG-0001",
        "contract_id": "CCON-0001", "capability_id": "CAPDEF-0001",
        "actor": "operator:cschott", "payload_digest": payload_digest({"a": 1}),
        "binding_digest": payload_digest({"b": 2}), "effect_class": "read-only",
        "artifact_digest": payload_digest({"c": 3}), "staged_path": "/staging/x",
        "requested_at": _WHEN, "kind": "capability-invocation",
        "schema_version": 1,
        "evidence": {"actor": "operator:cschott", "outcome": outcome,
                     "request_id": "req-1", "selection_id": "CSEL-000001"},
    }


def _cres(identity, invocation_record_id):
    return {
        "capability_result_id": identity,
        "invocation_record_id": invocation_record_id, "attempt_number": 1,
        "outcome_class": "refused", "reason": "instance-not-admitted",
        "recorded_at": _WHEN, "kind": "capability-result", "schema_version": 1,
        "evidence": {"actor": "operator:cschott", "outcome": OUTCOME_REFUSED},
    }


for records, expect_sound, expected_finding, description in (
        ([("capability-invocation", _cinv("CINV-000001"))], True, None,
         "a prepared invocation with no result"),
        ([("capability-invocation", _cinv("CINV-000001", outcome=OUTCOME_REFUSED)),
          ("capability-result", _cres("CRES-000001", "CINV-000001"))], True, None,
         "a refused invocation with its result"),
        ([("capability-invocation", _cinv("CINV-000001", outcome=OUTCOME_REFUSED))],
         False, FINDING_INTERRUPTED_REFUSAL, "a refused invocation with no result"),
        ([("capability-result", _cres("CRES-000001", "CINV-000009"))],
         False, FINDING_ORPHAN_RESULT, "a result naming no invocation"),
        ([("capability-invocation", _cinv("CINV-000001")),
          ("capability-result", _cres("CRES-000001", "CINV-000001"))],
         False, FINDING_OUTCOME_MISMATCH, "a refusal result linked to a prepared invocation"),
        ([("capability-invocation", _cinv("CINV-000001", invocation_id="inv-a")),
          ("capability-invocation", _cinv("CINV-000002", invocation_id="inv-a"))],
         False, FINDING_DUPLICATE_IDENTITY, "two records for one opaque identity")):
    with TemporaryDirectory() as tmp:
        store = _seed(tmp, records)
        before = inventory(store.root)
        code, out, err = _run(["validate", "--store-root", str(store.root),
                               "--expected-uid", str(UID), "--expected-gid", str(GID)])
        findings = _json.loads(out)["findings"]
        if expect_sound:
            check(code == EXIT_SUCCESS and not findings,
                  f"{description} is sound ({code} {findings})")
        else:
            check(code == EXIT_DENIED, f"{description} exits 1 ({code})")
            check(any(expected_finding in finding for finding in findings),
                  f"{description} reports {expected_finding} ({findings})")
        check(inventory(store.root) == before,
              f"validating {description} repairs nothing")
        check(tuple(_json.loads(_run(["validate", "--store-root", str(store.root),
                                      "--expected-uid", str(UID),
                                      "--expected-gid", str(GID)])[1])["findings"])
              == tuple(findings),
              f"validating {description} is deterministic")

with TemporaryDirectory() as tmp:
    # Residue is reported and never removed.
    store = _seed(tmp, [("capability-invocation", _cinv("CINV-000001"))])
    residue = store.root / "capability-invocations" / ".CINV-000002.tmp"
    residue.write_text("partial", encoding="utf-8")
    before = (residue.lstat().st_ino, residue.read_bytes())
    code, out, err = _run(["validate", "--store-root", str(store.root),
                           "--expected-uid", str(UID), "--expected-gid", str(GID)])
    check(code == EXIT_DENIED and any("tmp" in f for f in _json.loads(out)["findings"]),
          f"residue is reported ({_json.loads(out)['findings']})")
    check((residue.lstat().st_ino, residue.read_bytes()) == before,
          "residue is not removed by validation")

# --- the interface never crosses the boundary ------------------------------
with TemporaryDirectory() as tmp:
    # A staged artefact that would leave a marker if anything ran it.
    marker = Path(tmp) / "marker"
    hostile = (f"import pathlib\npathlib.Path({str(marker)!r}).write_text('ran')\n").encode()
    digest = "sha256:" + _hashlib2.sha256(hostile).hexdigest()
    fabric_root = _chain(tmp, **{"capability-package": {
        "artifact_reference": "file:nested/artifact.bin",
        "manifest_reference": "file:nested/artifact.manifest.json"}})
    approved, artifact = _source(tmp, content=hostile,
                                 manifest=_manifest(artifact_sha256=digest))
    staging = _staging(tmp)
    payload_root, _ = _payload_root(tmp)
    capability_root = Path(tmp) / "capability"
    _opened_capability(tmp)
    world = dict(fabric_root=fabric_root, approved=approved, staging=staging,
                 payload_root=payload_root, capability_root=capability_root)

    code, out, err = _run(_invoke_args(tmp, **world))
    check(code == EXIT_DENIED and _json.loads(out)["reason"] == REASON_NO_ADAPTER,
          f"a hostile artefact still ends at the adapter boundary ({_json.loads(out)['reason']})")
    check(not marker.exists(),
          "nothing imported, executed, or spawned the staged artefact")

# --- there is no adapter to find -------------------------------------------
for module in ("cli", "coordinator", "inspection"):
    source_text = (root / "tools" / "capability" / f"{module}.py").read_text(encoding="utf-8")
    for token, description in (("subprocess", "a subprocess"), ("os.system", "a shell"),
                               ("importlib", "dynamic loading"), ("runpy", "a module runner"),
                               ("docker", "docker"), ("podman", "podman"),
                               ("socket", "a socket"), ("eval(", "eval"),
                               ("exec(", "exec"), ("adapter_registry", "an adapter registry"),
                               ("register_adapter", "adapter registration"),
                               ("load_adapter", "adapter loading"),
                               ("request_critical_section", "the fabric lock"),
                               ("TrustStore", "trust")):
        check(token not in source_text,
              f"{module}.py contains no {description}")
check("no_authorised_adapter" in (root / "tools" / "capability" / "coordinator.py").read_text(encoding="utf-8"),
      "the refusal literal exists as a named architectural state")

# --- interface and direct orchestration agree ------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    code, out, err = _run(_invoke_args(tmp, **world, invocation_id="inv-equal"))
    through_cli = _json.loads(out)

    direct_root = Path(tmp) / "capability-direct"
    direct = CapabilityStore(direct_root, expected_uid=UID, expected_gid=GID)
    prepared = prepare_invocation(
        direct, fabric_root=world["fabric_root"], fabric_expected_uid=UID,
        fabric_expected_gid=GID, approved_artifact_root=world["approved"],
        trusted_source_uid=UID, staging_root=world["staging"], coordinator_uid=UID,
        selection_id="CSEL-000001", instance_id="CINST-000001",
        capability_package_id="CPKG-0001", invocation_id="inv-equal",
        payload={"text": "summarise"}, actor="operator:cschott",
        request_id="req-alpha", requested_at=_WHEN)
    for field in ("status", "reason", "payload_digest", "binding_digest",
                  "artifact_digest", "staged_path"):
        check(through_cli[field] == getattr(prepared, field),
              f"the interface does not alter {field}")

# ===========================================================================
# A7 — Track A closure: the composed runtime, and where it stops
# ===========================================================================
# Each increment proved its own boundary. This proves the composition: one
# operator request travelling the whole path, every identity and digest linking
# to the next, and then nothing. The absence of a next step is the property.

import ast as _ast  # noqa: E402

# --- the composed authority chain, end to end ------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    code, out, err = _run(_invoke_args(tmp, **world, invocation_id="inv-chain"))
    result = _json.loads(out)
    check(code == EXIT_DENIED and result["reason"] == REASON_NO_ADAPTER,
          f"the composed path ends at the adapter boundary ({result['reason']})")

    store = _opened_capability(tmp)
    cinv = store.read_record("capability-invocation", result["invocation_record_id"])
    fabric = _FabricStore.open_for_read(world["fabric_root"], expected_uid=UID,
                                        expected_gid=GID)
    csel = fabric.read_record("capability-selection", "CSEL-000001")
    cinst = fabric.read_record("capability-instance", csel["selected_instance_id"])
    cpkg = fabric.read_record("capability-package", cinst["capability_package_id"])
    ccon = fabric.read_record("capability-contract", cinst["contract_id"])
    capdef = fabric.read_record("capability-definition", cinst["capability_id"])
    manifest = _json.loads(
        (world["approved"] / "nested" / "artifact.manifest.json").read_text(encoding="utf-8"))
    staged = Path(cinv["staged_path"])

    # Every link, checked against the record that establishes it.
    check(cinv["invocation_id"] == "inv-chain", "the opaque identity is the caller's")
    check(cinv["binding_digest"] == bind(
        payload={"text": "summarise"}, invocation_id="inv-chain",
        selection_id="CSEL-000001", instance_id="CINST-000001",
        capability_package_id="CPKG-0001", actor="operator:cschott"),
        "the binding digest covers the payload and the claim")
    check(cinv["payload_digest"] == payload_digest({"text": "summarise"}),
          "the payload digest is of the canonical logical payload")
    check(cinv["selection_id"] == csel["selection_id"], "the record names the verified CSEL")
    check(cinv["instance_id"] == csel["selected_instance_id"],
          "the instance is the one the selection chose")
    check(cinv["capability_package_id"] == cinst["capability_package_id"],
          "the package is the one the instance binds")
    check(cinv["contract_id"] == cpkg["contract_id"] == ccon["contract_id"],
          "instance, package, and contract agree on the contract")
    check(cinv["capability_id"] == ccon["capability_id"] == capdef["capability_id"],
          "contract and definition agree on the capability")
    check(cinv["effect_class"] == ccon["effect_class"] == "read-only",
          "the effect class is read from the contract")
    check(manifest["capability_package_id"] == cinv["capability_package_id"]
          and manifest["contract_id"] == cinv["contract_id"]
          and manifest["capability_id"] == cinv["capability_id"],
          "the manifest is bound to the governed identities")
    check(cinv["artifact_digest"] == manifest["artifact_sha256"],
          "the verified digest is the one the manifest declared")
    check(staged.parent.name == "sha256-" + cinv["artifact_digest"].split(":")[1],
          "the staged identity derives from the verified digest")
    check("sha256:" + _hashlib2.sha256(staged.read_bytes()).hexdigest()
          == cinv["artifact_digest"],
          "the staged bytes hash to the digest the record carries")
    check(cinv["evidence"]["outcome"] == OUTCOME_PREPARED,
          "the chain terminates in a prepared invocation record")
    check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
          f"and in nothing else ({store.counts()})")

# --- the central closure test: a hostile artefact, four ways ---------------
with TemporaryDirectory() as tmp:
    markers = {name: Path(tmp) / f"marker-{name}"
               for name in ("import", "exec", "shell", "spawn")}
    hostile = (
        "import pathlib, os, sys\n"
        f"pathlib.Path({str(markers['import'])!r}).write_text('imported')\n"
        f"os.system('touch {markers['shell']}')\n"
        f"open({str(markers['exec'])!r}, 'w').write('executed')\n"
        f"os.spawnl(os.P_NOWAIT, '/bin/true', 'true')\n"
        f"pathlib.Path({str(markers['spawn'])!r}).write_text('spawned')\n"
    ).encode("utf-8")
    digest = "sha256:" + _hashlib2.sha256(hostile).hexdigest()
    fabric_root = _chain(tmp, **{"capability-package": {
        "artifact_reference": "file:nested/artifact.bin",
        "manifest_reference": "file:nested/artifact.manifest.json"}})
    approved, artifact = _source(tmp, content=hostile,
                                 manifest=_manifest(artifact_sha256=digest))
    world = dict(fabric_root=fabric_root, approved=approved,
                 staging=_staging(tmp), payload_root=_payload_root(tmp)[0],
                 capability_root=Path(tmp) / "capability")
    _opened_capability(tmp)

    children_before = len(os.listdir("/proc/self/task"))
    code, out, err = _run(_invoke_args(tmp, **world, invocation_id="inv-hostile"))
    result = _json.loads(out)

    check(code == EXIT_DENIED and result["reason"] == REASON_NO_ADAPTER,
          f"a hostile artefact reaches only the adapter boundary ({result['reason']})")
    check(result["status"] == "prepared", "its preparation genuinely succeeded")
    for name, marker in markers.items():
        check(not marker.exists(), f"nothing {name}ed the staged artefact")
    check(len(os.listdir("/proc/self/task")) == children_before,
          "no thread or child was spawned by the invocation")

    store = _opened_capability(tmp)
    check(store.counts() == {"capability-invocation": 1, "capability-result": 0},
          "the hostile artefact produced one prepared record and no result")
    staged = Path(store.list_records("capability-invocation")[0]["staged_path"])
    check(staged.read_bytes() == hostile,
          "the hostile bytes are staged unchanged, as data")
    check(not stat.S_IMODE(staged.lstat().st_mode) & 0o111,
          "the staged hostile artefact is not executable")

# --- there is no adapter to look up ----------------------------------------
_all_production = sorted((root / "tools" / "capability").glob("*.py"))
check(len(_all_production) == 12,
      f"the package holds exactly the twelve Track-A modules ({len(_all_production)})")
_combined = "\n".join(p.read_text(encoding="utf-8") for p in _all_production)
for token, description in (
        ("import subprocess", "a subprocess import"),
        ("import multiprocessing", "a multiprocessing import"),
        ("import runpy", "a module runner"),
        ("import ctypes", "a foreign function loader"),
        ("import socket", "a socket"),
        ("shell=True", "a shell invocation"),
        ("os.fork", "a fork"),
        ("os.spawn", "a spawn"),
        ("os.posix_spawn", "a posix spawn"),
        ("docker", "docker"), ("podman", "podman"),
        ("class Adapter", "an adapter class"),
        ("def invoke_adapter", "an adapter invocation"),
        ("ADAPTERS", "an adapter table"),
        ("entry_points", "a plugin entry point"),
        ("pkgutil", "a plugin walker")):
    check(token not in _combined,
          f"no production module contains {description}")

# The refusal literal is a named constant in exactly one module. Prose may
# discuss it; only one place may define it.
_defining = [p.name for p in _all_production
             if 'REASON_NO_ADAPTER = "no_authorised_adapter"' in p.read_text(encoding="utf-8")]
check(_defining == ["coordinator.py"],
      f"the refusal literal is defined once, in the coordinator ({_defining})")

# --- dependency inventory ---------------------------------------------------
_imports = set()
for module in _all_production:
    for node in _ast.walk(_ast.parse(module.read_text(encoding="utf-8"))):
        if isinstance(node, _ast.Import):
            for alias in node.names:
                _imports.add(alias.name.split(".")[0])
        elif isinstance(node, _ast.ImportFrom) and node.level == 0 and node.module:
            _imports.add(node.module.split(".")[0])
_expected = {"__future__", "argparse", "contextlib", "dataclasses", "datetime",
             "fcntl", "hashlib", "hmac", "json", "os", "pathlib", "re", "stat",
             "sys", "tempfile", "typing", "yaml"}
check(_imports <= _expected,
      f"the package depends only on the standard library and yaml "
      f"({sorted(_imports - _expected)})")

# --- tamper matrix, composed through the interface -------------------------
_tampers = []


def _tamper(description, mutate, expected_code, expected_reason=None):
    with TemporaryDirectory() as tmp:
        world = _world(tmp)
        store = _opened_capability(tmp)
        # A mutation may return CLI overrides, or nothing at all. Anything
        # that is not a mapping is a side effect, not an argument.
        produced = mutate(world, tmp)
        overrides = produced if isinstance(produced, dict) else {}
        code, out, err = _run(_invoke_args(tmp, **world, invocation_id="inv-t",
                                           **overrides))
        body = _json.loads(out) if out.strip() else {}
        actual = body.get("reason")
        ok_code = code == expected_code
        ok_reason = expected_reason is None or actual == expected_reason
        _tampers.append((description, code, actual))
        check(ok_code and ok_reason,
              f"{description} -> exit {code} reason {actual}")
        # Nothing tampered with may ever execute.
        check(not any(Path(tmp).glob("marker*")),
              f"{description} executes nothing")


def _write_manifest(world, **overrides):
    path = world["approved"] / "nested" / "artifact.manifest.json"
    body = _json.loads(path.read_text(encoding="utf-8"))
    body.update(overrides)
    path.chmod(0o644)
    path.write_text(_json.dumps(body), encoding="utf-8")
    path.chmod(0o644)


def _write_fabric(world, kind, identity, **overrides):
    store = _FabricStore(world["fabric_root"], expected_uid=UID, expected_gid=GID)
    path = store.path_for(kind, identity)
    body = _yaml_load(path.read_text(encoding="utf-8"))
    body.update(overrides)
    path.chmod(0o600)
    path.write_text(_yaml_dump(body), encoding="utf-8")
    path.chmod(0o400)


_tamper("a claimed selection that was never made",
        lambda w, t: {"--selection-id": "CSEL-000009"}, EXIT_DENIED, "selection-not-found")
_tamper("a claimed instance the selection did not choose",
        lambda w, t: {"--instance-id": "CINST-000002"}, EXIT_DENIED,
        "claimed-instance-not-selected")
_tamper("a claimed package the instance does not bind",
        lambda w, t: {"--package-id": "CPKG-0009"}, EXIT_DENIED,
        "claimed-package-not-bound")
_tamper("a withdrawn instance",
        lambda w, t: _write_fabric(w, "capability-instance", "CINST-000001",
                                   lifecycle_state="withdrawn"),
        EXIT_DENIED, "instance-not-admitted")
_tamper("an expired admission window",
        lambda w, t: _write_fabric(w, "capability-instance", "CINST-000001",
                                   admitted_until=_OPENED.isoformat()),
        EXIT_DENIED, "admission-window-not-open")
_tamper("a side-effecting contract",
        lambda w, t: _write_fabric(w, "capability-contract", "CCON-0001",
                                   effect_class="side-effecting"),
        EXIT_DENIED, "effect-class-not-executable")
_tamper("a manifest naming another package",
        lambda w, t: _write_manifest(w, capability_package_id="CPKG-0009"),
        EXIT_DENIED, "manifest-identity-mismatch")
_tamper("a manifest naming another contract",
        lambda w, t: _write_manifest(w, contract_id="CCON-0009"),
        EXIT_DENIED, "manifest-identity-mismatch")
_tamper("a manifest naming another capability",
        lambda w, t: _write_manifest(w, capability_id="CAPDEF-0009"),
        EXIT_DENIED, "manifest-identity-mismatch")
_tamper("a manifest declaring another artefact",
        lambda w, t: _write_manifest(w, artifact_reference="file:nested/other.bin"),
        EXIT_DENIED, "manifest-identity-mismatch")
_tamper("a manifest digest for different bytes",
        lambda w, t: _write_manifest(w, artifact_sha256="sha256:" + "0" * 64),
        EXIT_DENIED, "substitution-detected")
_tamper("substituted artefact bytes",
        lambda w, t: ((w["approved"] / "nested" / "artifact.bin").chmod(0o644),
                      (w["approved"] / "nested" / "artifact.bin").write_bytes(b"other\n")),
        EXIT_DENIED, "substitution-detected")
_tamper("a group-writable artefact",
        lambda w, t: (w["approved"] / "nested" / "artifact.bin").chmod(0o664),
        EXIT_DENIED, "artifact-not-readable")
_tamper("an aliased artefact",
        lambda w, t: os.link(w["approved"] / "nested" / "artifact.bin",
                             w["approved"] / "nested" / "alias.bin"),
        EXIT_DENIED, "artifact-not-readable")
_tamper("a payload carrying a duplicate key",
        lambda w, t: ((w["payload_root"] / "payload.json").chmod(0o644),
                      (w["payload_root"] / "payload.json").write_text('{"a":1,"a":2}')),
        EXIT_USAGE)
_tamper("a payload owned by another uid",
        lambda w, t: {"--payload-source-uid": str(UID + 1)}, EXIT_USAGE)
_tamper("a group-writable payload",
        lambda w, t: (w["payload_root"] / "payload.json").chmod(0o664), EXIT_USAGE)

check(len(_tampers) == 17, f"the tamper matrix covered every case ({len(_tampers)})")

# --- staged-object tampering after publication -----------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    _run(_invoke_args(tmp, **world, invocation_id="inv-first"))
    store = _opened_capability(tmp)
    staged = Path(store.list_records("capability-invocation")[0]["staged_path"])
    staged.chmod(0o600)
    staged.write_bytes(b"tampered\n")
    staged.chmod(0o400)
    code, out, err = _run(_invoke_args(tmp, **world, invocation_id="inv-second"))
    check(code == EXIT_DENIED and _json.loads(out)["reason"] == "staged-digest-collision",
          f"a tampered staged object refuses ({_json.loads(out)['reason']})")

# --- replay, conflict, and a new decision, through the interface -----------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    first = _json.loads(_run(_invoke_args(tmp, **world, invocation_id="inv-r"))[1])
    store = _opened_capability(tmp)
    before = inventory(store.root)
    staged_before = sorted(p.name for p in world["staging"].glob("sha256-*"))

    _saved = [(_a3mod, "verify_selected_evidence", _a3mod.verify_selected_evidence),
              (_a4mod, "resolve_and_stage_package", _a4mod.resolve_and_stage_package)]
    for owner, name, _ in _saved:
        setattr(owner, name, _explode_authority)
    try:
        replayed = _json.loads(_run(_invoke_args(tmp, **world, invocation_id="inv-r"))[1])
        tripped = None
    except AssertionError as error:
        replayed, tripped = None, str(error)
    finally:
        for owner, name, original in _saved:
            setattr(owner, name, original)
    check(tripped is None, f"exact replay reruns neither verification nor staging ({tripped})")
    check(replayed["status"] == "consumed", "exact replay is consumed")
    check(inventory(store.root) == before, "exact replay writes nothing")
    check(sorted(p.name for p in world["staging"].glob("sha256-*")) == staged_before,
          "exact replay publishes nothing further")

    (world["payload_root"] / "payload.json").chmod(0o644)
    (world["payload_root"] / "payload.json").write_text('{"text":"other"}', encoding="utf-8")
    conflicting = _json.loads(_run(_invoke_args(tmp, **world, invocation_id="inv-r"))[1])
    check(conflicting["status"] == "conflict", "a changed payload conflicts")
    check(inventory(store.root) == before, "a conflict writes nothing")

    fresh = _json.loads(_run(_invoke_args(tmp, **world, invocation_id="inv-r2"))[1])
    check(fresh["status"] == "prepared" and fresh["reason"] == REASON_NO_ADAPTER,
          "a new identity is an independent decision")
    check(store.counts()["capability-invocation"] == 2, "and gets its own record")

# --- residue, told apart ----------------------------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    _run(_invoke_args(tmp, **world, invocation_id="inv-res"))
    store = _opened_capability(tmp)
    runtime_residue = store.root / "capability-invocations" / ".CINV-000009.tmp"
    runtime_residue.write_text("partial", encoding="utf-8")
    staging_residue = world["staging"] / ".staging-abc.tmp"
    staging_residue.write_text("partial", encoding="utf-8")
    before = (runtime_residue.read_bytes(), staging_residue.read_bytes())

    code, out, err = _run(["validate", "--store-root", str(world["capability_root"]),
                           "--expected-uid", str(UID), "--expected-gid", str(GID)])
    findings = _json.loads(out)["findings"]
    check(code == EXIT_DENIED and any("CINV-000009" in f for f in findings),
          f"runtime residue is reported ({findings})")
    check(not any("staging" in f for f in findings),
          "staging residue is A4's boundary, not the evidence validator's")
    check((runtime_residue.read_bytes(), staging_residue.read_bytes()) == before,
          "neither residue is cleaned")

# --- the permission map, as it actually is ---------------------------------
with TemporaryDirectory() as tmp:
    world = _world(tmp)
    _run(_invoke_args(tmp, **world, invocation_id="inv-perm"))
    store = _opened_capability(tmp)
    staged = Path(store.list_records("capability-invocation")[0]["staged_path"])
    for target, expected, description in (
            (store.root / "capability-invocations", 0o700, "the record directory"),
            (store.root / "sequences", 0o700, "the sequence directory"),
            (store.path_for("capability-invocation",
                            store.list_records("capability-invocation")[0]
                            ["invocation_record_id"]), 0o600, "a record file"),
            (staged.parent, 0o700, "the staged digest directory"),
            (staged, 0o400, "the staged artefact")):
        actual = stat.S_IMODE(Path(target).lstat().st_mode)
        check(actual == expected,
              f"{description} is {oct(expected)} ({oct(actual)})")
        check(Path(target).lstat().st_uid == UID, f"{description} is coordinator-owned")
    # Roots inherit the ambient umask, exactly as the released stores do. This
    # is recorded rather than corrected: Deferred D owns it across planes.
    check(not stat.S_IMODE(store.root.lstat().st_mode) & stat.S_IWOTH,
          "the runtime root is not world-writable")
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
