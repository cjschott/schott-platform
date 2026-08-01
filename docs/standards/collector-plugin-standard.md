# Collector Plugin Standard

## Purpose

This standard defines the contract every evidence collector implements.

A collector is the point where the outside world first touches the platform model. That makes it the most dangerous component in the system and the one most likely to accumulate quiet privilege — a little filesystem access here, a subprocess call there, and eventually the component with the least review has the most authority.

This standard prevents that by construction: it defines what a collector *cannot* do, and the framework and validator enforce it.

## Scope

Applies to every plugin under `tools/collectors/plugins/` and to the framework in `tools/collectors/`.

## Definition

A collector is:

- **Read-only** — it observes and returns; it changes nothing
- **Source-specific** — one collector, one kind of source
- **Deterministic where possible** — the same input should yield the same output
- **Secret-safe** — it never receives, logs, or returns a secret value
- **Side-effect free** — running it twice changes nothing
- **Unable to mutate canonical entities**
- **Unable to remediate**
- **Unable to assign canonical evidence identifiers**
- **Responsible only for collecting and returning normalized observations**

A plugin that cannot write, cannot name, and cannot act has a worst failure mode of a *wrong observation* — which verification is designed to catch.

## Lifecycle

A collector has exactly five stages:

1. `discover` — determine what this collector could observe for a target
2. `validate_configuration` — confirm the context is usable; fail closed if not
3. `collect` — gather raw material from the source
4. `normalize` — convert raw material into normalized observations
5. `return_result` — hand back a `CollectorResult`

### Stages that deliberately do not exist

- `persist` — a collector that writes its own evidence can rewrite history. It returns data; the orchestrator decides what becomes a record.
- `remediate` — merging the least-trusted component with the highest-impact action means a misread becomes a production change.
- `mutate` — a collector that edits canonical entities destroys the reviewed intent it was meant to check.
- `approve` — approval is a human act; a collector granting it defeats the purpose.
- `deploy` — collection and change management are separate concerns and separate blast radii.

Adding any of these stages requires a new architecture decision, not a plugin update.

## Manifest

Every plugin ships a `manifest.yaml` declaring:

| Field | Meaning |
|---|---|
| `id` | Lowercase kebab-case identifier, unique across plugins |
| `name` | Human-readable name |
| `version` | Plugin version |
| `source_type` | An approved evidence source type |
| `description` | What it observes |
| `capabilities` | Capability ids it contributes to |
| `supported_targets` | Entity types it can observe |
| `permissions` | Requested permissions |
| `network_access` | Boolean |
| `subprocess_access` | Boolean |
| `filesystem_access` | Boolean |
| `secret_requirements` | What secrets it would need, described never valued |
| `output_contract` | Facts it produces |
| `lifecycle` | Plugin maturity |
| `provenance` | Provenance block |

`source_type` must be one of the ten approved types in the [Evidence Standard](evidence-standard.md).

## Permissions

### Approved in this increment

- `read-declared-model` — read entity records from `platform-model/`
- `read-repository-files` — read files from the repository working tree
- `synthetic-fixture-only` — operate solely on caller-supplied synthetic input

### Forbidden

- `write-platform-model`
- `write-evidence-store`
- `modify-runtime`
- `execute-remediation`
- `manage-secrets`
- `network-admin`
- `host-admin`

A manifest requesting a forbidden permission fails validation. These are not "not yet implemented" — they are outside the collector trust boundary, and granting any of them requires an architecture decision that revisits ADR-0002.

## Secrets

**Plugin code must not receive raw secret values.** Not redacted-on-output, not "handled carefully" — not received.

A plugin may declare in `secret_requirements` that a credential *would* be needed to reach a source. It never receives the value. Wiring real credentials to plugins requires a future ADR and a secret broker architecture that explicitly approves it.

Observations may record secret *metadata* such as `secret_present: true`. Fact names that look secret-bearing are rejected by the normalizer, which reports the key without echoing the value.

## Output Contract

A collector returns a `CollectorResult` containing:

- `collector_id`, `target`, `status`
- `observations` — normalized facts with `provenance: observed`
- `errors` — redacted `CollectorError` values
- `started_at`, `completed_at` — timezone-aware timestamps
- `content_fingerprint` — derived from normalized, redacted content

It does **not** contain an `EVID` identifier. Evidence identity is assigned outside the plugin, because a collector that numbers its own records controls the audit trail.

Approved status values: `success`, `partial`, `failed`, `unavailable`.

**A collection failure is not a service failure.** A collector that cannot reach a source reports `failed` or `unavailable`; it does not conclude anything about the health of the target.

## Failure Behaviour

- Invalid configuration **fails closed** — no partial collection proceeds on a bad context.
- Expected plugin failures become redacted `CollectorError` values, not exceptions escaping to the orchestrator.
- `BaseException` is never caught; a `KeyboardInterrupt` must remain interruptible.
- Naive timestamps are rejected. A time without a zone is not a point in time.

## Compliance

A plugin complies when:

- Its manifest carries every required field and parses as YAML.
- Its id is unique and lowercase kebab-case.
- Its `source_type` is approved.
- It requests only approved permissions and no forbidden ones.
- It declares no network, subprocess, or filesystem access in this increment.
- It implements `CollectorPlugin` and the five-stage lifecycle.
- It assigns no evidence identifier and writes no file.
- It contains no secret value and receives no raw secret.
- It is registered explicitly rather than discovered dynamically.
