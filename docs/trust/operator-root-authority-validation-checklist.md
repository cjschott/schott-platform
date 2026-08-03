# Operator Root Authority Validation Checklist

Two phases: what to check **before** instantiation, and what must be true
**after** cutover. Nothing here has been run.

See the [deployment guide](operator-root-authority-deployment.md).

## Phase 1 — dry run

**Every check below is non-mutating.** It reads state and writes nothing: no
store is created, no identifier is allocated, and no audit event is emitted.
If any check fails, stop — instantiation is not attempted.

| # | Check | Expected |
|---|---|---|
| 1 | **repository clean** — `git status --short` | empty |
| 2 | **released main** checked out at the current tag | matches |
| 3 | Trust Plane CLI available — `python3 -m tools.trust.cli --help` | exit 0 |
| 4 | Target store root is **outside the repository** | true |
| 5 | Input file sits **inside the approved input directory** | true |
| 6 | **containment** holds after full path resolution (no symlink escape) | true |
| 7 | Every reference in the input file resolves | true |
| 8 | Evidence records parse | true |
| 9 | No secret-shaped values anywhere in the input | true |
| 10 | Timestamps are **timezone-aware** | true |
| 11 | A root authority does **not already exist** in the target store | true |
| 12 | No runtime store is configured in production yet | true |
| 13 | **code-owned policy** remains the current fallback | true |

Read-only commands only:

```bash
python3 -m tools.trust.cli --help
python3 -m tools.trust.cli validate-store --help
python3 -m tools.trust.cli validate-store --store-root <STORE_ROOT>
```

`init-root` is **not** run during the dry run.

## Phase 2 — cutover acceptance

The single most important observation: the gateway's verdict source changes
from **`code-owned-policy`** to **`trust-plane-runtime`**.

| # | Acceptance | Expected |
|---|---|---|
| 1 | Verdict source moves to `trust-plane-runtime` | confirmed |
| 2 | **no migrated request uses the code-owned fallback** | confirmed |
| 3 | A **configured but unseeded** store denies | denies |
| 4 | A seeded store permits **only explicitly trusted subjects** | confirmed |
| 5 | **unknown subjects deny** | denies |
| 6 | Restricted scope denies out-of-scope operations | denies |
| 7 | **quarantined** subjects deny normal use | denies |
| 8 | **revoked** subjects deny | denies |
| 9 | **expired** subjects deny | denies |
| 10 | **no silent fallback** after a runtime denial | confirmed |
| 11 | Refusal wording remains explainable | confirmed |
| 12 | Every verdict **names its source** | confirmed |
| 13 | Every verdict names the governing trust record | confirmed |
| 14 | **no duplicate authority** is consulted | confirmed |

Checks 2 and 10 are the ones worth dwelling on. A migration that reaches the
runtime and then quietly drops back to code-owned policy on any denial has
reintroduced exactly the second authority this platform spent a release
removing — and it would look like success from every other angle.

## Evidence to retain

Exit codes, the created authority identifier, its fingerprint, the audit event
identifier, store validation output, file permissions, repository before/after
state, and confirmation that no secret appeared in stdout, stderr, the store, or
any fingerprint.

## Related

- [Deployment guide](operator-root-authority-deployment.md)
- [Trust migration](trust-migration.md)
