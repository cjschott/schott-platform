"""Linux host identity — remote and read-only.

Collects what a machine says it is: name, operating system, kernel,
architecture, and how long it has been up. Five catalog operations, all
unprivileged reads.

What it deliberately does not collect is the more important list. No user
accounts, no environment, no process list, no command history, no network
connections, no installed packages. Each would be easy to add and each turns
an identity check into surveillance of whoever uses the machine. An inventory
of installed packages is also a ready-made list of what to attack.

Unparseable output yields no fact rather than a zero. A machine that returned
something this collector could not read has told it nothing, and recording
that as 0 would be an invention.
"""

from __future__ import annotations

from typing import Any

from ...models import CollectionContext, CollectorManifest
from ...remote.plugin import RemoteCollectorPlugin

OPERATIONS = (
    "linux.hostname",
    "linux.os_release",
    "linux.kernel",
    "linux.architecture",
    "linux.uptime",
)

MANIFEST = CollectorManifest(
    id="linux-host",
    name="Linux Host Collector",
    version="0.1.0",
    source_type="ssh-command",
    description=(
        "Observes the identity of an approved remote Linux host: name, "
        "operating system, kernel, architecture, and uptime. Collects no "
        "users, processes, packages, or network state."
    ),
    permissions=("read-remote-host",),
    capabilities=(),
    supported_targets=("host",),
    network_access=True,
    subprocess_access=True,
    filesystem_access=False,
    secret_requirements=(),
    output_contract=(
        "hostname", "os_id", "os_pretty_name", "os_version_id",
        "kernel_release", "architecture", "uptime_seconds",
    ),
    lifecycle="production",
)


def first_line(text: str) -> str | None:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped
    return None


def parse_os_release(text: str) -> dict[str, str]:
    """Parse the standard KEY=VALUE release file.

    Values are optionally quoted. Malformed lines are skipped rather than
    guessed at.
    """
    parsed: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        parsed[key.strip().upper()] = value
    return parsed


def parse_uptime_seconds(text: str) -> int | None:
    """Whole seconds since boot, from the kernel's two-field uptime."""
    line = first_line(text)
    if not line:
        return None
    field = line.split()[0] if line.split() else ""
    try:
        return int(float(field))
    except ValueError:
        return None


class LinuxHostCollector(RemoteCollectorPlugin):
    """Observes the identity of one approved Linux target."""

    OPERATIONS = OPERATIONS

    @property
    def manifest(self) -> CollectorManifest:
        return MANIFEST

    def collect(self, context: CollectionContext) -> dict[str, Any]:
        outcomes = self.run_operations(
            context, tuple((operation_id, None) for operation_id in OPERATIONS))

        facts: dict[str, Any] = {}

        hostname = first_line(outcomes["linux.hostname"].stdout)
        if hostname is not None:
            facts["hostname"] = hostname

        release = parse_os_release(outcomes["linux.os_release"].stdout)
        for fact, key in (("os_id", "ID"), ("os_pretty_name", "PRETTY_NAME"),
                          ("os_version_id", "VERSION_ID")):
            if key in release:
                facts[fact] = release[key]

        kernel = first_line(outcomes["linux.kernel"].stdout)
        if kernel is not None:
            facts["kernel_release"] = kernel

        architecture = first_line(outcomes["linux.architecture"].stdout)
        if architecture is not None:
            facts["architecture"] = architecture

        uptime = parse_uptime_seconds(outcomes["linux.uptime"].stdout)
        if uptime is not None:
            facts["uptime_seconds"] = uptime

        return facts
