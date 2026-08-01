# Capabilities

What the platform can **intentionally provide**, recorded with an honest assessment of how far each ability has actually been built.

## Purpose

Capability claims are the easiest thing in a platform to overstate. A directory of schemas can look like a working evidence pipeline; a validator that has never seen real input can look like verification.

Recording the ability and its maturity as separate fields forces the gap to be visible instead of implied.

## Maturity is not intent

| Maturity | Meaning |
|---|---|
| `planned` | Decided, not built |
| `foundation` | Contracts and scaffolding exist; nothing real has flowed through |
| `partial` | Works for some cases, with known gaps |
| `operational` | Works for its intended scope and is relied upon |
| `optimized` | Operational and deliberately tuned |
| `retired` | No longer provided |

The line between `foundation` and `partial` is whether anything real has flowed through. Schemas and passing tests alone are `foundation`.

## Current capabilities

| ID | Name | Maturity | Risk |
|---|---|---|---|
| `CAP-0001` | Platform Modeling | operational | medium |
| `CAP-0002` | Evidence Collection | foundation | high |
| `CAP-0003` | Verification | foundation | high |
| `CAP-0004` | Drift Detection | foundation | high |
| `CAP-0005` | Knowledge Reasoning | planned | high |
| `CAP-0006` | LLM Routing | partial | medium |
| `CAP-0007` | Automation Planning | planned | critical |
| `CAP-0008` | Human Approval Workflow | planned | critical |

Only `CAP-0001` is operational. Every record carries a `maturity_rationale` explaining the value, and unconfirmed claims set `review_required: true`.

## Risk is about being wrong

Risk describes the consequence of a capability **misbehaving or being wrongly trusted**, not how hard it was to build. A capability that produces confident-looking output from unverified input is high risk regardless of maturity — which is why the evidence and verification capabilities are `high` while still only `foundation`.

`CAP-0007` and `CAP-0008` are `critical` and `planned` simultaneously: they are unbuilt, and the consequence of getting them wrong later is production change without review.

## File naming and IDs

Bare-slug filenames, `CAP-0001` four-digit identifiers, never reused.

## Honesty rules

- Do not claim operational maturity for unimplemented capabilities.
- `implemented_by` and `validated_by` must reference things that exist; the schema rejects operational maturity without both.
- A capability is no more trustworthy than the capabilities it requires.

## Validation

```bash
bash tests/test-platform-model.sh
python3 tools/collectors/validate_plugins.py --root .
```

## Related

- [Capability Model Standard](../../docs/standards/capability-model-standard.md)
- [ADR-0002 Evidence-First Architecture](../../docs/decisions/ADR-0002-evidence-first-architecture.md)
- [ADR-0003 Provider-Agnostic AI Architecture](../../docs/decisions/ADR-0003-provider-agnostic-ai-architecture.md)
