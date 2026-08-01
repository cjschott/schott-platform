"""Manual attestation collector — structured human input, no I/O of any kind.

Accepts an attestation supplied directly through the collection context. It
opens no file, reads no environment variable, spawns no process, and touches no
network. Its manifest declares all three access flags false and means it.

The collector deliberately does not generate the timestamp or infer the actor.
An attestation is a claim by a specific person at a specific time; if the
collector supplied either, the record would assert something nobody said.

It also never claims verification. A human saying a thing is true is evidence,
not proof, so `review_required` stays true until something else verifies it.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any

from ...base import CollectorPlugin
from ...exceptions import CollectorConfigurationError
from ...models import CollectionContext, CollectorManifest, Observation
from ...normalizer import normalize_observations
from ...redaction import REDACTED, is_secret_key, is_secret_value

APPROVED_CONFIDENCE = ("low", "medium", "high")

# A clock a few minutes fast is ordinary; an attestation dated next week is
# either a mistake or an attempt to pre-date a claim.
FUTURE_SKEW_ALLOWANCE = timedelta(minutes=5)

REQUIRED_FIELDS = ("actor", "attested_at", "source_description", "facts")

# Keys that would turn an observation into an instruction. An attestation
# describes what someone saw; it never requests an action.
ACTION_KEY_PARTS = (
    "remediation", "command", "execute", "run_", "apply", "fix_",
    "restart", "deploy", "rollback", "script",
)

BLOB_PATTERNS = (
    re.compile(r"^data:[^;]+;base64,", re.I),
    re.compile(r"^[A-Za-z0-9+/]{256,}={0,2}$"),
)

MAX_VALUE_LENGTH = 2000

MANIFEST = CollectorManifest(
    id="manual-attestation",
    name="Manual Attestation Collector",
    version="0.1.0",
    source_type="manual-attestation",
    description=(
        "Accepts structured human attestations supplied through the collection "
        "context. Performs no file, network, or subprocess access and never "
        "implies verification."
    ),
    permissions=("read-declared-model",),
    capabilities=("CAP-0002",),
    supported_targets=("host", "service", "storage", "network", "backup-policy"),
    network_access=False,
    subprocess_access=False,
    filesystem_access=False,
    secret_requirements=(),
    output_contract=(
        "attestation_source", "attested_by", "attested_at",
        "source_description", "confidence", "review_required",
        "verification_implied",
    ),
    lifecycle="production",
)


def _reject(message: str) -> None:
    raise CollectorConfigurationError(message)


def _validate_fact(key: str, value: Any) -> None:
    name = str(key)
    lowered = name.lower()

    if is_secret_key(name):
        _reject(f"attested fact '{name}' is secret-bearing; value withheld")
    if any(part in lowered for part in ACTION_KEY_PARTS):
        _reject(
            f"attested fact '{name}' looks like an action request; an attestation "
            "describes what was observed and never requests remediation"
        )

    if isinstance(value, (dict, list, tuple)):
        _reject(f"attested fact '{name}' must be a scalar value")

    text = "" if value is None else str(value)
    if len(text) > MAX_VALUE_LENGTH:
        _reject(f"attested fact '{name}' exceeds the permitted length")
    for pattern in BLOB_PATTERNS:
        if pattern.match(text.strip()):
            _reject(
                f"attested fact '{name}' looks like embedded file data; attachments "
                "are not ingested in this increment"
            )
    if is_secret_value(text):
        _reject(f"attested fact '{name}' contains a secret-shaped value; value withheld")


class ManualAttestationCollector(CollectorPlugin):
    """Validates and normalizes a human-supplied attestation."""

    @property
    def manifest(self) -> CollectorManifest:
        return MANIFEST

    def validate_configuration(self, context: CollectionContext) -> None:
        attestation = (context.options or {}).get("attestation")
        if not isinstance(attestation, dict):
            _reject("manual-attestation requires an 'attestation' mapping in the context options")

        for field in REQUIRED_FIELDS:
            if field not in attestation or attestation[field] in (None, "", {}, []):
                _reject(
                    f"attestation is missing required field '{field}'; an attestation "
                    "without an actor, timestamp, source description, and facts is unattributable"
                )

        actor = str(attestation["actor"])
        if is_secret_key(actor) or is_secret_value(actor):
            _reject("attestation actor must be a plain non-secret identifier")

        raw_time = attestation["attested_at"]
        try:
            parsed = datetime.fromisoformat(str(raw_time).replace("Z", "+00:00"))
        except ValueError:
            _reject("attested_at is not a valid ISO 8601 timestamp")
        if parsed.tzinfo is None:
            _reject("attested_at must carry timezone information; a time without a zone is not a point in time")
        if parsed > datetime.now(timezone.utc) + FUTURE_SKEW_ALLOWANCE:
            _reject("attested_at is in the future beyond the permitted clock-skew allowance")

        confidence = attestation.get("confidence", "medium")
        if confidence not in APPROVED_CONFIDENCE:
            _reject(f"confidence must be one of {', '.join(APPROVED_CONFIDENCE)}")

        facts = attestation["facts"]
        if not isinstance(facts, dict) or not facts:
            _reject("attestation facts must be a non-empty mapping")
        for key, value in facts.items():
            _validate_fact(key, value)

    def collect(self, context: CollectionContext) -> dict[str, Any]:
        attestation = (context.options or {})["attestation"]
        facts = dict(attestation["facts"])

        reference = attestation.get("external_reference")
        collected: dict[str, Any] = {
            # Stated explicitly so a consumer cannot mistake this for a
            # machine observation of the target.
            "attestation_source": "human",
            "verification_implied": False,
            "review_required": bool(attestation.get("review_required", True)),
            "attested_by": str(attestation["actor"]),
            "attested_at": str(attestation["attested_at"]),
            "source_description": str(attestation["source_description"]),
            "confidence": str(attestation.get("confidence", "medium")),
        }
        if reference is not None:
            collected["external_reference"] = (
                REDACTED if is_secret_value(str(reference)) else str(reference)
            )
        collected.update(facts)
        return collected

    def normalize(self, raw_result: Any, context: CollectionContext) -> list[Observation]:
        return normalize_observations(
            raw_result,
            source="manual-attestation",
            collected_at=context.collected_at,
            sensitivity="internal",
        )
