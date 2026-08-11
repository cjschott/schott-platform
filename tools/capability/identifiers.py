"""Identifier patterns for the two Capability Runtime record kinds.

Six digits for both, matching the released convention for records a running
system produces in volume — the Fabric's advertisements, instances, and
selections carry six for the same reason. An invocation is produced by running,
not declared by an operator, so it belongs on that side of the convention.

These identities live in the Capability Runtime's own space. They share no
prefix with the eight Fabric kinds, because a `CINV` is not a Fabric record and
must never be mistakable for one.
"""

from __future__ import annotations

import re

CAPABILITY_INVOCATION_ID = re.compile(r"^CINV-[0-9]{6}$")
CAPABILITY_RESULT_ID = re.compile(r"^CRES-[0-9]{6}$")

PATTERNS = {
    "capability-invocation": CAPABILITY_INVOCATION_ID,
    "capability-result": CAPABILITY_RESULT_ID,
}

PREFIXES = {
    "capability-invocation": "CINV",
    "capability-result": "CRES",
}

# Which field carries a record's identity. Each kind names its own -- there is
# no universal `id` -- so the store has to be told rather than left to guess.
ID_FIELDS = {
    "capability-invocation": "invocation_record_id",
    "capability-result": "capability_result_id",
}

RECORD_DIRS = {
    "capability-invocation": "capability-invocations",
    "capability-result": "capability-results",
}

ID_WIDTHS = {
    "capability-invocation": 6,
    "capability-result": 6,
}
