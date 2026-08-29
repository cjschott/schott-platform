"""What a Capability Runtime decision looks like once it is durable.

Two records, both closed and both self-identifying. The invocation record says
what was decided and about which exact request; the result record says what
came of it. They are Capability Runtime records and nothing else — **the
Fabric still has exactly eight kinds**, and neither of these is one of them.

**Evidence is minimised on purpose.** A payload appears as a digest, never as a
body; an artefact appears as a digest, never as bytes. Nothing here carries a
secret, an environment, a command, or an adapter, because none of those is a
fact about the decision and every one of them would be a liability sitting in
an immutable file for ever.

**A record states its own outcome.** The invocation record carries the decision
it recorded, so a refusal interrupted before its result record still reads as a
refusal rather than as a preparation that succeeded. Reconstructing intent from
which files happen to exist is how the wrong invocation looks approved.
"""

from __future__ import annotations

RECORD_SCHEMA_VERSION = 1

INVOCATION_KIND = "capability-invocation"
RESULT_KIND = "capability-result"

# Closed. An unknown field is a record whose meaning nobody reviewed.
INVOCATION_FIELDS = (
    "invocation_record_id", "invocation_id", "request_id", "selection_id",
    "instance_id", "capability_package_id", "contract_id", "capability_id",
    "operation", "actor", "payload_digest", "binding_digest", "effect_class",
    "artifact_digest", "staged_path", "requested_at", "kind", "schema_version",
    "evidence",
)

RESULT_FIELDS = (
    "capability_result_id", "invocation_record_id", "attempt_number",
    "outcome_class", "reason", "recorded_at", "kind", "schema_version",
    "evidence",
)

# The released vocabulary. Only `refused` is reachable while no adapter exists;
# the rest are named so the vocabulary does not have to change when one does.
OUTCOME_CLASSES = ("completed", "refused", "adapter-error", "provider-error",
                   "timeout", "cancelled", "interrupted", "serialisation-failure")
