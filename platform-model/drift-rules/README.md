# Drift Rules

Declarative definitions of comparisons between declared intent and observed fact.

**These are definitions, not results.** Nothing here has been executed against any entity.

## Purpose

A drift rule says: *for entities of these types, compare this declared path against this observed fact using this comparator, and if they differ, report this severity.*

It contains no logic for fixing anything, and cannot be extended to.

## File Naming

```text
<domain>.yaml
```

One file per rule domain, holding a `drift_rules` list. `core-platform.yaml` holds the initial set.

## Stable IDs

`DRIFT-0001`, four digits, never reused.

## Comparators

`equals`, `not_equals`, `contains`, `not_contains`, `exists`, `absent`, `subset`, `superset`, `numeric_range`.

## Remediation Mode

Only two values are accepted:

- `advisory` — report only
- `manual-approval-required` — report, and require human approval before any human-performed action

`automatic` is **not an accepted value**. The schema omits it from the enum and lists it explicitly as forbidden, and the validator rejects it.

This is deliberate and permanent. A system that both detects and corrects difference will eventually correct the wrong side — enforcing a stale declaration onto an environment that changed for a good reason.

## Evidence Age

`evidence_max_age` is `null` on every current rule, paired with `review_required: true`.

That is not an oversight. No committed document establishes an operational frequency for these checks, and an invented number would look authoritative while being unfounded. The null keeps the gap visible until a real cadence is agreed.

When a cadence is committed, use a duration such as `24h` or `7d`.

## Validation

```bash
python3 tools/platform_model/validate_evidence.py --root platform-model
```

## Example

```yaml
drift_rules:
  - id: DRIFT-0001
    name: Host primary platform role matches declared role
    description: The role a host fulfils should match its declared platform_role.
    target_entity_types: [host]
    declared_path: platform_role
    observed_fact: platform_role
    comparator: equals
    evidence_max_age: null
    review_required: true
    severity: medium
    missing_evidence_result: missing_observation
    mismatch_result: mismatch
    enabled: true
    remediation_mode: advisory
```

## What Does Not Exist Yet

- No rule evaluation engine.
- No runtime collection.
- No automatic remediation, at any severity.
