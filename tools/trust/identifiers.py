"""Identifier patterns for Trust Plane runtime records.

Six digits throughout. These records are machine-generated -- the platform
allocates them when a decision is recorded -- and the four-digit widths are
reserved for human-authored declarations elsewhere in the model.
"""

from __future__ import annotations

import re

AUTHORITY_ID = re.compile(r"^TAUTH-[0-9]{6}$")
RECORD_ID = re.compile(r"^TREC-[0-9]{6}$")
DECISION_ID = re.compile(r"^TDEC-[0-9]{6}$")
SCOPE_ID = re.compile(r"^TSCOPE-[0-9]{6}$")
EVIDENCE_ID = re.compile(r"^TEVID-[0-9]{6}$")
AUDIT_ID = re.compile(r"^TAUDIT-[0-9]{6}$")
LINEAGE_ID = re.compile(r"^TLIN-[0-9]{6}$")
# Lineage records are versioned, so the file name carries the version: a
# lineage advances by writing a new version rather than editing the previous
# one, and the head is whichever version is highest.
LINEAGE_VERSION_ID = re.compile(r"^TLIN-[0-9]{6}-v[0-9]{4}$")

PATTERNS = {
    "authority": AUTHORITY_ID,
    "record": RECORD_ID,
    "decision": DECISION_ID,
    "scope": SCOPE_ID,
    "evidence": EVIDENCE_ID,
    "audit": AUDIT_ID,
    "lineage": LINEAGE_VERSION_ID,
}

PREFIXES = {
    "authority": "TAUTH",
    "record": "TREC",
    "decision": "TDEC",
    "scope": "TSCOPE",
    "evidence": "TEVID",
    "audit": "TAUDIT",
    "lineage": "TLIN",
}
