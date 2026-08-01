# Operational Metadata Standard

## Purpose

This standard defines the operational metadata that every Schott Platform record must carry, and the rules that keep declared intent, observed reality, and inferred conclusions distinguishable from one another.

The [Platform Ontology Standard](platform-ontology-standard.md) requires every entity to carry operational metadata, but does not define what that metadata is. This standard supplies that definition.

The goal is narrow and specific: a human or an automated consumer such as Kyri must always be able to answer three questions about any fact in the platform model.

1. Where did this fact come from?
2. When was it true?
3. Is it still safe to act on?

A model that cannot answer those questions is not a source of truth. It is a collection of assertions with unknown reliability.

## Scope

This standard applies to:

- All machine-readable records under `platform-model/`
- Service catalog records
- Host and platform role records
- Relationship records
- Runbook and dashboard metadata blocks
- Any generated artifact that reports platform state

It does not govern application telemetry, log payloads, or metric storage. Those are covered by the [Platform Filesystem and Observability Standard](platform-filesystem-observability-standard.md).

## Core Principle

Every recorded fact carries a provenance class.

A fact without a provenance class is treated as `unknown`, not as truth. Consumers must not promote an unclassified value to an operational decision.

The platform model is a knowledge twin, not a live mirror of the environment. Git records what the platform is supposed to be. Runtime observation records what it was at a moment in time. These are different kinds of knowledge and must never be silently merged.

## Relationship to the Platform Ontology Standard

The Platform Ontology Standard defines four knowledge classes for consumers: `asserted`, `inferred`, `observed`, and `unknown`.

This standard uses `declared` where the ontology says `asserted`. The two terms describe the same class: a fact explicitly written into the platform model by a human or an approved change process.

| Ontology knowledge class | Platform model provenance value |
|---|---|
| `asserted` | `declared` |
| `observed` | `observed` |
| `inferred` | `inferred` |
| `unknown` | `unknown` |

`declared` is the canonical value in `platform-model/` records because model files record declarations of intent, not claims about live state. Consumers that expose the ontology vocabulary directly may map `declared` to `asserted` without loss of meaning.

Only one term may appear in any single record. Do not mix `declared` and `asserted` within the model.

## Provenance Classes

### `declared`

A fact explicitly written into the platform model and reviewed through normal change control.

Declared facts describe intended or approved state. They are authoritative for configuration, ownership, classification, and policy.

A declared fact does not prove the environment matches it. It proves the platform intends it to.

Examples:

- LiteLLM is intended to listen on TCP 4000.
- `schai` is classified Tier 1.
- Ollama must not publish a host port.

### `observed`

A fact collected from a live system at a specific moment.

Observed facts describe what was true at `observed_at`. They are authoritative for that instant only, and they decay.

Every observed fact must carry an `observed_at` timestamp. An observed fact without `observed_at` is invalid and must be rejected by validation.

Examples:

- A container reported healthy at a given time.
- A model was present in the volume at a given time.
- A port answered a probe at a given time.

### `inferred`

A fact derived by applying ontology inference rules to other facts.

Inferred facts must identify the rule that produced them and the inputs that fed it. They must never be recorded as `declared` or `observed`.

Inferred impact statements must use qualified language such as "may" rather than asserting certainty.

Examples:

- LiteLLM may be impacted if Ollama is unavailable.
- LiteLLM indirectly depends on `schai`.

### `unknown`

A fact that is not represented, not verifiable, or deliberately unfilled.

`unknown` is a legitimate and preferred value. An explicit `unknown` is safer than a plausible guess, and far safer than an empty field that a consumer may interpret as a negative.

Placeholder text must never be treated as an approved operational fact.

## The Metadata Envelope

Every entity record must carry a `provenance` block.

Required fields:

| Field | Requirement | Meaning |
|---|---|---|
| `class` | Always | One of `declared`, `observed`, `inferred`, `unknown` |
| `source` | Always | Where the fact came from: a document path, a command, or a rule ID |
| `recorded_at` | Always | Date the fact entered the model |
| `observed_at` | When `class` is `observed` | Timestamp the fact was true in the environment |
| `derived_from` | When `class` is `inferred` | Rule ID and input entity or relationship IDs |
| `last_reviewed` | Recommended | Date a human last confirmed the fact |

A record whose fields have mixed provenance must either carry a per-block `provenance` override or split the differing facts into separate blocks. A single record-level class must not be used to launder observed values as declared.

## Timestamps

Timestamps must be unambiguous.

- Use RFC 3339 format.
- Include an explicit UTC offset for `observed_at`.
- Date-only values are acceptable for `recorded_at` and `last_reviewed`.
- The platform operating timezone is `America/Chicago`.

Acceptable:

```text
observed_at: 2026-08-01T09:15:00-05:00
recorded_at: 2026-08-01
```

Not acceptable:

```text
observed_at: today
observed_at: 2026-08-01 09:15
recorded_at: recently
```

Relative expressions such as `now`, `current`, or `latest` must not appear as recorded values.

## Volatile Values

Volatile values change without a corresponding change to the model. Recording them as declared facts creates silent, permanent drift.

The following must not be stored as declared facts:

- Current kernel version
- Current disk usage or free space
- Current container IDs
- Current image IDs or digests
- Current uptime
- Current IP lease state
- Current process IDs
- Current model inventory
- Current certificate expiry

These values may be stored as observed facts with an `observed_at` timestamp, or referenced by the command that retrieves them. The preferred pattern is to record the retrieval command rather than the result.

Record this:

```yaml
disk_usage:
  provenance:
    class: declared
    source: docs/standards/operational-metadata-standard.md
    recorded_at: 2026-08-01
  retrieval_command: df -h /
```

Not this:

```yaml
disk_usage: 42%
```

## Freshness and Staleness

Observed facts have a useful lifetime. The model must not present a stale observation as current fact.

Consumers must:

- Compare `observed_at` against the current time before reporting an observed value.
- Qualify any observed value older than its freshness expectation as stale.
- Refresh runtime truth before high-impact decisions such as reboots, restarts, or recovery actions.
- Report the age of the observation alongside the value when the age is material.

A consumer that cannot determine freshness must report the value as `unknown` rather than as current.

Staleness is a reporting obligation, not merely a data attribute. Presenting a stale observation without qualification is a compliance failure even when the underlying value happens to still be correct.

## Conflict Resolution

When a declared fact and an observed fact disagree, the disagreement is drift.

Consumers must:

1. Report the conflict explicitly.
2. Identify both values and both provenance blocks.
3. Refrain from silently choosing the more convenient value.

Drift is an operational signal. Resolving it requires either correcting the environment to match the declaration or changing the declaration through review. Automation must not resolve drift by rewriting authoritative declared records.

## Inference Constraints

Inference may extend the model but must not manufacture certainty.

Inference must not:

- Claim live state without runtime evidence
- Represent an inferred fact as observed or declared
- Trigger write actions, configuration changes, or firewall changes
- Expose secret values
- Escalate a qualified impact statement into an unqualified one

Every inferred fact must remain traceable to its rule and inputs so a reviewer can reproduce the conclusion.

## Security and Secret Handling

Operational metadata must never contain:

- Passwords
- Private keys
- API tokens or bearer tokens
- Session secrets
- Credentials embedded in URLs
- Real environment variable values
- Unredacted prompts or model payloads

Metadata may record that a secret exists, where it is sourced from, and which entity requires it. It must not record the value.

Acceptable:

```yaml
security:
  authentication: required
  secret_source: ai/.env
```

Not acceptable:

```yaml
security:
  master_key: <the real key value>
```

Referencing a secret file by path is permitted. Committing that file, or any value from it, is prohibited.

## Canonical Example

```yaml
id: SVC-0002
type: service
name: LiteLLM

provenance:
  class: declared
  source: docs/superpowers/plans/2026-07-27-ai-platform-baseline.md
  recorded_at: 2026-08-01
  last_reviewed: 2026-08-01

network:
  listening_port: 4000
  exposure: application

health:
  provenance:
    class: declared
    source: docs/operations/operations.md
    recorded_at: 2026-08-01
  retrieval_command: curl --fail http://schai:4000/health
```

An observed block, when the model later records runtime evidence:

```yaml
last_health_result:
  provenance:
    class: observed
    source: curl --fail http://schai:4000/health
    observed_at: 2026-08-01T09:15:00-05:00
    recorded_at: 2026-08-01
  status: healthy
```

An inferred block:

```yaml
impact:
  provenance:
    class: inferred
    source: INF-003
    derived_from:
      - SVC-0002
      - SVC-0003
    recorded_at: 2026-08-01
  statement: LiteLLM may be impacted when Ollama is unavailable.
```

## Validation Requirements

Validation must verify:

- Every record carries a provenance class.
- Provenance class values are within the approved vocabulary.
- Observed facts carry `observed_at`.
- Inferred facts carry `derived_from`.
- Inferred facts are not labeled declared or observed.
- Timestamps parse as RFC 3339.
- Relative time expressions are absent.
- Prohibited volatile values are absent from declared facts.
- No secrets, tokens, passwords, or real environment values are present.

Validation must return actionable file paths and entity IDs for failures.

## Change Control

Changes to provenance semantics require:

- A clear reason
- Compatibility analysis for existing records
- Migration guidance
- Validation updates

Renaming a provenance class is a breaking semantic change and should be reviewed as an architecture decision.

## Compliance

A platform model record complies with this standard when:

- It carries a provenance class from the approved vocabulary.
- Its observed facts carry `observed_at` timestamps.
- Its inferred facts identify their rule and inputs and use qualified language.
- Its declared facts contain no volatile runtime values.
- Its timestamps are unambiguous and absolute.
- Stale observations are qualified rather than presented as current.
- Conflicts between declared and observed facts are reported rather than resolved silently.
- No secret values are present.
