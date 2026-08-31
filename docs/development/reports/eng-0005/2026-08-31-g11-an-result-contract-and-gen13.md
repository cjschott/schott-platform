# ENG-0005 G11-AN — the terminal result contract, and two things the architecture does not carry

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `62ce15d0e882f40f81b7a7ed76a39e1cf8b57a0c`
**Implementation commit:** `e5ec23d`

Both G11-AM defects are fixed and proven end to end. An execution's outcome now
reaches the caller *and* the store, and the eight outcomes that were
indistinguishable are distinguishable.

Two things stopped, both because the accepted architecture does not carry what
they need — not because a decision was hard.

**No result-artifact store exists.** §15 requires
`result_artifact_reference` *"where the result is stored out of line"*, §13
defines an append-only record plane and nothing else, and the artifacts root
holds approved packages, which are inputs. The field is written `null` and the
digest is real. §7 states the smallest missing contract.

**A prepared invocation cannot be told from an attempted one.** §17 says
validation reports an invocation with no result as interrupted. Both a
never-authorised preparation and a crashed execution write
`execution-prepared` and nothing else. §14 names an `adapter_identity` field on
the invocation record that would separate them; the implementation has never
carried it. §8 explains why guessing was the wrong move.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **88/88**, full **113/113**.

---

## 1. The two defects, and what they had in common

Both were the runtime knowing something and discarding it.

`AdapterOutcome` carries `outcome_class` **and** `succeeded`.
`prepare_invocation` copied the first and dropped the second, so a capability
that wrote a valid governed result and one that ran `pass` both returned
`completed`. And a result record was allocated only on refusal, so every
executed outcome left the store saying `execution-prepared` — the same words it
used before the container existed.

Neither was visible until G11-AL made execution reachable.

## 2. The accepted architecture

Read as normative, and it already answers most of this.

**§14** — the invocation record is written **before** the adapter, so a crash
mid-flight is still attributable. Its conceptual fields include
`adapter_identity`, which the implementation does not carry (§8).

**§15** — the result record carries `result_record_id`,
`invocation_record_id`, `attempt_number`, `outcome_class`, `reason`,
`result_digest`, `result_artifact_reference` *where the result is stored out of
line*, `started_at`, `ended_at`, `evidence`. And it **MUST NOT** persist
bodies: *"Results are recorded by digest and reference; a reason names the
failure without echoing content."*

**§17** — an invocation with no result is **interrupted**: observable residue,
never cleaned, never repaired. The runtime **MUST NOT** claim exactly-once
external execution.

## 3. Succeeded reaches the caller

`InvocationDecision` gains `succeeded`, `result_digest` and
`result_artifact_reference`.

`succeeded` is `None` where no adapter ran — a preparation that never reached
execution did not *fail*, and `False` would be a claim about a run that never
happened. `True`/`False` only where an execution outcome exists.

`require_execution_success` fails closed on anything that is not exactly a
boolean. `'true'`, `1`, `0`, `''` are all refused: a missing verdict is not
evidence a result was admitted, and defaulting it either way answers a question
nobody asked — which is how `completed` came to read as success.

## 4. The result schema

| | Before | After |
| --- | --- | --- |
| fields | 9 | **13** |
| schema version | shared `RECORD_SCHEMA_VERSION = 1` | `INVOCATION_SCHEMA_VERSION = 1`, `RESULT_SCHEMA_VERSION = 2` |

Added: `result_digest`, `result_artifact_reference`, `started_at`, `ended_at`.
`recorded_at` stays — when the record was written is not when the work ran, and
collapsing them would have made the record describe itself.

**The versions split rather than bumping the shared constant.** The invocation
record did not change, so its version does not move; bumping one constant would
have reinterpreted every historical invocation record as belonging to a schema
it was not written against. `inspection` now validates each kind against its
own version, because one shared check made a correct record of either kind look
malformed the moment the other moved.

**Legacy handling (§5 of the brief): option B.** No production capability
records exist — `/var/lib/kyri/capability` is absent — so v2 is the only
released executable result schema and no read compatibility was written. The
only v1 result bodies were fixtures, migrated in place. Recorded as a choice
with its evidence rather than left implicit.

## 5. The terminal writer

`record_terminal_result` — one narrow function that **records conclusions and
reaches none**. The outcome class was T13's, the admission verdict T14's, the
digest the collector's. It reruns no adapter, re-reads no exit code,
reinterprets no output and revisits no eligibility; a test asserts it invokes
nothing adapter-shaped.

**It never touches the invocation record.** CINV is the immutable
pre-execution attempt evidence, and recording completion by editing it would
destroy exactly the property §14 gives it. `CINV_MUTATED_AFTER_EXECUTION = NO`,
asserted structurally.

**Undescribable pairs are refused rather than written.** A success with no
digest, or a failure carrying one, is not an outcome anybody reached; a record
of it would be worse than none.

**Serialised, and entered only afterwards.** The store's own invocation
critical section — not the Fabric's — is entered *after* the adapter returns.
Holding it across execution would block every other identity operation for a
capability's full timeout. A second terminal publication for the same
invocation refuses: this adapter performs one attempt, and `attempt_number`
stays 1.

## 6. Result digest

`sha256:<64hex>`, read from the collector's manifest entry for the governed
`result.json` — the digest computed **during admission**, not recomputed here.
Re-hashing whatever is on disk now would answer a different question than what
was admitted. Nothing is derived from untrusted output: `outcome.result` exists
only where every T14 condition held, so an absent result yields an absent
digest.

## 7. Result artifact reference — the first stop

`result_artifact_reference` is written `null`, and that is a gap rather than a
design.

Established mechanically: §13 defines the execution store as an append-only
record plane and defines no artifact plane; `approved_artifact_root` is
consumed only by `resolve_and_stage_package`, so the artifacts authority holds
**inputs**; nothing else in the accepted architecture stores result bytes.

§15 makes the reference conditional — *"where the result is stored out of
line"* — so writing it null with a real digest is compliant and invents
nothing. But it means **the result's bytes are not durably retained**: they
remain in the invocation's output leaf as residue, and the CRES proves what the
result *was* without preserving it.

**The smallest missing contract**, stated so a ruling can be short:

- a content-addressed store under the execution store root, `0o700`/`0o600`
  like the rest;
- one object per admitted result, named by its own digest, so the reference is
  content-bound by construction and `result_artifact_reference` is derivable
  from `result_digest` rather than being a second fact;
- written by whoever holds the collected bytes — the worker holds the output
  descriptor, which argues for the worker;
- immutable and never cleaned, matching §13's residue doctrine.

I did not build it. It is a storage authority, and inventing an ad hoc path in
the CRES is exactly what the brief forbids.

## 8. Interrupted semantics — the second stop

§17's rule is unambiguous: an invocation with no result is interrupted.
Implementing it is not, and the reason is a missing field rather than a hard
call.

| Case | CINV `evidence.outcome` | CRES |
| --- | --- | --- |
| prepared, no adapter was ever authorised | `execution-prepared` | none |
| execution attempted, process died before the result | `execution-prepared` | none |

**The record cannot tell them apart.** Reporting every prepared invocation as
interrupted would relabel records that were never attempted, which §12 of the
brief forbids; inferring from a clock is what the doctrine forbids.

§14 names the field that would separate them — `adapter_identity` on the
invocation record. A prepared invocation carrying one was going to execute; one
without was not. The implementation has never carried it, and adding it changes
the invocation schema, which this checkpoint deliberately left at version 1.

So validation still does **not** report a prepared invocation with no result.
What it does now report correctly:

- prepared **with** a terminal result → sound, the ordinary successful shape;
- prepared with a **refusal** result → mismatch, two records disagreeing about
  whether anything was attempted;
- prepared with **more than one** result → mismatch;
- refused with no result → `refusal-without-result`, unchanged.

The first of those was previously reported as a mismatch, which was right only
while nothing could execute.

`INTERRUPTED_INVOCATION = NOT_RUN`, and the one-line fix is
`adapter_identity` on CINV at schema version 2.

## 9. What the outcomes now look like

Every row drives from the real front half against the real image.

| Case | `reason` | CRES `outcome_class` | `succeeded` | digest |
| --- | --- | --- | --- | --- |
| **success** | `completed` | `completed` | **True** | `sha256:…` |
| output absent | **`result-missing`** | `completed` | False | none |
| workload exit 42 | `provider-error` | `provider-error` | False | none |
| wrong image | `adapter-error` | `adapter-error` | False | none |
| extra mount | `adapter-error` | `adapter-error` | False | none |
| socket mount | `adapter-error` | `adapter-error` | False | none |
| wrong identity mapping | `adapter-error` | `adapter-error` | False | none |
| governed timeout | `timeout` | `timeout` | False | none |

The second row is the one that mattered: G11-AM reported it as `completed`,
indistinguishable from the first. It now names the governed reason and says it
did not succeed. `result-missing` is the single added word; every other reason
is an outcome class the runtime already had.

CINV stays `execution-prepared` in all of them, and no container survives any.

## 10. Not built

- **CLI execution binding** (§19–20 of the brief). `invoke` still cannot
  execute. Wiring it internally is bounded work and was not reached.
- **Preflight backend readiness** (§21–22).
- **Generation-13 installer, fixture ceremony, recovery matrix** (§27–28).
- Result-store validation beyond §8's list, and the consistency matrix.

None is blocked by the stops; all are bounded.

## 11. Generation 13

Recomputed mechanically. Closure unchanged at **68 objects** — the backend is
still naturally reachable through the released worker — but the delta grew.

| | G11-AM | now |
| --- | --- | --- |
| REPLACE | 8 | **10** |
| CREATE | 2 | 2 |
| total | 10 | **12** |

The two additions are `inspection.py` and `records.py`, joining
`coordinator.py` and `evidence.py`, which were already in the delta.

**Coherence group A** stands — `/usr/libexec/kyri-exec-worker.py` with
`/usr/lib/kyri/python/kyri_exec_podman.py`.

**A second group now exists, and it is critical.** `coordinator.py`,
`evidence.py`, `records.py` and `inspection.py` decide whether an execution's
outcome is recorded and how it is read. A generation exposing the new
coordinator against the old evidence module would execute capabilities and
write nothing; the old inspection against new records would call every result
malformed. §28 of the brief names this exactly: *"a Generation-13 transaction
must never expose a version where execution occurs but results cannot be
durably recorded."* The whole generation installs atomically, which satisfies
it — but the group is now named so a future partial install is recognised as
the hazard it is.

`GEN13_ENTRY_CLOSURE = PASS`. `GEN13_PREINSTALL = NOT_READY` — no installer,
and the object set may still move if §7 or §8 is ruled.

## 12. Helper, coordinator and sudoers

Unchanged and untouched. The installed helper is still `cfb0edd`-era on both
transition modules. Source coherence stays pinned. The coordinator authority
candidate revalidates byte-identical at `3dec888c…2811`, and the sudoers grant
pins an entrypoint the helper ceremony does not change.

`INSTALLED_HELPER_STILL_STALE = YES`.

## 13. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 88/88 |
| `run-validation.sh` (full) | **PASS**, 113/113 |
| terminal result contract (new) | **PASS**, 12 cases |
| invoke execution E2E | **PASS**, now asserting the fixed behaviour |
| capability runtime, inspection, preflight | **PASS** |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

**Three existing assertions moved, each sharpened.** Two counted string
occurrences in `evidence.py` and now assert per-writer structure: two durable
writes, neither nesting, and neither invoking an adapter inside the invocation
lock. The third reported prepared-with-a-result as a mismatch; it now fires on
outcome-class disagreement, so a refusal result under a prepared invocation is
still caught.

The recurring text-scan lesson appeared twice more and cost two cycles: both
functions name the adapter in prose to say they never call it, and one names it
in a refusal message. The assertion is now on `ast.Call` nodes.

## 14. Production non-mutation

No production capability records exist and none were created;
`/var/lib/kyri/capability` remains absent. Fixture Fabric, Trust and artifact
stores were read to shape fixtures and never written. No production Podman
storage opened. All containers ran in a disposable store and were removed.

Not installed: worker entrypoint, backend, helper, sudoers, coordinator
authority, Generation 13. CIMP-000001 unchanged and immutable.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 15. Next operator gate

None. Two rulings, both small and both stated above:

1. **§7** — the result-artifact storage contract, or an explicit ruling that a
   digest without retained bytes is sufficient for the first adapter.
2. **§8** — `adapter_identity` on the invocation record at schema version 2,
   which makes §17's interrupted rule implementable.

With those settled the remaining work is bounded and in order: the CLI binding,
preflight readiness, and the Generation-13 installer — whose object set both
rulings may still move.
