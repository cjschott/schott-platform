"""Identifier patterns for the eight accepted Fabric record kinds.

Widths are not cosmetic. Human-declared records — definitions, contracts,
packages, hosts, and routes — carry **four** digits, because an operator writes
them deliberately and a four-digit space is a reminder that they are meant to
be few. Records produced while the fabric runs — advertisements, instances, and
selections — carry **six**, because a running system produces them in volume.

Patterns are taken from the accepted schemas in `platform-model/schemas/`, not
restated from memory.
"""

from __future__ import annotations

import re

CAPABILITY_DEFINITION_ID = re.compile(r"^CAPDEF-[0-9]{4}$")
CAPABILITY_CONTRACT_ID = re.compile(r"^CCON-[0-9]{4}$")
CAPABILITY_PACKAGE_ID = re.compile(r"^CPKG-[0-9]{4}$")
CAPABILITY_HOST_ID = re.compile(r"^CHOST-[0-9]{4}$")
CAPABILITY_ROUTE_ID = re.compile(r"^CROUTE-[0-9]{4}$")

CAPABILITY_ADVERTISEMENT_ID = re.compile(r"^CADV-[0-9]{6}$")
CAPABILITY_INSTANCE_ID = re.compile(r"^CINST-[0-9]{6}$")
CAPABILITY_SELECTION_ID = re.compile(r"^CSEL-[0-9]{6}$")

PATTERNS = {
    "capability-definition": CAPABILITY_DEFINITION_ID,
    "capability-contract": CAPABILITY_CONTRACT_ID,
    "capability-package": CAPABILITY_PACKAGE_ID,
    "capability-host": CAPABILITY_HOST_ID,
    "capability-advertisement": CAPABILITY_ADVERTISEMENT_ID,
    "capability-instance": CAPABILITY_INSTANCE_ID,
    "capability-route": CAPABILITY_ROUTE_ID,
    "capability-selection": CAPABILITY_SELECTION_ID,
}

PREFIXES = {
    "capability-definition": "CAPDEF",
    "capability-contract": "CCON",
    "capability-package": "CPKG",
    "capability-host": "CHOST",
    "capability-advertisement": "CADV",
    "capability-instance": "CINST",
    "capability-route": "CROUTE",
    "capability-selection": "CSEL",
}
