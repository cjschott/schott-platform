"""Linux resource capacity — remote and read-only.

Collects how much a machine has: processors, memory, and real filesystem
capacity. Three catalog operations, all unprivileged reads.

Everything is reported in bytes. The kernel reports memory in kibibytes and
`df` is asked for bytes explicitly, so nothing downstream has to know which
unit a given fact arrived in — a mixed-unit record is how a capacity check
ends up wrong by a factor of 1024.

Pseudo-filesystems are excluded deterministically. `tmpfs` and its relatives
are memory pretending to be disk; counting them inflates apparent capacity
with space that vanishes on reboot.

This collector measures capacity, not utilisation, and it is not a monitoring
agent. It records what a machine has, sampled when something asked.
"""

from __future__ import annotations

from typing import Any

from ...models import CollectionContext, CollectorManifest
from ...remote.plugin import RemoteCollectorPlugin

OPERATIONS = (
    "linux.cpu_summary",
    "linux.memory_summary",
    "linux.filesystem_summary",
)

# Filesystem types that do not represent durable capacity. Excluded by an
# explicit list rather than a heuristic, so the rule is reviewable and the
# same set is excluded on every host.
PSEUDO_FILESYSTEM_TYPES = frozenset({
    "tmpfs", "devtmpfs", "proc", "sysfs", "cgroup", "cgroup2", "devpts",
    "securityfs", "pstore", "efivarfs", "bpf", "debugfs", "tracefs",
    "configfs", "fusectl", "hugetlbfs", "mqueue", "ramfs", "squashfs",
    "overlay", "autofs", "binfmt_misc", "nsfs",
})

KIB = 1024

MANIFEST = CollectorManifest(
    id="linux-resources",
    name="Linux Resources Collector",
    version="0.1.0",
    source_type="ssh-command",
    description=(
        "Observes processor, memory, and durable filesystem capacity on an "
        "approved remote Linux host. Reports capacity in bytes and excludes "
        "pseudo-filesystems."
    ),
    permissions=("read-remote-host",),
    capabilities=(),
    supported_targets=("host",),
    network_access=True,
    subprocess_access=True,
    filesystem_access=False,
    secret_requirements=(),
    output_contract=(
        "cpu_logical_count", "cpu_architecture", "cpu_model",
        "memory_total_bytes", "memory_available_bytes", "filesystems",
    ),
    lifecycle="production",
)


def parse_labelled_fields(text: str) -> dict[str, str]:
    """Parse `Label: value` lines into a mapping keyed by the exact label."""
    parsed: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        label, _, value = line.partition(":")
        label = label.strip()
        if label:
            parsed[label] = value.strip()
    return parsed


def parse_kibibyte_field(fields: dict[str, str], label: str) -> int | None:
    """Convert a kernel memory field reported in kibibytes into bytes."""
    raw = fields.get(label)
    if raw is None:
        return None
    parts = raw.split()
    if not parts:
        return None
    try:
        amount = int(parts[0])
    except ValueError:
        return None
    if len(parts) > 1 and parts[1].lower() != "kb":
        # The kernel reports kB here. An unexpected unit is not guessed at.
        return None
    return amount * KIB


def parse_filesystems(text: str) -> list[dict[str, Any]]:
    """Parse the capacity table, excluding pseudo-filesystems.

    The first line is a header. Rows with an unexpected column count are
    skipped rather than positionally guessed.
    """
    rows: list[dict[str, Any]] = []
    lines = text.splitlines()
    for line in lines[1:]:
        fields = line.split()
        if len(fields) != 5:
            continue
        source, fstype, size, available, path = fields
        if fstype.lower() in PSEUDO_FILESYSTEM_TYPES:
            continue
        try:
            size_bytes = int(size)
            available_bytes = int(available)
        except ValueError:
            continue
        rows.append({
            "device": source,
            "type": fstype,
            "path": path,
            "size_bytes": size_bytes,
            "available_bytes": available_bytes,
        })
    rows.sort(key=lambda row: row["path"])
    return rows


class LinuxResourcesCollector(RemoteCollectorPlugin):
    """Observes the capacity of one approved Linux target."""

    OPERATIONS = OPERATIONS

    @property
    def manifest(self) -> CollectorManifest:
        return MANIFEST

    def collect(self, context: CollectionContext) -> dict[str, Any]:
        outcomes = self.run_operations(
            context, tuple((operation_id, None) for operation_id in OPERATIONS))

        facts: dict[str, Any] = {}

        cpu = parse_labelled_fields(outcomes["linux.cpu_summary"].stdout)
        raw_count = cpu.get("CPU(s)")
        if raw_count is not None:
            try:
                facts["cpu_logical_count"] = int(raw_count)
            except ValueError:
                pass
        if "Architecture" in cpu:
            facts["cpu_architecture"] = cpu["Architecture"]
        if "Model name" in cpu:
            facts["cpu_model"] = cpu["Model name"]

        memory = parse_labelled_fields(outcomes["linux.memory_summary"].stdout)
        total = parse_kibibyte_field(memory, "MemTotal")
        if total is not None:
            facts["memory_total_bytes"] = total
        available = parse_kibibyte_field(memory, "MemAvailable")
        if available is not None:
            facts["memory_available_bytes"] = available

        filesystems = parse_filesystems(outcomes["linux.filesystem_summary"].stdout)
        if filesystems:
            facts["filesystems"] = filesystems

        return facts
