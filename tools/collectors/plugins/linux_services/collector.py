"""Linux service state — remote and read-only.

Reports the load, active, and enablement state of units the target explicitly
lists in `allowed_units`. One catalog operation, run once per named unit.

Two restrictions are deliberate and worth stating plainly.

There is no enumeration. Listing every unit on a host returns an unbounded
result shaped by whatever happens to be installed, which turns a targeted
question into a survey of the machine. Broad enumeration can be authorised
later as a decision; it will not arrive as a default.

No journal, log content, or process detail is collected. Logs are the richest
source of accidental secrets on any machine — tokens in URLs, credentials in
error messages, personal data in request traces — and a collector that reads
them ships all of that into evidence records.

Unit names are validated by the catalog against a strict pattern and must
appear in the target's allowlist. Both checks apply: the pattern stops a name
from being anything other than a unit, and the allowlist stops an approved
name from being one nobody approved.
"""

from __future__ import annotations

from typing import Any

from ...exceptions import CollectorConfigurationError
from ...models import CollectionContext, CollectorManifest
from ...remote.command_catalog import UNIT_NAME
from ...remote.plugin import RemoteCollectorPlugin

OPERATION = "linux.service_state"

# Properties requested from each unit. Fixed in the catalog argv; named here
# so parsing and the output contract agree.
UNIT_PROPERTIES = {
    "Id": "id",
    "LoadState": "load_state",
    "ActiveState": "active_state",
    "SubState": "sub_state",
    "UnitFileState": "unit_file_state",
}

MANIFEST = CollectorManifest(
    id="linux-services",
    name="Linux Services Collector",
    version="0.1.0",
    source_type="ssh-command",
    description=(
        "Observes the load, active, and enablement state of explicitly "
        "allow-listed units on an approved remote Linux host. Enumerates "
        "nothing and reads no logs."
    ),
    permissions=("read-remote-host",),
    capabilities=(),
    supported_targets=("host", "service"),
    network_access=True,
    subprocess_access=True,
    filesystem_access=False,
    secret_requirements=(),
    output_contract=("service.<unit>",),
    lifecycle="production",
)


def parse_unit_properties(text: str) -> dict[str, str]:
    """Parse `Property=value` output into the subset this collector reports."""
    parsed: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fact = UNIT_PROPERTIES.get(key.strip())
        if fact is not None:
            parsed[fact] = value.strip()
    return parsed


class LinuxServicesCollector(RemoteCollectorPlugin):
    """Observes named units on one approved Linux target."""

    OPERATIONS = (OPERATION,)

    @property
    def manifest(self) -> CollectorManifest:
        return MANIFEST

    def units_of(self, context: CollectionContext) -> tuple[str, ...]:
        target = self.target_of(context)
        return tuple(target.allowed_units or ())

    def validate_configuration(self, context: CollectionContext) -> None:
        super().validate_configuration(context)

        units = self.units_of(context)
        if not units:
            raise CollectorConfigurationError(
                "the target lists no allowed units; this collector observes "
                "named units only and never enumerates them"
            )

        for unit in units:
            if not isinstance(unit, str) or not UNIT_NAME.match(unit):
                # The rejected name is attacker-influenced text and is not
                # echoed into a message that will be logged.
                raise CollectorConfigurationError(
                    "an allowed unit name is not a valid systemd unit name; "
                    "the value is withheld"
                )

    def collect(self, context: CollectionContext) -> dict[str, Any]:
        units = self.units_of(context)
        outcomes = self.run_operations(
            context, tuple((OPERATION, unit) for unit in units))

        facts: dict[str, Any] = {}
        for unit in units:
            execution = outcomes.get(unit)
            if execution is None:
                continue
            properties = parse_unit_properties(execution.stdout)
            if properties:
                facts[f"service.{unit}"] = properties
        return facts
