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

# Two schemas, versioned separately.
#
# They shared one constant while the result record was only ever a refusal.
# G11-AN gave the result record the fields design section 15 names -- a digest,
# an artifact reference, and the execution's own start and end -- and bumping a
# shared constant would have reinterpreted every historical INVOCATION record
# as belonging to a schema it was not written against. The invocation record
# did not change, so its version does not move.
#
# `RECORD_SCHEMA_VERSION` is kept as the invocation version under its released
# name, because that is the value already written into invocation records.
INVOCATION_SCHEMA_VERSION = 1
RECORD_SCHEMA_VERSION = INVOCATION_SCHEMA_VERSION
RESULT_SCHEMA_VERSION = 2

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

# Closed, and now the full section 15 shape.
#
# `recorded_at` stays: it is when the record was written, which is not when the
# work ran. `started_at` and `ended_at` are the execution's own instants, taken
# from the lifecycle observation rather than from a clock the coordinator reads
# afterwards -- a result that timed the recording instead of the run would be
# describing itself.
#
# `result_artifact_reference` is null for now, and deliberately. Section 15
# requires it only "where the result is stored out of line", and no accepted
# durable result-artifact store exists: section 13 defines an append-only
# record plane and the artifacts root holds approved packages, which are
# inputs. Recording a digest without inventing a storage contract is the honest
# half of the field; see the G11-AN report.
RESULT_FIELDS = (
    "capability_result_id", "invocation_record_id", "attempt_number",
    "outcome_class", "reason", "result_digest", "result_artifact_reference",
    "started_at", "ended_at", "recorded_at", "kind", "schema_version",
    "evidence",
)

# The governed reasons a terminal result may name, and nothing else.
#
# Taken from the released vocabulary rather than invented: `serialisation-
# failure` is already an OUTCOME_CLASS, so a result whose bytes would not admit
# is named with the word the runtime already uses. `result-missing` is the one
# addition, because "completed and produced nothing" had no name and is exactly
# the case that used to read as success.
REASON_RESULT_MISSING = "result-missing"
REASON_SERIALISATION_FAILURE = "serialisation-failure"

TERMINAL_REASONS = (REASON_RESULT_MISSING, REASON_SERIALISATION_FAILURE)

# The released vocabulary. Only `refused` is reachable while no adapter exists;
# the rest are named so the vocabulary does not have to change when one does.
OUTCOME_CLASSES = ("completed", "refused", "adapter-error", "provider-error",
                   "timeout", "cancelled", "interrupted", "serialisation-failure")
