# G11-BC-Y — incident state frozen, provenance correction designed, Generation 20 prepared

**Date:** 2026-09-20
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `e5471e85f5fce312256ee377465d2e0220457800` (the G11-BC-X incident report)
**Engineer:** Claude (implementation)
**Status:** OPERATOR ACTION REQUIRED — Generation 20 is prepared and rehearsed, not installed. Nothing in production was mutated.

---

## A. The incident state, frozen

Measured read-only with the installed runtime. Nothing was written.

| | |
|---|---|
| Post-incident runtime aggregate | `9374b56870759ebccbbb74a38ada5905bcd5ce3bd1418428b72e148cdc662d68` |
| `CINV-000001` | `launch_authorized` |
| `CINV-000002` | `abandoned` |
| `CINV-000003` | no execution state |
| Occupancy | **1 of 2** |
| `capability-invocation.seq` / `capability-result.seq` | 3 / 1 |
| `cadm-counter` / `cmut-counter` | `000001` / `000000000007` |
| Transitions | 5 (`CINV-000001` ×2, `CINV-000002` ×3) |
| Administrative records | 1 (`CADM-000001`) |

`CADM-000001`, by member digest:

| Member | SHA-256 |
|---|---|
| `abandonment` | `d1307f014d8eae2cccf83bfc8c3d673a93a00a86c797e07af44b9053b0dedced` |
| `intent` | `a7faa2c165f7c0fd4b3b91204ecd213b4ad4ffdb1029e0c438b3eb25d6e92944` |
| `outcome` | `07bb889d884bc76b0cae423a65f6e2fdff9a6d7d8de4584df029fc6a3bbeeeb3` |

Its content: actor `primary-platform-operator`, previous_state `launch_authorized`,
state `abandoned`, reason `terminal-result-lifecycle-stranded`, result_record_id
`CRES-000001`, slot_released true, request_id `g11bcx-reclaim-cinv-000002`,
recorded_at `2026-09-20T18:54:33-05:00`.

`transitions/CINV-000002.000003` — `cd20bcd014c90370f3d3a599d84ebd2072b949360ca6f3e963bff3c99e22d156`:
`{"cinv":"CINV-000002","previous":"launch_authorized","schema_version":1,"sequence":3,"state":"abandoned"}`

`CMUT-000000000007` — intent `5716fb97…` (target `execution-transition`
`CINV-000002.000003`, expected `cd20bcd0…`), outcome `a569f203…` (`installed: true`).

Immutable records, all unchanged from before the incident: `CINV-000001`
`1dcef40d…`, `CINV-000002` `923ff0d7…`, `CINV-000003` `c0941b7d…`,
`CRES-000001` `18ba4c34…`. Launch-authorisation evidence preserved
(`CINV-000001` `fdce93ae…`, `CINV-000002` `14e94c0e…`); published handoff
`4ee55b59…`; staging `535b5f65…`.

Other governed roots unchanged: Fabric `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5`,
Platform Evidence `62c875851b83ca0d53c8b82469709be530cc6dad2957bb766fdb65fc2b5dc507`,
Artifacts `ef4297c611a2dd824f1c1e4960e64304f72b04d77c0f5f20dd650b0b3eb410df`.
Root Authority: 0 mounts. Trust: not readable as `cschott` and not touched.

Generation 19 is installed coherently: all seven objects at their reviewed
digests, 82 `.py` objects.

**INCIDENT_STATE_VERIFIED = PASS.**

The operator's container observation is accepted as stated in the prompt: no
`kyri-CINV-000002` container exists and none is running. That closes the safety
question the bypassed BLOCK A left open. It does not authorise the abandonment
retroactively, and nothing below treats it as if it did.

## B/C. The correction model

**Existing mechanisms were checked first.** The Trust plane has decision
supersession (`tools/trust/lineage.py::validate_supersession`) and the Fabric has
record supersession (`CROUTE-0006 supersedes CROUTE-0005`). Neither fits: both
replace a record with a newer one that takes over its role, and a provenance
correction must do the opposite — leave the original standing and in force, and
dispute one claim inside it. The capability runtime has exactly two record kinds
(`CINV`, `CRES`) and no annotation or amendment concept anywhere.

**So: one closed-set administrative verb, `correct-provenance`.** ADR-0016 has
the full argument. It reuses the `CADM` machinery — same counter, same
create-once `intent` → attempt → `outcome` ordering, same namespace — and adds
one member, `provenance-correction`. No new record kind, no new counter, no new
mutation-journal target.

It asserts exactly: *this administrative action occurred and its lifecycle
effect is retained; the claim named in `disputed_field`, as recorded in
`subject_cadm`, is not truthful provenance.* It is not ratification, it names no
substitute actor, and `action_reversed: false` / `effect: retained` are written
out rather than implied.

The invariants, each enforced in code and proven in
`tests/test-capability-execution-provenance-correction.sh` (22 assertions):

1. The subject is never opened for writing; its SHA-256 is recorded so later
   tampering shows.
2. `CORRECTABLE_FIELDS` is `{actor}`. `state`, `previous_state`, `reason`,
   `slot_released` and `result_record_id` are unreachable — a dispute about what
   happened is not a dispute about who is recorded as having done it.
3. The disputed value must match what the store holds.
4. Exactly one member may carry the claim; ambiguity refuses rather than choosing.
5. The subject's recorded state must still be the lifecycle's state.
6. It takes the `CINV` lock and **not** the capacity lock. The lock it does not
   take is part of the evidence.
7. No transition, no result, no slot movement — the module imports neither
   `capacity` nor `transition_locked`, and a static backstop asserts that.
8. Create-once per (subject, field); an identical repeat resumes, anything
   differing refuses.

Measured on a fixture: a correction writes one `CADM`, advances `cadm-counter`,
and leaves the subject, the lifecycle, the occupancy, the transition journal and
`cmut-counter` byte-identical. Removing the new `CADM` and the counter increment
reproduces the pre-correction store exactly.

## D. Generation 20 — the mutation target is explicit

`command_abandon` resolved `CAPABILITY_RUNTIME_ROOT`, a module constant, and the
CLI accepted no runtime-root argument. The constant had been given to it by
analogy with `authorise-launch`, and **the analogy was false**: those verbs
compile their roots in because the privileged transition on the far side
compiles in the same ones, so the ceremony and its consumer agree by
construction. Nothing downstream of `abandon` does that. The argument did not
apply; the hazard did.

Now:

- `abandon` and `correct-provenance` both require `--store-root`. No default.
- `_explicit_root` refuses a missing, relative or non-normalised root **before
  any store is opened**.
- Omission is argparse exit 2 naming `--store-root`.
- The help text says production is `/data/kyri/capability-runtime` and that a
  rehearsal must name its own fixture.
- Invalid roots fail through the existing `CapabilityStore` and backing-store
  verification, unchanged.

**This is a breaking change on purpose.** A script that called `abandon` without
a target now fails loudly instead of mutating production.

## E. Audit of every mutating CLI surface

Enforced as a test, not only written down —
`tests/test-capability-mutation-target-explicit.sh` introspects `build_parser()`
and each handler's source, and fails if any verb resolves the constant without
being on the allowlist.

| Verb | Root | Class | Rehearsable against a fixture |
|---|---|---|---|
| `invoke` | `--store-root` | 1 safe explicit | yes |
| `inspect` | `--store-root` | read-only | yes |
| `validate` | `--store-root` | read-only | yes |
| `abandon` | `--store-root` **(new)** | 1 safe explicit | yes |
| `correct-provenance` | `--store-root` | 1 safe explicit | yes |
| `authorise-launch` | compiled-in | 2 intentionally fixed — the privileged transition compiles in the same roots | no; rehearse at the API |
| `execute` | compiled-in | 2 intentionally fixed — same reason | no; rehearse at the API |
| `recover` | compiled-in | 2 intentionally fixed — writes nothing to the store | no; rehearse at the API |

**Class 3 (same hazard as `abandon`): none remain.** The compiled-in root is
resolved exactly three times in `cli.py`, and the test pins that number, so a
fourth cannot appear unnoticed.

The three class-2 verbs keep their fixed roots deliberately. They are documented
here and are **not to be driven from a harness**: a rehearsal of those paths
belongs at the operation API, where the roots are arguments.

## F. The mutator's own answer about where it wrote

`backing_store.target_fingerprint(root)` returns the device and inode the kernel
reports for the descriptor the mutation is written through. `RootDescriptor`
still carries no `path` — a fingerprint that handed back a name would hand back a
way to reopen by name.

Both `abandonment.abandon` and `provenance.correct_provenance` compute it and
return it; both CLI verbs emit it as `target` alongside the `store_root` as
typed.

Proven against the real host:

- a fixture-targeted `abandon` reports the fixture's execution-root inode, and
  production is byte-identical;
- that inode differs from production's, so the two are distinguishable;
- a production-targeted call would report production's inode — computed
  read-only, so a ceremony can pin it;
- omission refuses; a relative, non-normalised or nonexistent root refuses
  cleanly with no traceback.

**No test in this checkpoint claims production safety because a path is absent
from a rendered script.** That assertion was true on 2026-09-20 and useless.

## G. What `actor` is

The incident proves `actor` is a **caller-asserted string, not authenticated
provenance**. Nothing binds it to an operator, a session, a key or a privilege.

This is documented in ADR-0016 (§"What actor means") and asserted in tests: an
actor nobody has ever heard of is accepted and recorded verbatim, exactly as an
operator's would be, and the record claims no authentication for it.

**No narrow improvement was implemented, and that is a decision rather than an
omission.** The obvious candidate — an `actor_provenance: "asserted"` marker in
the abandonment detail — would bump the schema of `CADM-000001`'s own record type
in the same generation that must record a correction about it, making the subject
harder to compare against its peers for no gain in truth. A real binding belongs
to the Trust plane's decision lineage or the privileged helper's authority, and
is a separate reviewed increment.

**ACTOR_PROVENANCE_FINDING: asserted, not authenticated; documented, tested, not
fixed.**

## H. Red first

`tests/test-capability-mutation-target-explicit.sh` reproduces the incident class
against the **installed Generation-19 runtime**, with its store constructor and
root anchor replaced by recorders that raise, so nothing is opened, locked or
written:

- every caller-controlled value says fixture; the installed `abandon` asks for
  `/data/kyri/capability-runtime`;
- the installed abandon surface has no root argument at all, so it cannot be
  aimed;
- production is byte-identical afterwards.

Then green, against the checkout: omission refuses, the fixture target mutates
the fixture only, the reported target is the fixture's inode, and no hidden
default exists.

## I. Generation 20, prepared

`provisioning/execution/install-generation-20.sh` (mode 0644), pinned to
`6ba8e5c951f8c98bb1e0e9cc0997d497f7445202`, baseline
`5ab509125963c2b8862815aba6f6ee6b878d0d92`. Five objects, one coherence group
(P), one CREATE, library 81 → 82 (plus the published helper module).

Publication order, derived from the import graph and **measured**:

| published so far | `tools.capability.cli` | `correct-provenance` |
|---|---|---|
| (Generation 19) | imports | no |
| + `backing_store.py` | imports | no |
| + `admin.py` | imports | no |
| + `abandonment.py` | imports | no |
| + `provenance.py` | imports | no |
| + `cli.py` (Gen 20) | imports | **yes** |

`cli.py` imports `abandonment` and `provenance` at module level, so a wrong
order is an ImportError on *every* command including `recover`. The suite
imports `tools.capability.cli` against each intermediate rather than arguing
about it, and proves `cli.py`-first is exactly that ModuleNotFoundError. No
intermediate exposes the verb; the explicit target and the new verb arrive
together in the final step, so there is no window in which a correction could be
recorded through an implicitly resolved root.

`tests/test-capability-execution-generation20-installer.sh` — 83 assertions,
host-only, fixture-driven: declaration, source verification, the transaction,
the installed surface (including that a Generation-19-shaped `abandon` call is
now a usage error), coherence across all five intermediates, a reordered matrix
refused, ten interruption points recovered, and `postcommit` correctly *not*
rolled back. The installed library is byte-identical at the end.

`provisioning/execution/gen20-operator-ceremony.txt` chains
`--verify-source → --verify → --install → --verify-installed` and documents
`--recover`.

**Generation 20 is NOT installed. Nothing in this checkpoint used it against
production.**

## J. The correction ceremony

`provisioning/execution/g11-bc-y-cadm-000001-provenance-correction-ceremony.txt`
— prepared, **not executed**.

It pins the post-incident baseline `9374b568…`, all three `CADM-000001` member
digests and the disputed claim itself, all four immutable record digests, both
sequences, both counters, the transition count, `CINV-000002 = abandoned`,
occupancy 1 of 2, `CINV-000003` having no execution state, and the correction's
expected identity `CADM-000002`. The operator's no-container observation is
carried as an evidence reference, not as a gate — a correction touches no
container.

Gate 0 refuses a host that is not wholly Generation 20, including the specific
check that the installed `abandon` now requires `--store-root` — if it does not,
the host is still one where the incident is possible. The call runs from
`/usr/lib/kyri/python` with `--store-root /data/kyri/capability-runtime` spelled
out, and the emitted `target` is compared against the inode the ceremony
measured for itself.

Afterwards it re-checks that `CADM-000001` is byte-identical, that no transition
and no `CMUT` were written, that both sequences are unmoved, that no `CRES`
appeared, that `CINV-000003` gained nothing, and that the lifecycle and occupancy
are exactly where they were.

**It changes no lifecycle, no occupancy, touches neither `CINV-000001` nor
`CINV-000003`, creates no `CRES`, runs no Stage 2 and executes no payload.**

### It was rehearsed whole, which the last ceremony could not be

`tests/test-capability-cadm-000001-correction-rehearsal.sh` — 41 assertions:

- against this host as it stands, the ceremony **refuses**, at the
  installed-generation gate, and writes nothing;
- a Generation-20 library is built by the real installer into a fixture, a byte
  copy of the production runtime is made, and the ceremony runs whole against
  them;
- the ceremony's own emitted target is the **fixture's** inode, not production's;
- the mutation is exactly one `CADM` plus one counter increment, proven by
  reconstruction;
- `CADM-000001`, the transition journal, the mutation journal and every `CINV`
  and `CRES` are byte-identical;
- **production is byte-identical, and the installed library is byte-identical.**

That is the property G11-BC-X's rehearsal did not have. Before Generation 20 the
gates followed a substitution and the mutation did not.

## K. CINV-000001 and CINV-000003

Untouched, as instructed. `CINV-000001` was not reclaimed. `CINV-000003` Stage 2
was not run and has no execution state. One slot is free; whether Stage 2 can
proceed at 1 of 2 without reclaiming `CINV-000001` is a reviewer decision after
Generation 20 and the correction record are accepted.

## L. Verification

| Run | Result |
|---|---|
| Quick validator | **129/129**, passed |
| Full validator | **154/154**, passed |
| Clean-clone full validator | **154/154**, passed |
| ShellCheck (CI-pinned 0.9.0) | clean |
| Static + docs-static | passed |

New suites: provenance correction 22, mutation target 39, Generation-20
installer 83, correction rehearsal 41.

### Eight generation suites were reconstructing hosts that never existed

The first full run failed in eight places, and none of them was the new work.
Each of those suites rebuilds an earlier host by copying the live library and
undoing later generations **from a hand-kept list**, and every list stopped at
Generation 18. When the operator installed Generation 19, each fixture silently
kept `abandonment.py` and claimed to be a host that never had it. The suites'
own comments record this going stale at Generations 14, 15 and 16 already;
Generation 19 was the fourth time, and declaring Generation 20 would have been
the fifth.

The lists are gone. Every successor is found by name.

Three consequences of a generation being **declared but not installed** — which
had never happened before — are handled where they arise:

- a CREATE is subtracted from a count only when the live tree actually holds it;
- the successor chain is a SET of declared states rather than its last value,
  because the host sits at Generation 19's `cli.py` while Generation 20 declares
  the next one;
- `succession_rewind` removes a REPLACE whose pathname another ceremony in the
  same set introduced, instead of failing to restore it from a commit that never
  carried it.

The Generation-19 suite also published its intermediates from the **checkout**,
which was the same thing until Generation 20's `cli.py` imported a module a
Generation-19 fixture does not hold. It reads its own commit now.

One further defect was found by the clean clone and not by the local run: the
Generation-20 suite asserted the installer's mode was exactly 644, and a fresh
clone under a different umask carries 664. The property is that it is not
executable, and that is what it asserts.

Generation 20 is declared in `g5-preflight.sh`'s `GENERATION_DELTA`. The four
new suites run in CI; the disarmed reclamation rehearsal is named in both the
validator and the CI workflow as deliberately not run, so its omission is a
decision on the record rather than a gap.

Production after every run: runtime `9374b568…`, one administrative record,
`cadm-counter` `000001`, `cmut-counter` `000000000007`, Fabric `a87c2010…`,
installed library 82 objects. Unchanged.

## Actions NOT performed

`CADM-000001` was not edited or deleted. `CINV-000002` was not reverted. No
compensating lifecycle transition was created. `CINV-000001` was not abandoned.
CINV-000003 Stage 2 and Stage 3 were not run. No payload was executed.
`MAXIMUM_SLOTS` is unchanged at 2. No runtime record was hand-edited. Fabric,
Trust, Artifact authority and Platform Evidence were not altered. Root Authority
was not mounted. ENG-0006 was not begun. **Generation 20 was not installed, and
no correction was recorded.**

## For the reviewer

1. Accept or refuse ADR-0016 and the `correct-provenance` verb.
2. Accept or refuse Generation 20. It is a breaking change to the `abandon`
   surface, deliberately.
3. If both are accepted: the operator runs `gen20-operator-ceremony.txt`, then —
   after your acceptance of the installation — the correction ceremony.
4. Then decide CINV-000003 Stage 2 at occupancy 1 of 2.
5. Authenticated actor provenance remains open and is not addressed here.
