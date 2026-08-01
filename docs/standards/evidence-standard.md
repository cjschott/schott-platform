# Evidence Standard

## Purpose

This standard defines evidence: immutable, timestamped support for an observed fact.

The platform model records what the platform is *supposed* to be. Evidence is how a claim about what it *was* enters the model without contaminating that declaration. Without a defined evidence record, observation and intent blur together, and the model loses the ability to say which of its statements anyone actually checked.

**This sprint creates schemas only. No evidence is collected, and no collector exists.**

## Scope

Applies to every record under `platform-model/evidence/`.

It does not govern verification outcomes or drift evaluation, which are covered by the [Verification and Drift Standard](verification-drift-standard.md).

## Core Principle

Evidence is immutable and bounded in time.

An evidence record makes exactly one kind of claim: *at `collected_at`, this collector observed these facts about this target.* It never claims the facts are still true, and the schema gives it no way to.

## Approved Source Types

- `manual-attestation` — a human recorded what they saw
- `command-output` — output of a local command
- `ssh-command` — output of a remote command over SSH
- `api-response` — response from a service API
- `file-inspection` — contents or attributes of a file
- `configuration-render` — rendered configuration, such as `docker compose config`
- `health-check` — result of a defined health probe
- `backup-report` — output of a backup or verification job
- `monitoring-query` — result of a metrics or logging query
- `git-repository` — state derived from repository contents

A source type outside this list requires a documented standard change. Unapproved source types are rejected by validation.

## Required Fields

| Field | Meaning |
|---|---|
| `id` | Stable four-digit identifier, `EVID-0001` |
| `type` | Always `evidence` |
| `target` | Entity id the evidence is about |
| `source_type` | One of the approved source types |
| `collector` | What produced the record |
| `collected_at` | RFC 3339 timestamp with explicit offset |
| `status` | Collection outcome |
| `facts` | Normalized observations |
| `provenance` | Always class `observed`, carrying `observed_at` |
| `sensitivity` | Handling classification |
| `retention` | How long the record is kept |
| `content_fingerprint` | Digest of the normalized source material |
| `redaction` | What was removed, and whether anything was |
| `references` | Supporting documents or superseded evidence |

## Status Values

- `success` — collection completed and facts are trustworthy
- `partial` — collection completed but some facts are missing
- `failed` — collection ran and did not succeed
- `unavailable` — collection could not be attempted

Failed and unavailable records must include a non-secret `error_summary`. A failure with no explanation is indistinguishable from a bug in the collector, and both need to be visible.

**A collection failure is not a service failure.** It says the platform could not look, not that the target is broken. Consumers must not translate one into the other.

## Sensitivity Values

- `public` — no handling restriction
- `internal` — ordinary platform operational data
- `restricted` — limited distribution
- `secret-metadata` — describes the existence or shape of a secret, never its value

## Secret Handling

Evidence may record secret **metadata**:

```yaml
facts:
  secret_present: true
  secret_source: ai/.env
  secret_length_class: long
```

Evidence must **never** record:

- Secret values of any kind
- API keys or tokens
- Passwords
- Private keys
- Bearer tokens
- Session cookies
- Full authentication headers

This is enforced by validation, which rejects secret-bearing keys and never echoes a flagged value in its error output — an error message that prints the secret it objected to has leaked it into CI logs.

The distinction matters operationally: knowing a credential *exists and is referenced* is useful for verification; knowing its value is a liability with no verification benefit.

## Immutability

- **Existing evidence is never overwritten.** A record describes one moment; editing it destroys the only thing it was for.
- **Recollection creates a new `EVID` identifier.** Two collections are two facts about two moments.
- **Corrections supersede rather than replace.** A superseding record references what it supersedes, and both remain.
- **Identifiers are never reused.**

## Repository Content Rules

- **Raw command output is not committed by default.** Command dumps carry incidental secrets, host detail, and noise, and they are not reviewable.
- **Repository evidence contains normalized facts plus a `content_fingerprint`,** not arbitrary output. The fingerprint proves what was seen without republishing it.
- **Redaction must be declared.** A record that removed material says so, so a reader knows the facts are partial by design rather than by accident.

## Time Rules

- `collected_at` is required on every record.
- `provenance.observed_at` is required, because evidence provenance is always `observed`.
- Timestamps are RFC 3339 with an explicit offset. Naive timestamps are rejected: a time without a zone is not a time.
- Relative expressions such as `now` or `latest` are never recorded as values.

**Evidence must not claim continuous truth beyond its collection timestamp.** Its age is always evaluable, and consumers must qualify it by age rather than presenting it as current state.

## Compliance

An evidence record complies when:

- It carries every required field.
- Its id is a unique four-digit `EVID` identifier.
- Its target resolves to an existing entity.
- Its source type, status, and sensitivity are drawn from the approved vocabularies.
- Its timestamps are absolute and carry timezone information.
- Its provenance class is `observed` with an `observed_at` value.
- Failed or unavailable collection includes a non-secret error summary.
- It contains no secret value.
- It declares any redaction performed.
- It supersedes rather than overwrites prior evidence.
