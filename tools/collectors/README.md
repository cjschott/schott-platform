# Collector Framework

Read-only plugins that observe platform sources and return normalized data.

**No live collector exists in v0.5.0.** The only plugin is a synthetic fixture that observes nothing and refuses to run outside a test context. This increment defines the contract; collectors arrive from v0.6.0.

## Why the contract came first

A collector is where the outside world first touches the platform model. That makes it the component most likely to accumulate quiet privilege — a little filesystem access here, a subprocess call there — until the least-reviewed part of the system holds the most authority.

Defining the boundary before the first collector means a plugin cannot widen its own permissions, invent its own vocabulary, or acquire write access by accident.

## Architecture

```text
CollectionContext          supplied by the orchestrator, carries no secrets
    ->
CollectorPlugin.execute()  owns the lifecycle, fails closed
    ->
  validate_configuration   reject a bad context before collecting anything
  collect                  gather raw material
  normalize                convert to Observations, reject the unrepresentable
    ->
CollectorResult            data returned; nothing written
```

The orchestrator decides what becomes an evidence record. The plugin never does.

## Lifecycle

`discover` → `validate_configuration` → `collect` → `normalize` → `return_result`

Stages that deliberately do not exist: `persist`, `remediate`, `mutate`, `approve`, `deploy`. Adding one requires an architecture decision, not a plugin update. See the [Collector Plugin Standard](../../docs/standards/collector-plugin-standard.md) for why each is excluded.

## Adding a collector

1. Create `tools/collectors/plugins/<name>/` with `__init__.py`, `collector.py`, and `manifest.yaml`.
2. Subclass `CollectorPlugin` and implement `manifest`, `validate_configuration`, `collect`, and `normalize`. Do not override `execute` — the guarantees live there.
3. Declare an approved `source_type` from the [Evidence Standard](../../docs/standards/evidence-standard.md).
4. Request only approved permissions.
5. Register it explicitly in `KNOWN_PLUGINS` in `validate_plugins.py` and in whatever registry the orchestrator builds. **There is no auto-discovery**: a plugin that appears by being dropped on disk is a plugin nobody reviewed.
6. Run the validator and the framework tests.

## Permissions

**Approved:** `read-declared-model`, `read-repository-files`, `synthetic-fixture-only`.

**Forbidden:** `write-platform-model`, `write-evidence-store`, `modify-runtime`, `execute-remediation`, `manage-secrets`, `network-admin`, `host-admin`.

The forbidden set is outside the collector trust boundary, not merely unimplemented. Granting any of them requires revisiting [ADR-0002](../../docs/decisions/ADR-0002-evidence-first-architecture.md).

## Normalization

Normalization is separate from collection so a source-specific bug cannot smuggle an unrepresentable or secret-bearing value into the pipeline, and so the same rules apply to every collector regardless of source.

It rejects unsupported types rather than coercing them — `str()` on an arbitrary object produces a plausible-looking value with no meaning. It preserves an explicit `unknown` rather than dropping a fact, because a missing key and a key known to be unknown are different facts. Output ordering is sorted, so fingerprints are stable across runs.

## Result contract

`CollectorResult` carries `collector_id`, `target`, `status`, `observations`, `errors`, `started_at`, `completed_at`, and `content_fingerprint`.

It carries **no evidence identifier**. A collector that numbers its own records controls the audit trail, so identity is assigned outside the plugin.

Status values: `success`, `partial`, `failed`, `unavailable`. A `failed` or `unavailable` result describes the *collection*, never the target — **collection failure is not service failure**.

## Secret safety

Plugin code does not receive raw secret values. Not redacted-on-output, not handled carefully — not received. Wiring real credentials requires a future ADR and a secret broker.

The normalizer rejects secret-bearing fact names and reports the key with the value withheld. The fingerprint is computed over normalized values only, so it can never be a hash of a secret.

## Validation

```bash
python3 tools/collectors/validate_plugins.py --root .
bash tests/test-collector-framework.sh
```

## What does not exist

- **No runtime collection.** Nothing contacts a host, opens a socket, or spawns a process.
- **No evidence persistence.** Collectors return data; they write nothing.
- **No automatic remediation**, at any layer, under any configuration.

## Related

- [ADR-0002 Evidence-First Architecture](../../docs/decisions/ADR-0002-evidence-first-architecture.md)
- [ADR-0003 Provider-Agnostic AI Architecture](../../docs/decisions/ADR-0003-provider-agnostic-ai-architecture.md)
- [Collector Plugin Standard](../../docs/standards/collector-plugin-standard.md)
- [Evidence Standard](../../docs/standards/evidence-standard.md)
