# Platform Model

Machine-readable knowledge model for the Schott Platform.

## Purpose

This directory is the canonical, machine-readable record of what the platform is: its roles, hosts, services, and the relationships between them.

Documentation explains the platform to humans. This model is what tools consume. When the two disagree, that disagreement is a defect in one of them, not a matter of preference.

The model exists so that a human or an automated consumer can answer operational questions without guessing:

- What runs on this host, and what breaks if it reboots?
- What does this service depend on?
- Where are the logs, and how do I know it is healthy?
- Who owns it, and how is it recovered?

## Directory Structure

```text
platform-model/
├── ontology/
│   ├── entity-types.yaml         # Controlled entity vocabulary
│   ├── relationship-types.yaml   # Controlled relationship vocabulary
│   ├── validation-rules.yaml     # Rule ids, descriptions, severities
│   └── inference-rules.yaml      # Conservative derivation rules
├── roles/                        # Platform role definitions
├── hosts/                        # Host entities
├── services/                     # Service entities
├── networks/                     # Declared network policy
├── storage/                      # Logical storage entities
├── backup-policies/              # Protection scope and retention
├── relationships/                # Canonical declared edge lists
├── schemas/                      # Declarative record schemas
├── evidence/                     # Immutable observed-fact records
├── verifications/                # Read-only comparison results
├── drift-rules/                  # Declarative drift definitions
├── capabilities/                 # What the platform can intentionally provide
└── README.md
```

The ontology is the semantic source of truth. Tools must consume it rather than inventing private terminology.

## Declared, Observed, and Inferred Facts

Every fact in this model carries a provenance class. This is the most important rule in the directory.

| Class | Meaning | Requirement |
|---|---|---|
| `declared` | Written into the model deliberately; describes intended state | Carries `source` and `recorded_at` |
| `observed` | Collected from a live system at a moment in time | Must carry `observed_at` |
| `inferred` | Derived by an inference rule | Must carry `derived_from`; must use qualified language |

The vocabulary is exactly these three values and there are no aliases. The full contract is defined in the [Operational Metadata Standard](../docs/standards/operational-metadata-standard.md), and the [Platform Ontology Standard](../docs/standards/platform-ontology-standard.md) uses the same three names.

A fact that is not represented or not verifiable does not get a fourth class. Record its *value* as `unknown` inside a `declared` record — the absence is itself a deliberate declaration.

Everything currently in this model is `declared`. No runtime observation is recorded yet.

### Why runtime facts must not be silently presented as current

A declared fact says what the platform is supposed to be. It does not prove the environment matches.

An observed fact was true at `observed_at` and begins decaying immediately. Presenting a three-week-old observation as current fact is how an operator ends up rebooting a host they believed was idle.

So this model deliberately does not store volatile values:

- Kernel version, uptime, disk usage, free space
- Container ids, image ids, image digests
- IP lease state, process ids
- Current model inventory

Instead it stores the *command that retrieves them*. A retrieval command never goes stale; a copied value does.

If you must store a runtime value, store it as an `observed` fact with an `observed_at` timestamp, and expect consumers to qualify it by age.

When a declared fact and an observed fact disagree, that is drift. Report it. Do not silently pick the convenient one.

## Stable Identifiers

Identifiers are immutable and are never reused after retirement.

| Entity type | Prefix | Example |
|---|---|---|
| Platform role | `ROLE` | `ROLE-0001` |
| Host | `HOST` | `HOST-0001` |
| Service | `SVC` | `SVC-0002` |
| Network | `NET` | `NET-0001` |
| Storage | `STOR` | `STOR-0001` |
| Backup policy | `BKP` | `BKP-0001` |
| Evidence | `EVID` | `EVID-0001` |
| Verification | `VER` | `VER-0001` |
| Drift rule | `DRIFT` | `DRIFT-0001` |
| Capability | `CAP` | `CAP-0001` |
| Relationship | `REL` | `REL-0006` |

Relationship ids are allocated in blocks so independent edge lists never
collide: `REL-0001`–`REL-0999` for the AI platform set, `REL-1001` onward for
the infrastructure set.

Full prefix assignments live in `ontology/entity-types.yaml`.

Renaming a service does not change its id. Moving a service to a different host does not change its id. Replacing a service with a functionally different system creates a new id and marks the old one deprecated or retired.

Filenames are the bare slug: `litellm.yaml`. The slug is the join key between the filename and the record, so renumbering an id never forces a rename. Validation enforces that the filename matches the record's `slug` and that ids are four digits.

## How to Add an Entity

1. Choose the correct entity type from `ontology/entity-types.yaml`. If none fits, propose an ontology change rather than inventing a type.
2. Allocate the next unused id for that prefix. Never reuse a retired id.
3. Create the file in the matching directory, named `<slug>.yaml`, and set the matching `slug` field.
4. Add a `provenance` block with `class: declared`, a `source`, and `recorded_at`.
5. Fill the required fields for the entity kind:
   - **Services:** `id`, `type`, `name`, `lifecycle`, `owner`, `platform_role`, `deployment`, `observability`, `security`, `relationships`
   - **Hosts:** `id`, `type`, `hostname`, `lifecycle`, `platform_role`, `environment`, `criticality`, `observability`, `security`
6. Record retrieval commands instead of volatile values.
7. Run the validator.

Incomplete records are acceptable during discovery, but gaps must be explicit. Use an `unknown` value rather than a plausible placeholder. Placeholder text must never be treated as an approved operational fact.

## How to Add a Relationship

Relationships are declared **once**, in the canonical edge list under `relationships/`.

1. Confirm both entities already exist. Dangling references fail validation.
2. Choose a relationship type from `ontology/relationship-types.yaml`.
3. Append an entry to the appropriate file in `relationships/` with a new `REL-` id, `source`, `relationship`, `target`, and a `provenance` block.
4. Add `dependency_class` and `impact` when the edge is a dependency.
5. Reference the relevant standards or acceptance evidence.
6. In the entity files, add the new id under `relationships.declared`. Do **not** restate source, relationship, and target there.

Inverse edges are derived from the `inverse` field in `relationship-types.yaml`, not stored. Storing both directions invites contradictory duplicates.

Inferred edges are never written to these files. They are produced at query time by `ontology/inference-rules.yaml` and must be labeled `inferred` with `derived_from`.

## How to Validate the Model

```bash
bash tests/test-platform-model.sh
```

This validates structure, required files, prohibited content, and — when PyYAML is available — parses every document to check id uniqueness, four-digit id format, filename-to-slug agreement, reference resolution, required fields, vocabulary compliance, and the provenance contract.

To parse the YAML directly:

```bash
python3 - <<'PY'
from pathlib import Path
import yaml

for path in sorted(Path("platform-model").rglob("*.yaml")):
    with path.open(encoding="utf-8") as handle:
        yaml.safe_load(handle)
    print(f"OK: {path}")
PY
```

If PyYAML is unavailable the Bash contract still validates structure, but structural YAML checks are skipped and the script reports it.

## Recording What You Do Not Know

Much of this model describes systems that have never been contacted. That is expected, and it must not be disguised.

When a fact is not established by committed documentation, set `review_required: true` and add a `review_note` saying what is unconfirmed and what depends on confirming it:

```yaml
review_required: true
review_note: >-
  This host does not appear in any committed document. Its role and criticality
  tier are provisional and must be confirmed before automation, monitoring, or
  backup policy targets it.
```

The flag is not a placeholder to be cleaned up later by guessing. It is the honest answer, and it is enforced: validation requires Tier 0 and Tier 1 hosts to carry either backup coverage or `review_required`, so an unprotected critical host cannot pass silently.

Do not invent a backup schedule, retention window, or restore cadence. A fabricated schedule in a machine-readable model is worse than an explicit unknown, because automation and operators will both believe it.

## Lifecycle, Provenance, Verification, and Health

Four questions are routinely collapsed into one word. Keeping them apart is what stops the model from quietly lying:

| Concept | Question | Example values |
|---|---|---|
| `lifecycle` | How mature is this record? | `declared`, `verified`, `managed` |
| `provenance` | Where did this fact come from? | `declared`, `observed`, `inferred` |
| `verification_state` | Did evidence support the declaration? | `pending`, `verified`, `drift` |
| `operational_health` | Is it working right now? | **Not modeled** |

A `verified` lifecycle does not mean a service is up. It means evidence supported the declared facts *at a point in time*. Operational health is deliberately absent: answering it needs live telemetry the platform does not have, and an authoritative-looking field that is never refreshed is worse than no field.

`observed` is provenance and never a lifecycle state. See the [Entity Lifecycle Standard](../docs/standards/entity-lifecycle-standard.md).

## Evidence and Verification

`evidence/`, `verifications/`, and `drift-rules/` hold the evidence layer. Their schemas live in `schemas/` and are enforced by:

```bash
python3 tools/platform_model/validate_evidence.py --root platform-model
```

**No runtime collection exists.** The `evidence/` and `verifications/` directories ship with guidance and no records, because inventing an evidence record would defeat the purpose of an evidence layer.

**No automatic remediation exists.** `remediation_mode` accepts only `advisory` or `manual-approval-required`; `automatic` is rejected by the validator. Detection and correction stay permanently separate.

## Capabilities

`capabilities/` records what the platform can intentionally provide, with a maturity value that is a claim about **implementation**, not intent. Only `CAP-0001` Platform Modeling is `operational`; the evidence, verification, and drift capabilities are `foundation` because nothing real has yet flowed through them.

Collectors are defined in `tools/collectors/` and governed by [ADR-0002](../docs/decisions/ADR-0002-evidence-first-architecture.md). v0.6.0 adds three local read-only collectors — git repository, Compose configuration render, and manual attestation — documented under [`docs/collectors/`](../docs/collectors/).

They return `CollectorResult` objects. **No evidence record is persisted**: the orchestrator that would turn an observation into an `EVID` record does not exist yet, so `evidence/` remains empty by design.

## Ontology Conformance

Every edge is validated against the `allowed_sources` and `allowed_targets` its relationship type declares. Without that check the controlled vocabulary would be decorative — any entity kind could be joined to any other and the graph would still "pass".

If a legitimate edge is rejected, the fix is an explicit, commented ontology change, not a looser test. Widening a relationship's allowed types is a semantic decision and should be reviewed as one.

## Security Rules

The model must never contain:

- Passwords, private keys, API tokens, or bearer tokens
- Session secrets or credentials embedded in URLs
- Real environment variable values
- Model blobs, digests, or binary artifacts
- Unredacted prompts or model payloads

The model may record that a secret exists and name its `secret_source` path. It must never record the value. Referencing `ai/.env` by path is correct; committing that file or any value from it is prohibited.

Validation checks for secret-shaped content, but the check is a backstop, not permission to be careless.

## Scope

Current entities:

| ID | Type | Name |
|---|---|---|
| `ROLE-0001` | platform-role | AI Platform |
| `HOST-0001` | host | schai |
| `SVC-0002` | service | LiteLLM |
| `SVC-0003` | service | Ollama |
| `ROLE-0002`–`ROLE-0009` | platform-role | Management, Compute, Backup, Storage, Web, Media, Monitoring, Development |
| `HOST-0002`–`HOST-0011` | host | schmgmt, schoxmox1, schoxmox2, schpbs, schdownload, schweb1, schweb2, schplex, schraspi, schotectli |
| `NET-0001`–`NET-0004` | network | Homelab LAN, Management Address Pool, DHCP Client Pool, AI Backend |
| `STOR-0001`–`STOR-0004` | storage | Ollama model volume, PBS local datastore, off-site datastore, NAS media |
| `BKP-0001`–`BKP-0005` | backup-policy | Tier 0, Tier 1, AI configuration, Proxmox guests, off-site replication |

LiteLLM is the only application-facing AI endpoint, reachable at `http://schai:4000/v1`. Ollama is an internal backend with no host-published port and must never be documented as an application endpoint.

**Kyri is a future consumer of this model, not a deployed entity.** It has no service record here and must not be given one until it is actually deployed. The model is being built so that Kyri has something accurate to reason over — modelling it as deployed before it exists would be exactly the kind of unverified assertion this directory is designed to prevent.

Backup policies, dashboards, alerts, and runbook entities are referenced by path where relevant but do not yet exist as entities.

## Governing Standards

- [Platform Ontology Standard](../docs/standards/platform-ontology-standard.md)
- [Operational Metadata Standard](../docs/standards/operational-metadata-standard.md)
- [Service Catalog Standard](../docs/standards/service-catalog-standard.md)
- [Platform Role and Host Classification Standard](../docs/standards/platform-role-host-classification-standard.md)
- [Dependency Mapping Standard](../docs/standards/dependency-mapping-standard.md)
- [Service Exposure Standard](../docs/standards/service-exposure-standard.md)
