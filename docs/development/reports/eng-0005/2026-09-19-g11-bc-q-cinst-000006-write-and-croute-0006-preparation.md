# G11-BC-Q — the CINST-000006 write, verified; the reviewed bodies, recovered

ENG-0005. 2026-09-19. Branch `arch/eng-0005-execution-transition`.

Three things happened in this checkpoint.

The CINST-000006 production write was verified independently of the reviewer's
report, and the mutation it produced was accounted for by content rather than
by pathname or timestamp.

The reviewed CROUTE-0006 and CSEL-000004 request bodies — pinned by digest in
G11-BC-N and never committed — were **re-derived and reproduced byte for byte**,
and are now committed. This discharges the reproducibility issue carried from
G11-BC-O and G11-BC-P.

The CROUTE-0006 freeze artifact was prepared, gated twice, and **rehearsed
whole** before being committed. Nothing was installed and nothing was written
to production.

---

## 1. Starting source authority

| | |
| --- | --- |
| HEAD at start | `7a9a8949a01f14715981e7cc8c92f6ba1dd97c53` |
| required source authority | `7a9a8949a01f14715981e7cc8c92f6ba1dd97c53` ✔ |
| branch | `arch/eng-0005-execution-transition` ✔ |
| origin | contains HEAD at the same commit ✔ |
| working tree | clean; nothing staged, nothing untracked ✔ |
| G11-BC-P report | present ✔ |
| accepted correction implementation | `e78c67857503daf877f9aaa9c5242c60011578d8` ✔ |

## 2. G11-BC-P correction authority

The corrected CINST-000006 freeze artifact
`provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt` was the executable
authority for the ceremony. G11-BC-P replaced both of its gates after the
original pair failed live — Gate 1 failing **open** — and proved the corrected
pair fails closed by executing them. The reviewed body was never touched by
that correction.

## 3. The corrected freeze result

The ceremony completed. Frozen input, as installed:

```
/etc/kyri/fabric/cinst-000006.json
sha256  6746234a2b1293052c223ff4a3e253286129ddf58b9d8397d1ecf4d04175e162   ✔ reviewed
bytes   1269                                                              ✔ reviewed
owner   root:cschott   mode 0640                                          ✔ reviewed
```

Verified read-only this checkpoint, directly from the live path.

## 4. Final current-eligibility result

```
eligible True | 12 of 12 met | unmet [] | reasons []
```

Recomputed this checkpoint against production through the released evaluator at
the current clock (`2026-09-19T17:13-05:00`): unchanged, 12 of 12.

## 5. Final production preflight

As accepted by the reviewer:

```
destination_exists    false
mutated               false
operation             admit-instance
outcome               preflight
predicted_record_id   CINST-000006
rehearsal_reason      null
would_accept          true
request_digest        sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372
```

Pre-write Fabric aggregate:
`3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28`.

## 6. The immutable production write

```
outcome        accepted
reason         null
record_id      CINST-000006
record_kind    capability-instance
request_digest sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372
request_id     g11bcn-admit-instance-cpkg-0001-chost-0001-cadv-000007-supersedes-cinst-000005
```

## 7. Persisted record and semantics

`/var/lib/kyri/fabric/capability-instances/CINST-000006.yaml`

```
sha256  5a320fa0cb9f678d3f78a11416beec17945b06add25446fbae7e0e1bf5575b9b   ✔ matches reviewer
```

Read back from the live record this checkpoint, field by field:

| field | value |
| --- | --- |
| `instance_id` | CINST-000006 |
| `lifecycle_state` | admitted |
| `supersedes` | CINST-000005 |
| `advertisement_id` | CADV-000007 |
| `capability_id` | CAPDEF-0001 |
| `capability_package_id` | CPKG-0001 |
| `capability_host_id` | CHOST-0001 |
| `contract_id` | CCON-0001 |
| `package_trust_record_id` | TREC-000002 |
| `host_trust_record_id` | TREC-000001 |
| `admitted_at` | 2026-09-19T06:15:00-05:00 |
| `admitted_until` | 2026-09-23T06:00:00-05:00 |
| permitted operation | execute |
| permitted classification | internal |
| permitted target | HOST-0001 |
| stored `request_digest` | `sha256:c9444952…f6f02372` ✔ |

Every value matches the reviewer's record exactly.

## 8. Sequence transition

```
capability-instance.seq        5 -> 6
capability-advertisement.seq   7   unchanged
capability-route.seq           5   unchanged
capability-selection.seq       3   unchanged
```

## 9. Independent mutation accounting

Not inferred from pathnames or mtimes. Equal-size sequence replacement is
possible — `capability-instance.seq` is 2 bytes before and after — so the
accounting is done by **content**, and by reconstruction rather than
enumeration.

The live store was copied, `CINST-000006.yaml` removed from the copy, and
`capability-instance.seq` rewound to `5`. The canonical aggregate of that
reconstruction is:

```
3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28
```

which is exactly the reviewed pre-write aggregate. The aggregate is a hash over
every file's content, so reproducing it proves **no other file in the store
differs by a single byte**. The complete Fabric mutation was therefore:

1. creation of `capability-instances/CINST-000006.yaml`;
2. advancement of `capability-instance.seq` from `5` to `6`.

Both are within the released `admit-instance` write contract. No unexpected
mutation.

**A method note.** The aggregate digests `sha256sum` output, which names
absolute paths, so it is root-dependent by construction. A reconstruction under
a scratch root must therefore present the production path strings or it will
differ for the wrong reason. That renormalisation was validated first against
an *unmodified* copy of the live store, which reproduced the live aggregate
exactly, before it was trusted to judge a modified one.

The frozen-input store was accounted for the same way. `/etc/kyri/fabric` moved
from `aa4a2d00aa90f98c93823493b32fd9e4b34c31e2de5114aba9b8c5808ee87698` to
`292a0888ed3483a4d91e69d6c285b93f41fcbb3b6f328c0cfa0cc6737a2206d6`; removing
`cinst-000006.json` from a copy of the current store reproduces the former
exactly. The freeze's only effect there was the one file it declared.

## 10. Post-write Fabric validation

```
python3 -m tools.fabric.cli validate --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000

status    reported
findings  []
reason    null
counts    CADV 7, CINST 6, CROUTE 5, CSEL 3,
          contract 1, definition 1, host 1, package 1
```

CADV-000007 remains the advertisement head; CINST-000006 is the
capability-instance head. CROUTE-0006, CSEL-000004 and CINV-000003 are absent.

## 11. Post-CINST Fabric aggregate

Computed with the established canonical command:

```bash
find /var/lib/kyri/fabric -type f -print0 | sort -z \
  | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
```

```
1549986cf2119f9da4af805cf5cbb5733f9c0fa1d28b76e25dc3e78be7f2cb78
```

**This is the required baseline for the CROUTE-0006 freeze artifact.** The
pre-CINST baseline `3bcb5779…` is not reused, and the committed artifact pins
`1549986c…`.

## 12. No mutation outside Fabric

| authority | aggregate | agrees with G11-BC-P |
| --- | --- | --- |
| `/usr/lib/kyri/python` (runtime) | `70011c72f8a1c9c4f29111c6ae0f6caa6c8ece6973611a64d0664e437f58e793` | yes |
| `/var/lib/kyri/evidence` (Platform Evidence) | `62c875851b83ca0d53c8b82469709be530cc6dad2957bb766fdb65fc2b5dc507` | yes |
| `/var/lib/kyri/artifacts` (Artifact authority) | `ef4297c611a2dd824f1c1e4960e64304f72b04d77c0f5f20dd650b0b3eb410df` | yes |
| `/data/kyri/capability-runtime` | cinv.seq 2, cres.seq 1 | yes |
| Root Authority | not mounted | yes |

Trust: `valid true`, `problems []`, counts authority 1, record 2, decision 2,
lineage 3, evidence 7, audit 4. TREC-000001 and TREC-000002 remain the
governing records.

The installed runtime was not reinstalled, sudoers was not modified, and Root
Authority was not mounted.

---

## 13. The reviewed request bodies, recovered as bytes

This is the substantive correction in this checkpoint.

G11-BC-N reviewed the CROUTE-0006 and CSEL-000004 bodies, recorded their
digests, byte counts and request digests in prose — and committed neither. That
is the same defect that lost the Option-B CINV payload, whose bytes could not
be found anywhere on this host when they were needed. A digest without its
bytes is not a reviewable artifact.

Both bodies were **re-derived, not invented**, and required to agree exactly
with the previously reviewed authority before anything was committed.

**Method, and why it is trustworthy.** The derivation runs from a body that is
already accepted and on disk, transformed by the G11-BC-M → G11-BC-N deltas
that the two *already accepted* G11-BC-N bodies (CADV-000007, CINST-000006)
establish: the `g11bcm-` → `g11bcn-` request-id prefix, the advanced
predecessor identifiers, the 2026-09-15 → 2026-09-19 window, and the
`provenance.recorded_at` date.

The extraction step was validated before it was trusted: the CROUTE-0005 body
rendered out of its committed freeze artifact is **byte-identical** to the
accepted frozen input `/etc/kyri/fabric/croute-0005.json`, so the method
reproduces a known-good body exactly.

### CROUTE-0006

Derived from the CROUTE-0005 body. Reproduced on the first attempt:

```
sha256  cd7a1f9a8cd5f982d3f62b7d02ff253bc6c33b006a9aa0717aff162a1e40a78c   ✔ reviewed
bytes   678                                                               ✔ reviewed
```

### CSEL-000004

Derived from the withdrawn G11-BC-M CSEL body recovered at commit
`77670b71749cd051cb1a0825ca93163dda04b982` (verified at its historical digest
`60857d68…`, 605 bytes). The structural deltas produced a 605-byte body with
the **wrong** digest, so one field was still wrong.

Rather than guess, the remaining unknown — the `recorded_at` / `evaluated_at`
instant — was **solved for**: every second of 2026-09-19 was rendered and
digested until one reproduced the reviewed SHA-256. Exactly one did.

```
2026-09-19T06:40:00-05:00      (not 06:45, which the chain's 15-minute cadence suggested)
sha256  d04171c50397be2d41f8d066b526f237d982ac1df113840eb81afa6ec44c2f29   ✔ reviewed
bytes   605                                                               ✔ reviewed
```

Finding a 605-byte preimage of a reviewed SHA-256 is conclusive: these are the
reviewed bytes, not a plausible reconstruction of them. **No replacement bytes
were invented, and nothing was committed on a "close enough" match.**

### Confirmed by the engine, not only by digest

Both bodies were preflighted through the released CLI against a scratch copy of
current production. Each resolved to exactly the reviewed request digest —
which the derivation never targeted, since the request digest is computed by
the engine from the canonicalised body:

| body | request digest resolved | reviewed |
| --- | --- | --- |
| CROUTE-0006 | `sha256:4a81d1c7fc7c023de601ea004a8bbd3ee9d4bb150b9867e52e1c7075447035a9` | ✔ |
| CSEL-000004 | `sha256:2856ff77601e24e80f9414abf93a6eb4719d0514b386ceaca9472e712f1fd437` | ✔ |

The CSEL preflight additionally resolved `selected_instance_id CINST-000006`
against a store with CROUTE-0006 written — the semantics the reviewer specified.

### Committed

```
provisioning/fabric/g11-bc-n-croute-0006-input.json    678 bytes  cd7a1f9a…
provisioning/fabric/g11-bc-n-csel-000004-input.json    605 bytes  d04171c5…
```

`-input.json` rather than `-payload.json`: "input" is this repository's own word
for these bytes — the CLI flag is `--input-file`, the destination is a "frozen
input", and `/etc/kyri/fabric/croute-0006.json` is what one becomes. The
`.json` extension and the `-input` suffix distinguish them from the
`-freeze.txt` ceremonies beside them at a glance: these are **inert reviewed
bytes, not executable ceremonies**. Nothing executes them; they carry no
shebang, which is asserted.

---

## 14. The CROUTE-0006 freeze artifact

`provisioning/fabric/g11-bc-n-croute-0006-freeze.txt`. Prepared, not executed.

Identity derived from the live sequence (`capability-route.seq` = 5), not
assumed: **CROUTE-0006**.

**The committed inert body is the only body it can render.** The block does not
restate the bytes in a heredoc; it copies
`provisioning/fabric/g11-bc-n-croute-0006-input.json` and refuses if that file
is absent. Two copies of reviewed bytes are two things that can disagree, so
there is one copy. The suite asserts the block carries no second copy.

What it pins:

| | |
| --- | --- |
| reviewed body sha256 | `cd7a1f9a8cd5f982d3f62b7d02ff253bc6c33b006a9aa0717aff162a1e40a78c` |
| reviewed byte count | 678 |
| request digest | `sha256:4a81d1c7fc7c023de601ea004a8bbd3ee9d4bb150b9867e52e1c7075447035a9` |
| predicted record id | CROUTE-0006 |
| Fabric baseline | `1549986cf2119f9da4af805cf5cbb5733f9c0fa1d28b76e25dc3e78be7f2cb78` (post-CINST) |
| required predecessor input | `/etc/kyri/fabric/cinst-000006.json` |
| destination | `/etc/kyri/fabric/croute-0006.json`, refused if it exists |

Refused **by name**, because all three are accepted route inputs still sitting
in `/etc/kyri/fabric` and all three are a plausible mis-paste:

```
CROUTE-0003  724ec6c2…
CROUTE-0004  bfb15383…
CROUTE-0005  6d8311e5…   the immediate predecessor, also 678 bytes,
                         routing to CINST-000005, whose admission closed
                         2026-09-19T06:00:00-05:00
```

### The gates

Both run **before** anything is installed, and both use the corrected G11-BC-P
patterns. No new unexecuted shell or Python composition was introduced.

**Gate 1 — wall clock. Three inputs, three channels.** A route body carries no
window of its own, so both windows it rests on are read out of the live store
through the released `inspect` CLI: CADV-000007, and the admission of
CINST-000006. Neither is restated as a constant, so neither can drift from the
authority it describes. The rendered body is `argv[1]`, the inspected
advertisement `argv[2]`, the inspected instance `argv[3]`; stdin carries the
program and nothing else. No command takes a second input redirection, and the
gate runs as a plain command under `if !` so its status is its own.

It refuses by name on every failure mode, including an instant carrying no
timezone offset, which is refused rather than guessed. The window rules:

```
observed_at <= now < valid_until          the advertisement
now < admitted_until                      the admission of CINST-000006
admitted_until <= valid_until             the admission cannot outlive it
admitted_at <= recorded_at < admitted_until   the route lies inside the admission
```

It also refuses a body that does not route to exactly `["CINST-000006"]`, does
not supersede CROUTE-0005, or is not `route_version 6`; and an instance that is
not `admitted` or does not rest on CADV-000007.

**Gate 2 — current eligibility.** CINST-000006's eligibility, recomputed by the
released evaluator at the current clock. Unlike the CINST freeze, CINST-000006
is already a written record, so no candidate is applied to a copy and the
evaluator reads production directly; `compute-eligibility` is read-only, and
the block's closing aggregate check proves it mutated nothing. The result
arrives as a file argument and the program on a quoted heredoc, so no
backslash appears anywhere inside an f-string expression. It requires
`eligible is True`, `unmet == []` and a non-empty condition list.

At operator execution time the block therefore refuses, **before** installing
`/etc/kyri/fabric/croute-0006.json`, if CADV-000007 is no longer fresh, if
CINST-000006's admission has closed, or if CINST-000006 is not currently
eligible through the released evaluator.

---

## 15. Rehearsal — the whole block, executed

Against a fixture copied from the production stores, with three substitutions
and nothing else (the Fabric root, the frozen-input root, and `FABRIC_BEFORE`,
which the second forces). `sudo` is shimmed. Trust and Evidence stay pointed at
the real stores, which the block only reads.

The block runs to completion:

```
ok  observed_at <= now < valid_until
ok  now < admitted_until <= valid_until
ok  admitted_at <= recorded_at < admitted_until
eligible True | 12 of 12 met | unmet [] | reasons []
ok  eligible true, no unmet conditions
ok  CINST-000006 eligible at the current clock
ok  predicted_record_id CROUTE-0006
ok  request_digest      sha256:4a81d1c7fc7c023de601ea004a8bbd3ee9d4bb150b9867e52e1c7075447035a9
```

and the suite independently asserts of that run:

- the rendered block references no production Fabric or frozen-input path;
- the installed frozen input is `cd7a1f9a…`, 678 bytes, mode 0640;
- the `create-route` stayed a preflight — `would_accept true`, `mutated false`,
  `destination_exists false`;
- **no route record was written even in the fixture**, and the fixture's
  `capability-route.seq` is still 5.

**Resolution, proved separately.** A freeze does not select, so the reviewed
body was written into a scratch store and the released selector asked what it
resolves to:

```
scratch write     record_id CROUTE-0006, digest sha256:4a81d1c7…
route sequence    5 -> 6
selector          selected_instance_id CINST-000006
```

A route that accepts and resolves to the wrong instance is the one failure its
own identity cannot catch, which is why it is asserted rather than assumed.

### Fail closed, by stage

Each case changes exactly one thing and asserts where control stopped — and,
**new in this checkpoint, that the refusal is that stage's own judgement.**

| sabotage | exits nonzero | states its own refusal | no traceback | gate 2 runs | install runs | fixture store |
| --- | --- | --- | --- | --- | --- | --- |
| gate 1: advertisement expired | yes | yes | yes | **no** | **no** | byte-identical |
| gate 1: admission of CINST-000006 expired | yes | yes | yes | **no** | **no** | byte-identical |
| gate 1: `inspect` itself fails | yes | yes | yes | **no** | **no** | byte-identical |
| gate 2: CINST-000006 not eligible | yes | yes | yes | yes | **no** | byte-identical |
| gate 2: `compute-eligibility` itself fails | yes | yes | yes | yes | **no** | byte-identical |
| wrong body / digest mismatch | yes | yes | yes | **no** | **no** | byte-identical |
| changed Fabric baseline | yes | yes | yes | yes | (after) | byte-identical |

No route record was created in any run, including the sabotaged ones. An
expired advertisement stops the block before Gate 2 and before the install on
**3 of 3** runs.

**The expected-refusal column found a real defect in this suite's own first
draft.** The gate-2 sabotage had been written the way the CINST suite writes
it — substituting the `compute-eligibility` command line — which makes the
*command* fail, so the block refused with "compute-eligibility failed against
production" and the eligibility **judgement never ran**. It passed a
refusal-only assertion while proving nothing about the check it was aimed at.
That is precisely the failure mode G11-BC-P identified: a test that cannot
distinguish a refusal from a crash is not evidence about a gate. The sabotage
now overwrites the evaluator's *result file* immediately before the check
reads it, so the judgement is exercised, and the "command fails" case is a
separate row with its own expected refusal.

The two `inspect` calls are sabotaged individually for the same reason. A
blanket substitution hits both at once, and the gate then refuses because it
was handed an advertisement where an instance belonged — a true refusal for an
irrelevant reason.

---

## 16. Tests

| suite | result |
| --- | --- |
| `test-fabric-freeze-artifacts.sh` | 193 PASS, 0 FAIL (141 → 193) |
| `test-fabric-freeze-gate-execution.sh` | 65 PASS, 0 FAIL (63 → 65) |
| `test-fabric-freeze-croute-0006-rehearsal.sh` | **new** — 0 FAIL |
| `test-fabric-freeze-cinst-000006-rehearsal.sh` | 0 FAIL (spent-ceremony mode) |
| `test-static.sh` | 0 FAIL |
| `tools/dev/run-shellcheck.sh` | clean, exit 0 |

Two ShellCheck `SC2016` findings on the new suite are suppressed in-script with
justifications, per the workflow's stated policy: both are sed **addresses**
matching literal `${...}` text in the rendered block, so they must reach sed
unexpanded — text to find, not expressions to evaluate.

### Changes to existing suites, and why

**`test-fabric-freeze-artifacts.sh`.** Three changes.

*A row's body may now live in a committed file.* Field 16 names the inert input,
or `-` for the heredoc shape every earlier artifact uses. Where it names a file,
the suite requires the block to reference that path **and** to carry no BODY
heredoc of its own.

*The "every G11-BC-N artifact is gated" sweep is scoped to `*-freeze.txt`.* It
swept every `g11-bc-n-*` file, so committing inert `.json` bodies beside the
ceremonies made them fail as ungated ceremonies. They are reviewed bytes;
nothing executes them, so there is nothing for a clock to gate. They are judged
by digest, byte count and JSON validity instead.

*The backdated-expiry regression handles a three-input gate.* It detected gate
arity 1 or 2 and built the fixture shape that gate takes; a route gate reads
three files, so arity 3 is now detected and its fixture built. This follows the
principle G11-BC-P established rather than extending a special case: the gate
says what it reads, and the test does not guess. The route gate is now executed
against both an expired and an open window, so it is proved to refuse **and**
proved not to be a brick.

**`test-fabric-freeze-cinst-000006-rehearsal.sh`.** Its ceremony is spent, and
it had begun failing for the one reason that is not a defect: it rehearses a
freeze that installs `/etc/kyri/fabric/cinst-000006.json` and preflights against
a store where CINST-000006 does not exist, and the accepted write made both
preconditions permanently unsatisfiable.

Deleting it would delete the evidence; leaving it asserting a vanished world
would make it red forever. It now branches on the fact. In the spent state it
asserts what remains true and checkable — the post-write baseline, the
persisted record at its accepted SHA, the stored request digest, the sequence,
the frozen input in production, and that the committed artifact **still renders
the body that was written**. A skip would prove nothing; these do.

The new rehearsal suite is registered in `tests/host-only.manifest`,
`tools/dev/run-validation.sh` and `.github/workflows/ci.yml`.

---

## 17. Remaining authority window

```
CADV-000007 valid_until      2026-09-23T06:00:00-05:00
CINST-000006 admitted_until  2026-09-23T06:00:00-05:00
now                          2026-09-19T17:13-05:00
remaining                    ~3 days 13 hours
```

Still to fit inside it: the CROUTE-0006 freeze and write, the CSEL-000004
freeze and write, and CINV-000003 Stages 0–3. Gate 1 refuses rather than
extends when the window closes.

## 18. Actions NOT performed

Nothing in the stop boundary was done.

```
/etc/kyri/fabric/croute-0006.json     NOT installed
CROUTE-0006                           NOT written to production
CSEL-000004                           NOT installed, NOT written
g11-bc-n-csel-000004-freeze.txt       NOT created (Section H)
CINV-000003                           NOT allocated
staging, invocation, execution        none
existing Fabric records               unaltered
Trust / Artifact authority            unaltered
Platform Evidence                     unaltered
runtime                               not reinstalled
sudoers                               not modified
Root Authority                        not mounted
ENG-0006 / TrustGateway cutover       not begun
```

The CSEL-000004 **bytes** are committed; its executable authority is
deliberately not prepared, because its correct baseline does not exist until
CROUTE-0006 is permanently written. Preserve bytes now, prepare authority later.
The suite asserts that no CSEL-000004 freeze artifact exists.

## 19. Production no-mutation proof

Measured at the start of this checkpoint and again at the end, after every
rehearsal and every sabotage run:

```
/var/lib/kyri/fabric   1549986cf2119f9da4af805cf5cbb5733f9c0fa1d28b76e25dc3e78be7f2cb78   unchanged
/etc/kyri/fabric       292a0888ed3483a4d91e69d6c285b93f41fcbb3b6f328c0cfa0cc6737a2206d6   unchanged
capability-route.seq                                          5   unchanged
/etc/kyri/fabric/croute-0006.json                             absent
/var/lib/kyri/fabric/capability-routes/CROUTE-0006.yaml       absent
CSEL-000004, CINV-000003                                      not created, not allocated
```

Trust, Platform Evidence, Artifact authority and the installed runtime match the
aggregates in §12, so none was touched. The rehearsal suite re-asserts every
line above each time it runs.

## 20. Known risks

**The window is the binding constraint.** Three days remain and four ceremonies
are left. Gate 1 refuses rather than extends when it closes.

**The rehearsal is not the production run.** It substitutes two roots and shims
`sudo`. What it cannot exercise is the privileged `install` as root and the real
`/etc/kyri/fabric` permissions; those are first exercised in the live ceremony.
The substitutions are mechanical and asserted — the rendered block is checked to
contain no production path — but they are substitutions.

**The CSEL-000004 timestamp was recovered by search, not by record.** The bytes
are proved by preimage and the engine confirms the reviewed request digest, so
the body is certain. What is *not* recoverable is the reasoning that chose
06:40 over the chain's 15-minute cadence. It is recorded here so the next
reader does not have to re-derive it.

**`FABRIC_BEFORE` is root-dependent by construction.** The aggregate digests
`sha256sum` output including absolute paths. Correct for pinning a specific
store, and why the rehearsal must compute its own.

**Gate 2 reads production directly.** Correct — CINST-000006 is a written
record — and cheaper than the CINST gate's whole-store copy. It relies on
`compute-eligibility` being read-only, which the closing aggregate check
verifies on every run rather than assumes.

---

## 21. Readiness for CROUTE-0006

The artifact is committed, gated twice, rehearsed whole, and proved to fail
closed at every stage. The reviewed body is committed as recoverable bytes. The
baseline it pins is the current production aggregate.

What remains is the reviewer's verification of the committed artifact, and then
a single operator freeze of CROUTE-0006 — which installs one file and writes
nothing.
