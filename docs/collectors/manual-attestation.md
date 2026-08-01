# Manual Attestation Collector

Accepts a structured human attestation. Performs no I/O of any kind.

- **Plugin ID:** `manual-attestation`
- **Source type:** `manual-attestation`
- **Permissions:** `read-declared-model`
- **Network access:** false · **Subprocess:** false · **Filesystem:** false

## Purpose

Lets an operator record something only a human can observe — a rack label, a physical cable run, a vendor confirmation — as evidence with proper attribution.

## Required inputs

Supplied through `CollectionContext.options["attestation"]`:

| Field | Requirement |
|---|---|
| `actor` | Explicit non-secret identifier of who attested |
| `attested_at` | RFC 3339 timestamp **with timezone** |
| `source_description` | How the person knows |
| `facts` | Non-empty mapping of scalar facts |
| `confidence` | `low`, `medium`, or `high` (default `medium`) |
| `review_required` | Optional; defaults to true |
| `external_reference` | Optional ticket or document reference |

The collector **does not generate the timestamp or infer the actor**. An attestation is a claim by a specific person at a specific time; if the collector supplied either, the record would assert something nobody said.

## Commands executed

None. This collector opens no file, reads no environment variable, spawns no process, and touches no network.

## Collected facts

`attestation_source` (always `human`), `verification_implied` (always `false`), `review_required`, `attested_by`, `attested_at`, `source_description`, `confidence`, optional `external_reference`, plus the attested facts.

## Not collected

- **Attachments, photos, or embedded file data.** Blob and base64 payloads are rejected.
- **Anything read from disk, stdin, or the environment.**
- **Actor identity inferred from the system.**

## What an attestation does not mean

`verification_implied` is always false and `review_required` stays true unless a future verifier changes it.

A human saying a thing is true is **evidence, not proof**. The record states its own provenance as human-supplied so no consumer can mistake it for a machine observation of the target.

## Secret handling

Rejected before anything is emitted:

- Secret-bearing keys (`password`, `api_key`, `token`, …)
- Secret-shaped values (embedded credentials, bearer tokens, private keys, JWTs)
- An actor that looks secret-bearing

No rejection message echoes the offending value.

## Failure modes

Every one of these is a closed failure:

| Condition | Reason |
|---|---|
| Missing `actor`, `attested_at`, `source_description`, or `facts` | An attestation without attribution is unattributable |
| Naive timestamp | A time without a zone is not a point in time |
| Future timestamp beyond 5 minutes | Either a mistake or a pre-dated claim |
| Empty facts | Nothing was attested |
| Non-scalar fact value | Structure invites smuggled payloads |
| Secret-bearing key or value | See above |
| Action-shaped key (`remediation`, `command`, `restart`, …) | An attestation describes what was observed; it never requests remediation |
| Blob or base64 payload | Attachments are not ingested in this increment |
| Value over 2000 characters | Bounded input |
| Invalid `confidence` | Outside the approved vocabulary |

## Validation

```bash
bash tests/test-initial-collectors.sh
```

## Example output

Synthetic values:

```json
{
  "collector_id": "manual-attestation",
  "target": "HOST-0001",
  "status": "success",
  "observations": [
    {"fact": "attestation_source", "value": "human", "provenance": "observed"},
    {"fact": "verification_implied", "value": false},
    {"fact": "review_required", "value": true},
    {"fact": "attested_by", "value": "platform-engineer"},
    {"fact": "attested_at", "value": "2026-08-01T09:00:00-05:00"},
    {"fact": "source_description", "value": "visual inspection of the rack label"},
    {"fact": "rack_label", "value": "R2-U14"}
  ]
}
```

## Boundaries

- **No persistence.** Returns a `CollectorResult`; writes no file.
- **No EVID assignment.**
- **No remediation.** Action-shaped facts are rejected outright.
