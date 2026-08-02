#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for remote read-only collectors.
#
# This sprint crosses the remote-observation boundary, so the safety assertions
# here matter more than anywhere else in the repository: a defect in a local
# collector produces a wrong record, and a defect here reaches another machine.
#
# NOTHING IN THIS SUITE CONTACTS A HOST. Every behavioural test drives
# FakeRemoteTransport. The one component that could reach a host —
# SSHRemoteTransport — is tested by inspecting the argv it would build, and is
# never executed.
#
# No DNS lookup, no SSH, no network, no credential read, no host-key
# enrollment, no runtime records, no model mutation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REMOTE="tools/collectors/remote"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_contains() {
  if [[ -f "${ROOT}/$1" ]] && grep -Eq "$2" "${ROOT}/$1"; then
    pass "$3"
  else
    fail "$3 (expected /$2/ in $1)"
  fi
}

# assert_absent_in <target> <pattern> <description> [exclude-glob]
assert_absent_in() {
  local target="$1" pattern="$2" description="$3" exclude="${4:-}" matches
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  if [[ -n "${exclude}" ]]; then
    matches="$(grep -rIniE --exclude="${exclude}" -e "${pattern}" "${ROOT}/${target}" || true)"
  else
    matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${target}" || true)"
  fi
  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -2 | tr '\n' ' ')"
  fi
}

# --- Required modules ------------------------------------------------------
for module in __init__ models target transport ssh_transport command_catalog \
              result redaction; do
  assert_file "${REMOTE}/${module}.py"
done
assert_file "tools/collectors/remote_cli.py"

for plugin in linux_host linux_resources linux_services; do
  assert_file "tools/collectors/plugins/${plugin}/__init__.py"
  assert_file "tools/collectors/plugins/${plugin}/collector.py"
  assert_file "tools/collectors/plugins/${plugin}/manifest.yaml"
  assert_file "tools/collectors/plugins/${plugin}/README.md"
done

assert_file "platform-model/schemas/remote-target.schema.yaml"
assert_file "platform-model/schemas/remote-operation.schema.yaml"
assert_file "docs/decisions/ADR-0010-remote-read-only-collection.md"
for doc in remote-collection linux-host linux-resources linux-services; do
  assert_file "docs/collectors/${doc}.md"
done

# --- Identifier widths -----------------------------------------------------
assert_contains "platform-model/schemas/remote-target.schema.yaml" \
  "RTGT-\[0-9\]\{4\}" "remote target schema uses declared four-digit identifiers"
assert_contains "platform-model/schemas/remote-operation.schema.yaml" \
  "ROP-\[0-9\]\{4\}" "remote operation schema uses declared four-digit identifiers"

# --- No arbitrary execution -------------------------------------------------
# The single most important boundary: a shell reintroduces the injection
# surface argv removes.
assert_absent_in "${REMOTE}" 'shell[[:space:]]*=[[:space:]]*True' \
  "no remote code uses shell=True"
assert_absent_in "${REMOTE}" '(os\.system\(|os\.popen\(|\beval\(|\bexec\()' \
  "no remote code uses os.system, os.popen, eval, or exec"
assert_absent_in "tools/collectors/plugins/linux_host" 'shell[[:space:]]*=[[:space:]]*True' \
  "linux_host never uses a shell"
assert_absent_in "tools/collectors/plugins/linux_resources" 'shell[[:space:]]*=[[:space:]]*True' \
  "linux_resources never uses a shell"
assert_absent_in "tools/collectors/plugins/linux_services" 'shell[[:space:]]*=[[:space:]]*True' \
  "linux_services never uses a shell"

# Subprocess belongs only in the audited transport runner.
assert_absent_in "${REMOTE}" \
  '(import[[:space:]]+subprocess|from[[:space:]]+subprocess[[:space:]]+import|subprocess\.[a-zA-Z_])' \
  "subprocess appears only in ssh_transport.py" "ssh_transport.py"
assert_absent_in "${REMOTE}" \
  '(import[[:space:]]+paramiko|from[[:space:]]+paramiko|import[[:space:]]+fabric|asyncssh)' \
  "no embedded SSH library is imported"

# --- Host-key verification cannot be weakened ------------------------------
assert_absent_in "${REMOTE}" 'StrictHostKeyChecking[[:space:]]*=?[[:space:]]*(no|off|accept-new)' \
  "host-key checking is never disabled or set to accept-new"
assert_absent_in "${REMOTE}" 'UserKnownHostsFile[=[:space:]]*/dev/null' \
  "the known-hosts file is never /dev/null"
assert_contains "${REMOTE}/ssh_transport.py" 'StrictHostKeyChecking=yes' \
  "ssh transport pins StrictHostKeyChecking=yes"
assert_contains "${REMOTE}/ssh_transport.py" 'BatchMode=yes' \
  "ssh transport pins BatchMode=yes"

# --- No forwarding, no proxying, no TTY ------------------------------------
assert_absent_in "${REMOTE}" \
  '(ForwardAgent[[:space:]]*=?[[:space:]]*yes|ForwardX11[[:space:]]*=?[[:space:]]*yes|ProxyCommand|ProxyJump)' \
  "no agent, X11, or proxy forwarding is configured"
assert_absent_in "${REMOTE}" '(RequestTTY[[:space:]]*=?[[:space:]]*(yes|force)|["'"'"']-tt?["'"'"'])' \
  "no TTY allocation is requested"

# --- No privilege escalation, mutation, or downloads -----------------------
# Checked across the catalog and every plugin: these must not appear as
# executable operations anywhere.
for forbidden in sudo su doas 'apt-get' 'apt ' dnf yum rpm dpkg pacman apk \
                 'systemctl start' 'systemctl stop' 'systemctl restart' \
                 'systemctl reload' reboot shutdown mount umount chmod chown \
                 'rm ' 'mv ' 'cp ' tee curl wget 'nc ' ncat socat scp sftp \
                 rsync docker podman kubectl; do
  if grep -rIn -- "\"${forbidden}" "${ROOT}/${REMOTE}/command_catalog.py" >/dev/null 2>&1; then
    fail "catalog contains forbidden operation token: ${forbidden}"
  else
    pass "catalog contains no '${forbidden}' operation"
  fi
done

assert_absent_in "${REMOTE}/command_catalog.py" '(/bin/(ba)?sh|["'"'"']sh["'"'"']|["'"'"']bash["'"'"'])' \
  "the catalog invokes no shell"

# --- No credential material -------------------------------------------------
assert_absent_in "${REMOTE}" \
  '(BEGIN[[:space:]]+(RSA|OPENSSH|EC|DSA)[[:space:]]*PRIVATE KEY|private_key_content|key_material)' \
  "no private-key material appears in remote code"
assert_absent_in "${REMOTE}/models.py" '(^|[^a-z_])(password|passphrase)[[:space:]]*:' \
  "the target model has no password or passphrase field"
assert_absent_in "${REMOTE}" '\-o[[:space:]]*PasswordAuthentication[[:space:]]*=?[[:space:]]*yes' \
  "password authentication is never enabled"

# --- No discovery -----------------------------------------------------------
assert_absent_in "${REMOTE}" \
  '(ipaddress\.ip_network|CIDR|subnet_scan|discover_hosts|nmap|ping[[:space:]]+-c)' \
  "no target discovery or subnet scanning exists"

# --- No persistence, no identifiers, no remediation ------------------------
assert_absent_in "${REMOTE}" '(EVID-[0-9]|VER-[0-9]|MEM-[0-9]|OBS-[0-9]|OCC-[0-9])' \
  "remote code assigns no persistent record identifier"
assert_absent_in "${REMOTE}" \
  '(write_evidence|persist_evidence|EvidenceStore|OccurrenceStore)' \
  "remote code never persists evidence"
assert_absent_in "${REMOTE}" \
  '(def[[:space:]]+(remediate|repair|fix)_|auto_remediate|apply_fix)' \
  "no remediation path exists in remote code"
assert_absent_in "${REMOTE}" \
  "(open\\(['\"][^'\"]*platform-model[^'\"]*['\"],[[:space:]]*['\"][wax])" \
  "remote code never writes into platform-model"
assert_absent_in "${REMOTE}" "['\"][^'\"]*ai/\\.env['\"]" \
  "remote code never references ai/.env"

# --- CI and local validation wiring ----------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-remote-collectors\.sh' \
  "ci runs the remote collector tests"
assert_contains "tools/dev/run-validation.sh" 'tests/test-remote-collectors\.sh' \
  "local validation runs the remote collector suite"

# --- Behavioural validation ------------------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'PY' 2>&1 || true
import json
import os
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
os.chdir(root)

failures = 0
CANARY = "CANARY-REMOTE-MUST-NOT-APPEAR-8d4f"


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


try:
    from tools.collectors.models import CollectorResult
    from tools.collectors.remote.models import (
        AuthenticationReference, RemoteExecutionResult, RemoteFailureCategory,
        RemoteOperation, RemoteTarget,
    )
    from tools.collectors.remote.target import TargetError, load_target, validate_target
    from tools.collectors.remote.transport import FakeRemoteTransport, RemoteTransport
    from tools.collectors.remote.ssh_transport import SSHRemoteTransport, build_ssh_argv
    from tools.collectors.remote.command_catalog import (
        CATALOG, CatalogError, operation_for, operation_ids,
    )
    from tools.collectors.remote.redaction import redact_remote_output
    from tools.collectors.plugins.linux_host.collector import LinuxHostCollector
    from tools.collectors.plugins.linux_resources.collector import LinuxResourcesCollector
    from tools.collectors.plugins.linux_services.collector import LinuxServicesCollector
    from tools.collectors.models import CollectionContext
    ok("remote modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"remote import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

STAMP = "2026-08-02T09:00:00-05:00"


def target(**overrides):
    defaults = dict(
        target_id="RTGT-0001",
        hostname="host.invalid",
        port=22,
        username="observer",
        host_key_policy="strict",
        known_hosts_reference="/approved/known_hosts",
        authentication_reference=AuthenticationReference(
            kind="ssh-key-path", reference="/approved/keys/observer"),
        platform="linux",
        trust_classification="internal",
        allowed_operation_ids=tuple(operation_ids()),
        connect_timeout_seconds=5,
        command_timeout_seconds=15,
        max_stdout_bytes=65536,
        max_stderr_bytes=4096,
        allowed_units=("nginx.service",),
    )
    defaults.update(overrides)
    return RemoteTarget(**defaults)


def context(**extra):
    options = {"target": target()}
    options.update(extra)
    return CollectionContext(target="HOST-0001", declared={}, requested_facts=(),
                             collected_at=STAMP, options=options)


# --- Catalog: code-owned, argv-only ---------------------------------------
check(len(operation_ids()) >= 9, "the catalog defines at least nine operations")
for identifier in ("linux.hostname", "linux.os_release", "linux.kernel",
                   "linux.architecture", "linux.uptime", "linux.cpu_summary",
                   "linux.memory_summary", "linux.filesystem_summary",
                   "linux.service_state"):
    check(identifier in operation_ids(), f"catalog defines {identifier}")

for identifier in operation_ids():
    operation = operation_for(identifier)
    check(isinstance(operation.argv, tuple) and operation.argv,
          f"{identifier} is an argv tuple")
    check(all(isinstance(part, str) for part in operation.argv),
          f"{identifier} argv contains only strings")
    check(operation.timeout_ceiling_seconds > 0, f"{identifier} has a positive timeout ceiling")
    check(operation.output_ceiling_bytes > 0, f"{identifier} has an output ceiling")
    check(operation.platform == "linux", f"{identifier} declares its platform")
    check(operation.required_privilege == "unprivileged",
          f"{identifier} requires no privilege")
    lowered = " ".join(operation.argv).lower()
    for forbidden in ("sudo", "sh -c", "bash", "apt", "yum", "systemctl start",
                      "systemctl stop", "rm ", "curl", "wget", "docker"):
        check(forbidden not in lowered, f"{identifier} contains no '{forbidden}'")

try:
    operation_for("linux.definitely_not_real")
    bad("an unknown operation identifier is rejected")
except CatalogError:
    ok("an unknown operation identifier is rejected")

# The catalog must not accept command text from a caller.
check(not any(hasattr(CATALOG, name) for name in ("add", "register", "extend", "update")),
      "the catalog exposes no mutation entry point")

# --- SSH argv builder: inspected, never executed --------------------------
argv = build_ssh_argv(target(), operation_for("linux.hostname"))
joined = " ".join(argv)
check(argv[0].endswith("ssh"), "the transport invokes the ssh client directly")
for required in ("BatchMode=yes", "StrictHostKeyChecking=yes",
                 "UserKnownHostsFile=/approved/known_hosts", "ConnectTimeout=5"):
    check(required in joined, f"ssh argv pins {required}")
for forbidden in ("StrictHostKeyChecking=no", "StrictHostKeyChecking=accept-new",
                  "/dev/null", "ForwardAgent=yes", "ForwardX11=yes",
                  "ProxyCommand", "ProxyJump", "-tt", "PasswordAuthentication=yes",
                  "ControlMaster", "-L ", "-R ", "-D "):
    check(forbidden not in joined, f"ssh argv excludes {forbidden}")
check(all(isinstance(part, str) for part in argv), "ssh argv contains only strings")
check(argv == build_ssh_argv(target(), operation_for("linux.hostname")),
      "ssh argv construction is deterministic")
# The remote operation words appear as separate argv entries, never as one
# shell string.
check("hostname" in argv, "the operation argv is passed as discrete arguments")

# Missing references must fail before any ssh invocation is attempted.
for broken, label in ((target(known_hosts_reference=""), "known-hosts reference"),
                      (target(authentication_reference=None), "authentication reference")):
    try:
        build_ssh_argv(broken, operation_for("linux.hostname"))
        bad(f"a missing {label} fails before ssh is invoked")
    except (ValueError, TargetError):
        ok(f"a missing {label} fails before ssh is invoked")

check(issubclass(SSHRemoteTransport, RemoteTransport),
      "the ssh transport implements the transport interface")

# --- Target model: explicit, no credentials -------------------------------
fields = set(RemoteTarget.__dataclass_fields__)
for absent in ("password", "passphrase", "private_key", "key_content", "secret"):
    check(absent not in fields, f"the target model has no '{absent}' field")
check("authentication_reference" in fields, "the target references authentication")
check("known_hosts_reference" in fields, "the target references known hosts")

for bad_host in ("10.0.0.0/24", "192.168.1.1-192.168.1.50", "*.example.invalid", ""):
    try:
        validate_target(target(hostname=bad_host))
        bad(f"a range or wildcard hostname is rejected: {bad_host!r}")
    except TargetError:
        ok(f"a range or wildcard hostname is rejected: {bad_host!r}")

for bad_port in (0, 65536, -1):
    try:
        validate_target(target(port=bad_port))
        bad(f"an out-of-range port is rejected: {bad_port}")
    except TargetError:
        ok(f"an out-of-range port is rejected: {bad_port}")

for field, value in (("username", ""), ("connect_timeout_seconds", 0),
                     ("command_timeout_seconds", 0), ("max_stdout_bytes", 0)):
    try:
        validate_target(target(**{field: value}))
        bad(f"an invalid {field} is rejected")
    except TargetError:
        ok(f"an invalid {field} is rejected")

try:
    validate_target(target(platform="windows"))
    bad("an unsupported platform is rejected")
except TargetError:
    ok("an unsupported platform is rejected")

try:
    validate_target(target(host_key_policy="ignore"))
    bad("a permissive host-key policy is rejected")
except TargetError:
    ok("a permissive host-key policy is rejected")

# --- Collectors run against the fake transport only -----------------------
HOSTNAME_OUT = "web01.invalid\n"
OS_RELEASE_OUT = 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\nID=ubuntu\nVERSION_ID="24.04"\n'
KERNEL_OUT = "6.8.0-136-generic\n"
ARCH_OUT = "x86_64\n"
UPTIME_OUT = "123456.78 987654.32\n"
CPU_OUT = "Architecture: x86_64\nCPU(s): 8\nModel name: Test CPU\n"
MEM_OUT = "MemTotal:       16327456 kB\nMemAvailable:   10485760 kB\n"
FS_OUT = ("Filesystem Type 1B-blocks Available Mounted on\n"
          "/dev/sda1 ext4 500000000000 250000000000 /\n"
          "tmpfs tmpfs 8000000000 8000000000 /run\n")
SERVICE_OUT = ("Id=nginx.service\nLoadState=loaded\nActiveState=active\n"
               "SubState=running\nUnitFileState=enabled\n")

RESPONSES = {
    "linux.hostname": HOSTNAME_OUT,
    "linux.os_release": OS_RELEASE_OUT,
    "linux.kernel": KERNEL_OUT,
    "linux.architecture": ARCH_OUT,
    "linux.uptime": UPTIME_OUT,
    "linux.cpu_summary": CPU_OUT,
    "linux.memory_summary": MEM_OUT,
    "linux.filesystem_summary": FS_OUT,
    "linux.service_state": SERVICE_OUT,
}

transport = FakeRemoteTransport(responses=RESPONSES)
host_result = LinuxHostCollector().execute(context(transport=transport))
check(isinstance(host_result, CollectorResult), "linux-host returns a CollectorResult")
check(host_result.status == "success", "linux-host succeeds against the fake transport")
facts = {o.fact: o.value for o in host_result.observations}
check(facts.get("hostname") == "web01.invalid", "linux-host collects the hostname")
check("ubuntu" in str(facts.get("os_id", "")).lower(), "linux-host collects OS identity")
check(facts.get("kernel_release") == "6.8.0-136-generic", "linux-host collects the kernel release")
check(facts.get("architecture") == "x86_64", "linux-host collects the architecture")
check(int(facts.get("uptime_seconds", 0)) == 123456, "linux-host collects uptime seconds")
for forbidden in ("users", "environment", "processes", "command_history",
                  "network_connections", "installed_packages"):
    check(forbidden not in facts, f"linux-host does not collect {forbidden}")

resources = LinuxResourcesCollector().execute(context(transport=FakeRemoteTransport(responses=RESPONSES)))
rfacts = {o.fact: o.value for o in resources.observations}
check(resources.status == "success", "linux-resources succeeds")
check(int(rfacts.get("cpu_logical_count", 0)) == 8, "linux-resources collects the CPU count")
check(int(rfacts.get("memory_total_bytes", 0)) == 16327456 * 1024,
      "linux-resources converts total memory to bytes")
check(int(rfacts.get("memory_available_bytes", 0)) == 10485760 * 1024,
      "linux-resources converts available memory to bytes")
check("ext4" in json.dumps(rfacts), "linux-resources reports the filesystem type")
check("tmpfs" not in json.dumps(rfacts),
      "linux-resources excludes pseudo-filesystems deterministically")

services = LinuxServicesCollector().execute(context(transport=FakeRemoteTransport(responses=RESPONSES)))
sfacts = {o.fact: o.value for o in services.observations}
check(services.status == "success", "linux-services succeeds")
blob = json.dumps(sfacts)
for expected in ("nginx.service", "loaded", "active", "running", "enabled"):
    check(expected in blob, f"linux-services reports {expected}")
for forbidden in ("journal", "logs", "process_list"):
    check(forbidden not in blob, f"linux-services does not collect {forbidden}")

multi = target(allowed_units=("zeta.service", "alpha.service", "mid.service"))
multi_transport = FakeRemoteTransport(responses=RESPONSES)
multi_result = LinuxServicesCollector().execute(
    CollectionContext(target="HOST-0001", declared={}, requested_facts=(),
                      collected_at=STAMP,
                      options={"target": multi, "transport": multi_transport}))
unit_facts = [o.fact for o in multi_result.observations]
check(unit_facts == sorted(unit_facts), "multiple services are ordered deterministically")

# Unit names must be validated and drawn from the allowlist.
for evil in ("nginx.service; rm -rf /", "../../etc/passwd", "*", "nginx.service extra"):
    evil_result = LinuxServicesCollector().execute(
        CollectionContext(target="HOST-0001", declared={}, requested_facts=(),
                          collected_at=STAMP,
                          options={"target": target(allowed_units=(evil,)),
                                   "transport": FakeRemoteTransport(responses=RESPONSES)}))
    check(evil_result.status in {"failed", "partial"},
          f"an invalid unit name is refused: {evil!r}")
    check(CANARY not in json.dumps([e.__dict__ for e in evil_result.errors]),
          "unit rejection leaks nothing")

# --- Authorization and platform -------------------------------------------
unauthorized = target(allowed_operation_ids=("linux.hostname",))
denied = LinuxResourcesCollector().execute(
    CollectionContext(target="HOST-0001", declared={}, requested_facts=(),
                      collected_at=STAMP,
                      options={"target": unauthorized,
                               "transport": FakeRemoteTransport(responses=RESPONSES)}))
check(denied.status == "failed", "an unauthorized operation is refused")
check(any(e.category == RemoteFailureCategory.UNSUPPORTED_TARGET.value or
          "authoriz" in e.summary.lower() for e in denied.errors),
      "the refusal names missing authorization")

# --- Failure categories -----------------------------------------------------
CATEGORY_CASES = (
    ("timeout", RemoteFailureCategory.TIMEOUT.value),
    ("output_limit", RemoteFailureCategory.OUTPUT_LIMIT.value),
    ("authentication_failure", RemoteFailureCategory.AUTHENTICATION_FAILURE.value),
    ("host_key_failure", RemoteFailureCategory.HOST_KEY_FAILURE.value),
    ("transport_failure", RemoteFailureCategory.TRANSPORT_FAILURE.value),
)
for mode, expected in CATEGORY_CASES:
    failing = FakeRemoteTransport(responses=RESPONSES, failure_mode=mode)
    result = LinuxHostCollector().execute(context(transport=failing))
    check(result.status in {"failed", "unavailable"}, f"{mode} produces a failed result")
    check(any(e.category == expected for e in result.errors),
          f"{mode} is categorised as {expected}")
    summaries = " ".join(e.summary.lower() for e in result.errors)
    for claim in ("host is down", "service failed", "infrastructure drifted",
                  "declared state is wrong"):
        check(claim not in summaries, f"{mode} does not claim '{claim}'")

# Truncated and timed-out output must not be accepted partially.
truncated = FakeRemoteTransport(responses=RESPONSES, failure_mode="output_limit")
partial = LinuxHostCollector().execute(context(transport=truncated))
check(not any(o.fact == "hostname" for o in partial.observations),
      "no partial output is accepted after a truncation failure")

# --- Secrets never escape ---------------------------------------------------
for stream in ("stdout", "stderr", "exception"):
    leaky = FakeRemoteTransport(responses=RESPONSES, leak=(stream, CANARY))
    result = LinuxHostCollector().execute(context(transport=leaky))
    serialized = json.dumps({
        "obs": [o.__dict__ for o in result.observations],
        "err": [e.__dict__ for e in result.errors],
        "fp": result.content_fingerprint,
    }, default=str)
    check(CANARY not in serialized, f"a secret in {stream} never reaches the result")

check(CANARY not in redact_remote_output(f"https://user:{CANARY}@host/x")[0],
      "remote output redaction removes embedded credentials")

# --- Invalid UTF-8 decodes deterministically ------------------------------
binary = FakeRemoteTransport(responses=RESPONSES, raw_bytes=b"\xff\xfeweb01\n")
binary_result = LinuxHostCollector().execute(context(transport=binary))
check(binary_result.status in {"success", "partial", "failed"},
      "invalid UTF-8 does not crash the collector")
repeat = LinuxHostCollector().execute(
    context(transport=FakeRemoteTransport(responses=RESPONSES, raw_bytes=b"\xff\xfeweb01\n")))
check([o.value for o in binary_result.observations] == [o.value for o in repeat.observations],
      "invalid UTF-8 decoding is deterministic")

# --- Determinism and non-persistence ---------------------------------------
first = LinuxHostCollector().execute(context(transport=FakeRemoteTransport(responses=RESPONSES)))
second = LinuxHostCollector().execute(context(transport=FakeRemoteTransport(responses=RESPONSES)))
check([(o.fact, o.value) for o in first.observations] ==
      [(o.fact, o.value) for o in second.observations],
      "repeated collection with identical input is byte-identical")
# The fingerprint is a content hash over normalized, redacted observations,
# computed by the framework's execute() lifecycle. It is not an identity: the
# guarantee that matters is that no collector assigns a record identifier.
check(first.content_fingerprint.startswith("sha256:"),
      "remote results carry a framework content fingerprint")
check(first.content_fingerprint == second.content_fingerprint,
      "identical remote input produces an identical fingerprint")
for record in (first, resources, services):
    blob = json.dumps({"o": [o.__dict__ for o in record.observations]}, default=str)
    for prefix in ("EVID-", "VER-", "MEM-", "OBS-", "OCC-"):
        check(prefix not in blob, f"no {prefix} identifier is assigned by a collector")

model_before = sorted((str(p.relative_to(root)), p.stat().st_size)
                      for p in (root / "platform-model").rglob("*") if p.is_file())
LinuxHostCollector().execute(context(transport=FakeRemoteTransport(responses=RESPONSES)))
model_after = sorted((str(p.relative_to(root)), p.stat().st_size)
                     for p in (root / "platform-model").rglob("*") if p.is_file())
check(model_before == model_after, "remote collection never modifies platform-model")

# --- Target loading: containment and references ---------------------------
with tempfile.TemporaryDirectory() as tmp:
    approved = Path(tmp) / "approved"
    approved.mkdir()
    target_yaml = """---
target_id: RTGT-0001
hostname: web01.invalid
port: 22
username: observer
host_key_policy: strict
known_hosts_reference: /approved/known_hosts
authentication_reference:
  kind: ssh-key-path
  reference: /approved/keys/observer
platform: linux
trust_classification: internal
allowed_operation_ids:
  - linux.hostname
connect_timeout_seconds: 5
command_timeout_seconds: 15
max_stdout_bytes: 65536
max_stderr_bytes: 4096
allowed_units: []
"""
    (approved / "web01.yaml").write_text(target_yaml, encoding="utf-8")
    loaded = load_target("web01.yaml", approved_directory=str(approved))
    check(loaded.hostname == "web01.invalid", "a target loads from an approved directory")
    check(loaded.authentication_reference.reference == "/approved/keys/observer",
          "authentication is a reference, not material")

    outside = Path(tmp) / "outside.yaml"
    outside.write_text(target_yaml, encoding="utf-8")
    (approved / "escape.yaml").symlink_to(outside)
    for escape in ("escape.yaml", "../outside.yaml"):
        try:
            load_target(escape, approved_directory=str(approved))
            bad(f"a target file escaping the approved directory is refused: {escape}")
        except TargetError:
            ok(f"a target file escaping the approved directory is refused: {escape}")

    # Credential material inside a target file must be refused outright.
    (approved / "withkey.yaml").write_text(
        target_yaml + f"password: {CANARY}\n", encoding="utf-8")
    try:
        load_target("withkey.yaml", approved_directory=str(approved))
        bad("a target file carrying a password is refused")
    except TargetError as error:
        ok("a target file carrying a password is refused")
        check(CANARY not in str(error), "the refusal never echoes the credential")

# --- CLI --------------------------------------------------------------------
import subprocess  # noqa: E402 - the harness runs the CLI as a child


def cli(*args, expect=None):
    proc = subprocess.run([sys.executable, "-m", "tools.collectors.remote_cli", *args],
                          capture_output=True, text=True, cwd=str(root),
                          env={**os.environ, "PYTHONPATH": str(root)})
    if expect is not None:
        check(proc.returncode == expect,
              f"cli {args[0] if args else ''} exits {expect} (got {proc.returncode})")
    return proc


help_proc = cli("--help")
import re as _re  # noqa: E402
choices = _re.search(r"\{([a-z,\-]+)\}", help_proc.stdout)
commands = set(choices.group(1).split(",")) if choices else set()
for command in ("list-operations", "validate-target", "collect"):
    check(command in commands, f"cli exposes {command}")
for forbidden in ("enroll", "trust", "add-key", "install", "remediate"):
    check(forbidden not in commands, f"cli exposes no {forbidden} command")

listed = cli("list-operations", expect=0)
check("linux.hostname" in listed.stdout, "cli list-operations reports the catalog")
check(listed.stdout == cli("list-operations").stdout,
      "cli list-operations output is deterministic")

# No target contents may be supplied on the command line.
check("--hostname" not in help_proc.stdout and "--command" not in help_proc.stdout,
      "cli accepts no inline target or command content")

cli("collect", "--collector", "linux-host", expect=2)

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "remote collector behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for the remote collector tests.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nRemote collector validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nRemote collector validation passed.\n'
