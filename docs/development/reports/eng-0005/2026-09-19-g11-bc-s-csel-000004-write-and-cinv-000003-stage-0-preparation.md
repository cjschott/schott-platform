# G11-BC-S — the CSEL-000004 write, verified; CINV-000003 Stage 0 prepared

ENG-0005. 2026-09-19. Branch `arch/eng-0005-execution-transition`.

The CSEL-000004 production write was verified independently of the reviewer's
report and its mutation accounted for by content. The governed Fabric chain for
CINV-000003 is now complete.

The CINV-000003 **Stage 0** ceremony was then prepared, gated four times, and
rehearsed whole.

**One material finding on the released contract, reported before anything was
prepared:** Stage 0 allocates nothing. §6 states the released contract as it
actually is.

Nothing was performed against production.

---

## 1. Starting source authority

| | |
| --- | --- |
| HEAD at start | `73102de00f65b9c247bef475feea35b6e1aa648c` |
| required source authority | `73102de00f65b9c247bef475feea35b6e1aa648c` ✔ |
| branch | `arch/eng-0005-execution-transition` ✔ |
| origin | contains HEAD at the same commit ✔ |
| working tree | clean; nothing staged, nothing untracked ✔ |
| G11-BC-R report | present ✔ |

## 2. Prior preparation authority

G11-BC-R prepared `provisioning/fabric/g11-bc-n-csel-000004-freeze.txt`, gated
three times, and rehearsed the whole block including a scratch write that
predicted the identity and sequence the operator's write would produce.

## 3. The freeze result and its gates

```
/etc/kyri/fabric/csel-000004.json
sha256  d04171c50397be2d41f8d066b526f237d982ac1df113840eb81afa6ec44c2f29   ✔ reviewed
bytes   605                                                               ✔ reviewed
owner   root:cschott   mode 0640                                          ✔ reviewed
```

Verified read-only this checkpoint, and **byte-identical to the committed inert
input** `provisioning/fabric/g11-bc-n-csel-000004-input.json`. That is the
second end-to-end confirmation that recovering and committing the reviewed
bytes in G11-BC-Q worked: the CSEL body — whose timestamp had to be solved for
by preimage search because G11-BC-N recorded only a digest — is literally what
was frozen and written.

| gate | result |
| --- | --- |
| **1 — wall clock and binding** | CADV-000007 fresh; CINST-000006 admission open; `admitted_until <= valid_until`; reviewed `evaluated_at` inside the admission; CROUTE-0006 routes exactly to CINST-000006; request class matches CROUTE-0006 |
| **2 — current eligibility** | `eligible true`, 12 of 12 met, `unmet []`, `reasons []` |
| **3 — governed resolution** | resolved route CROUTE-0006, `route_version 6`, selected CINST-000006, considered `[CINST-000006]`, excluded `[]` |

Current eligibility recomputed this checkpoint at the current clock: unchanged,
12 of 12.

## 4. Final production preflight

```
destination           /var/lib/kyri/fabric/capability-selections/CSEL-000004.yaml
destination_exists    false
mutated               false
operation             select
outcome               preflight
predicted_record_id   CSEL-000004
record_kind           capability-selection
selected_instance_id  CINST-000006
request_digest        sha256:2856ff77601e24e80f9414abf93a6eb4719d0514b386ceaca9472e712f1fd437
would_accept          true
```

Pre-write Fabric aggregate:
`f122e53034eeca45ce7b1d8ac5afdc9562a16a086757e203291a8ce1b018cefb`.

## 5. The production write, and what it persisted

```
outcome               accepted
reason                null
record_id             CSEL-000004
record_kind           capability-selection
selected_instance_id  CINST-000006
request_digest        sha256:2856ff77601e24e80f9414abf93a6eb4719d0514b386ceaca9472e712f1fd437
```

`/var/lib/kyri/fabric/capability-selections/CSEL-000004.yaml`

```
sha256  5e58396f3e6937701f07c8b7f2aabbfdb7483213f801358e5ea369eb223aaf24   ✔ matches reviewer
```

Read back from the live record, field by field:

| field | value |
| --- | --- |
| `selection_id` | CSEL-000004 |
| `route_id` | CROUTE-0006 |
| `route_version` | 6 |
| `selected_instance_id` | CINST-000006 |
| `considered_candidates` | [CINST-000006] |
| `excluded_candidates` | [] |
| `local_node_identity` | HOST-0001 |
| `selected_at` | 2026-09-19T06:40:00-05:00 |
| `selection_reason` | first eligible candidate in declared order |
| request class | CAPDEF-0001 / CCON-0001 / ["1.0.0"] / internal / local-only |
| stored `request_digest` | `sha256:2856ff77…1fd437` ✔ |

Every value matches the reviewer's record exactly.

### Sequence transition

```
capability-selection.seq       3 -> 4
capability-advertisement.seq   7   unchanged
capability-instance.seq        6   unchanged
capability-route.seq           6   unchanged
capability-invocation.seq      2   unchanged
capability-result.seq          1   unchanged
```

### Mutation accounting

By content, not by pathname or mtime — `capability-selection.seq` is 2 bytes
before and after, so equal-size replacement is possible and enumeration would
not detect it.

The live store was copied, `CSEL-000004.yaml` removed from the copy, and
`capability-selection.seq` rewound to `3`. The canonical aggregate of that
reconstruction is:

```
f122e53034eeca45ce7b1d8ac5afdc9562a16a086757e203291a8ce1b018cefb
```

exactly the accepted pre-write aggregate. The aggregate hashes every file's
content, so reproducing it proves **no other file differs by a single byte**.
The complete Fabric mutation was therefore:

1. creation of `capability-selections/CSEL-000004.yaml`;
2. advancement of `capability-selection.seq` from `3` to `4`.

Both are within the released `select` write contract. The renormalisation the
reconstruction requires was validated against an *unmodified* copy first, which
reproduced the live aggregate exactly.

`/etc/kyri/fabric` moved from `81f86a80…` to `b6a5074a84f70713482efbdec860b392d4f1c3e618a084d5445d47eaab22a610`;
removing `csel-000004.json` from a copy reproduces the former exactly.

### Post-write validation

```
status    reported      findings []      reason null
counts    CADV 7, CINST 6, CROUTE 6, CSEL 4,
          contract 1, definition 1, host 1, package 1
```

### Post-CSEL Fabric aggregate

```
a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5
```

**This is the complete governed Fabric chain baseline for CINV-000003**, and it
is what the Stage 0 artifact pins.

### No mutation outside Fabric

| authority | aggregate | agrees with G11-BC-R |
| --- | --- | --- |
| `/usr/lib/kyri/python` (runtime) | `70011c72f8a1c9c4f29111c6ae0f6caa6c8ece6973611a64d0664e437f58e793` | yes |
| `/var/lib/kyri/evidence` (Platform Evidence) | `62c875851b83ca0d53c8b82469709be530cc6dad2957bb766fdb65fc2b5dc507` | yes |
| `/var/lib/kyri/artifacts` (Artifact authority) | `ef4297c611a2dd824f1c1e4960e64304f72b04d77c0f5f20dd650b0b3eb410df` | yes |
| `/data/kyri/capability-runtime` | `159651ee6c98113f182b80cecdff5a83f5782df8ff8e16c6cf30ac91f0ea92fc`, cinv.seq 2, cres.seq 1 | yes |
| Root Authority | not mounted | yes |

Trust: `valid true`, `problems []`. TREC-000001 and TREC-000002 remain the
governing records. No runtime reinstall, no sudoers change, Root Authority
unmounted.

---

## 6. The released CINV stage contract, reconstructed

Read from `tools/capability/cli.py`, `tools/common/trusted_source.py`,
`tools/capability/invocation_identity.py`, and the accepted CINV-000001 and
CINV-000002 ceremonies (G11-BB-A, G11-BB-X, G11-BB-Y, G11-BB-Z). Not inferred
from this checkpoint's instructions.

**Stage 0 allocates nothing.** It is not a released CLI command at all. It is
the operator placing the reviewed payload in a coordinator-owned approved root
and looking at the host one last time. G11-BB-A states it directly: *"Stage 0
may create only the reviewed operator work area."*

| stage | released command | allocates | mutates | irreversible |
| --- | --- | --- | --- | --- |
| **0** | none — `mkdir` + place payload | **nothing** | only `/data/kyri/work/<label>/` | no |
| **1** | `capability invoke` | **CINV-000003** | writes the immutable invocation record, stages the package tree, `capability-invocation.seq 2 -> 3` | **yes — the first irreversible step** |
| **2** | `capability authorise-launch` | nothing | nothing governed | no |
| **3** | `capability execute` | CRES | runs the capability, writes the result record | yes |

Stage-specific detail that bears on Stage 0:

- **What Stage 0 reads.** Everything: Fabric, Trust, the runtime store, the
  payload. It writes nothing governed, so its whole job is judgement.
- **What Stage 1 requires of Stage 0's output.** `open_trusted_regular_file`
  checks the *descriptor*, not the path: a regular file, owned by the supplied
  trusted uid, not group- or other-writable, and — here — **exactly one hard
  link**, under a root owned by that uid and not group- or world-writable. Those
  are properties Stage 0 must establish, so the block establishes and then
  verifies them rather than assuming them.
- **Payload digest binding.** Two different values over one document. The **raw
  sha256** is what the operator checks on disk; the **`payload_digest`** is
  sha256 over the canonical form and is what CINV-000003 will record and Stage 2
  re-presents against. Reformatting moves the first and not the second.
- **CSEL binding.** Stage 1 names `--selection-id CSEL-000004` and
  `--instance-id CINST-000006`; the released preflight resolves the chain and
  reports `current_eligibility`.
- **Exit codes.** Stage 1 returns **rc=1 with `status: prepared`** — the JSON is
  the verdict, the exit code is not. Stage 2 returns rc=0. This is a released
  behaviour, not a defect, and Stage 0 does not touch it.
- **A successful stop after Stage 0** is: the work area exists with the reviewed
  payload at the reviewed digest and the required ownership and modes; no
  governed store has moved; no identifier has been allocated.

**This differs from the framing in the instructions for this checkpoint**,
which contemplated Stage 0 possibly allocating CINV-000003 and asked for pins
"where applicable". It does not allocate. The artifact pins what Stage 0 is
responsible for and, separately, states what Stage 1 *will* be — labelled as
not to be run — so the reviewer can see the target without it becoming
executable authority. No architecture was changed to make either framing true.

---

## 7. The CINV-000003 payload, re-verified

Committed at `provisioning/execution/g11-bc-n-cinv-000003-payload.json`,
unchanged since `906b760`.

```
raw bytes          300                                                             ✔
raw sha256         d01faccc67b83c60051348422861c121211a4079f7748572bad0a4882575a569  ✔
canonical bytes    271                                                             ✔
canonical digest   591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3  ✔
operation          verify-execution-boundary                                       ✔
arguments.count    1                                                               ✔
arguments.label    g11bcn-third-controlled-production-invoke                       ✔
note binds         CADV-000007 / CINST-000006 / CROUTE-0006 / CSEL-000004          ✔
```

The canonical values were recomputed with the released canonicalizer
(`tools.capability.invocation_identity.canonical_bytes`), the same function
Stage 1 will use. No payload byte was modified.

---

## 8. Stage 0, prepared

`provisioning/execution/g11-bc-n-cinv-000003-stage-0-ceremony.txt`. Prepared,
not performed.

Its only durable effect is a directory and a file **outside every governed
store**:

```
/data/kyri/work/g11bcn                    cschott:cschott  0700
/data/kyri/work/g11bcn/third-invoke.json  cschott:cschott  0600  300 bytes  1 link
```

**The payload is copied, not retyped.** The CINV-000001 and CINV-000002
ceremonies rendered theirs from a heredoc; the reviewed Option-B payload that
was never committed could not be recovered when it was needed — searched for by
content across the repository, `/data/kyri` and the operator home, and gone.
The bytes are committed now, so the block copies them.

### What it pins

| | |
| --- | --- |
| payload raw sha256 / bytes | `d01faccc…4882575a569` / 300 |
| payload canonical digest / bytes | `591d4b0d…7d3c59b3` / 271 |
| post-CSEL Fabric aggregate | `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5` |
| capability-runtime aggregate | `159651ee6c98113f182b80cecdff5a83f5782df8ff8e16c6cf30ac91f0ea92fc` |
| `capability-invocation.seq` | 2 (and CINV-000003 absent) |
| `capability-result.seq` | 1 |
| governed chain | CADV-000007 / CINST-000006 / CROUTE-0006 / CSEL-000004 |
| execution image | `5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` |

It does **not** pin a request digest for the invocation: the released contract
defines none before allocation, and inventing one would be a pin the contract
does not define. `predicted_invocation_record_id CINV-000003` is derived by the
released preflight in the rehearsal (§9) rather than asserted by the block,
because Stage 0 does not run the preflight.

Refused by name: the accepted CINV-000001 and CINV-000002 payloads, which are
still in their own work areas and are a plausible mis-copy.

### The four gates

All four run **before** anything is created, and all use the corrected
G11-BC-P/Q/R patterns — each input on its own argv channel, stdin carrying only
program text, every gate a plain command under `if !` so its status is its own,
and every failure refusing by name.

**Gate 1 — current governed authority. Five inputs, five channels.** The
advertisement, instance, route and selection are read live through the released
`inspect`. Beyond the windows it refuses a route that no longer points at
exactly CINST-000006, and a selection that no longer resolves through
CROUTE-0006, no longer selects CINST-000006, considered a different candidate
set, carries exclusions, or names a different node. An instant with no timezone
offset is refused rather than guessed.

**Gate 2 — current eligibility** through the released evaluator at the current
clock.

**Gate 3 — the chain has not moved.** Both governed stores by aggregate, both
runtime sequences, the absence of CINV-000003, and Trust validity. Trust is
checked here because Stage 1 reads it, and a Trust store that has gone invalid
must stop the ceremony at the last reversible point rather than the first
irreversible one.

**Gate 4 — the payload**, rendered into the gate's own temporary directory and
judged there. Raw digest, raw byte count, canonical digest, canonical byte
count, operation, argument count, label, and that the note binds all four chain
records. Nothing is placed in the work area until all of it agrees.

**Why a ceremony that allocates nothing still needs gates.** Stage 0 is where
the operator last looks before the irreversible step. The engine judges every
request at the instant the request names and will not tell an operator that the
authority they are acting under has expired — the failure the withdrawn
G11-BC-M CSEL artifact demonstrated. A work area prepared against a chain that
has since moved is a work area for Stage 1 to allocate against the wrong
authority.

---

## 9. Rehearsal

The whole block runs to completion against a fixture copied from the production
Fabric and capability-runtime stores, with three substitutions and the two
baselines they force.

```
ok  observed_at <= now < valid_until
ok  now < admitted_until <= valid_until
ok  CROUTE-0006 routes to exactly CINST-000006
ok  CSEL-000004 selects CINST-000006 through CROUTE-0006
eligible True | 12 of 12 met | unmet [] | reasons []
ok  CINV-000003 absent          ok  trust valid, no problems
raw        d01faccc…  (300 bytes)
canonical  591d4b0d…  (271 bytes)
ok  operation verify-execution-boundary, count 1, reviewed label
ok  the note binds CADV-000007 / CINST-000006 / CROUTE-0006 / CSEL-000004
ok  uid 1000, root 0700, file 0600, one link
ok  no invocation identifier was allocated
```

**The assertion that matters most is negative.** After the happy path the
fixture runtime store is byte-identical to its own before-state,
`capability-invocation.seq` is still 2, `capability-result.seq` is still 1, and
no CINV-000003 or CRES record exists. Stage 0 does not reach any Stage-1 effect.

The extracted block is also asserted to contain **no `sudo` at all** — the two
read-only observation commands that need the capability account are deliberately
outside it, so a privilege prompt cannot land in the middle of a gated sequence.

**The released preflight over the work area Stage 0 produced** — run against the
fixture runtime store, not production — accepts and reports:

```
predicted_invocation_record_id   CINV-000003
payload_digest                   sha256:591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
selection_id CSEL-000004         instance_id CINST-000006
current_eligibility true         scope_permits_operation true
would_accept true                outcome preflight
```

and allocated nothing: the sequence is still 2.

### Fail closed, by stage

Eighteen sabotages, each changing exactly one thing. Every one must refuse
**for its own reason** and must not crash.

| sabotage | gate 2 | gate 3 | gate 4 | work area | refusal |
| --- | --- | --- | --- | --- | --- |
| advertisement expired | no | no | no | **no** | CADV-000007 is EXPIRED |
| admission expired | no | no | no | **no** | admission closed |
| route head moved | no | no | no | **no** | no longer routes to exactly CINST-000006 |
| selection names another route | no | no | no | **no** | does not resolve through CROUTE-0006 |
| selection names another instance | no | no | no | **no** | does not select CINST-000006 |
| advertisement absent from store | no | no | no | **no** | could not inspect CADV-999999 |
| `inspect` itself fails | no | no | no | **no** | could not inspect CADV-000007 |
| not currently eligible | yes | no | no | **no** | not eligible at the current clock |
| `compute-eligibility` fails | yes | no | no | **no** | compute-eligibility failed |
| Fabric baseline moved | yes | yes | no | **no** | the Fabric store has moved |
| runtime store moved | yes | yes | no | **no** | the capability-runtime store has moved |
| invocation sequence moved | yes | yes | no | **no** | capability-invocation.seq is 2, expected 9 |
| result sequence moved | yes | yes | no | **no** | capability-result.seq is 1, expected 9 |
| Trust does not validate | yes | yes | no | **no** | the Trust store does not validate |
| `trust validate-store` fails | yes | yes | no | **no** | could not be validated |
| payload raw bytes changed | yes | yes | yes | **no** | raw digest |
| payload relabelled | yes | yes | yes | **no** | raw digest |
| payload missing | yes | yes | yes | **no** | not recoverable |

No invocation record was created in any run. An existing work area is refused
before any gate runs. An expired advertisement stops the block before Gate 2 and
before creation on **3 of 3** runs.

### Gate 4's canonical check, judged directly

The raw check fires first and catches every payload substitution, so **no
sabotage of the payload source can reach the canonical program**. A sabotage
that never touches what it is aimed at proves nothing about it — the shape
G11-BC-R found in its own first draft. So the canonical check is extracted and
run against crafted documents.

It is run the way the block runs it — the **program on stdin, the data as
argv**, from the repository root. Executing the extracted file by path would put
`/tmp` on `sys.path` and the released canonicalizer would not import, which
would read as a failure of the gate rather than of the harness.

Each crafted document is judged against **its own** canonical digest and byte
count. Against the reviewed ones every case refuses on the digest, and the
semantic checks below would never run — refusals proving only that sha256 works.
Those checks exist as a cross-check on the **pin**, not on the document: they
are what would catch a reviewed digest constant that is itself wrong, and that
is reachable only when the digest agrees. So the digest is made to agree and the
semantics made to fail:

```
a changed label                          arguments.label is …
a changed operation                      the payload operation is execute
a changed argument count                 arguments.count is 2
a note that does not bind CSEL-000004    the note does not bind CSEL-000004
no arguments object                      carries no arguments object
no note                                  carries no note
not JSON                                 not readable JSON
```

and against the reviewed pins every one of them refuses on the canonical digest.
A **reformatted** payload — the same document, different layout — is *accepted*
by the canonical check, which is what makes the raw check load-bearing rather
than redundant.

---

## 10. Spent ceremony — CSEL-000004

The CSEL freeze rehearsal is now in spent-ceremony mode, following the corrected
durable-facts model. It asserts the immutable accepted record at
`5e58396f…`, its stored request digest, `selected_instance_id CINST-000006`,
`route_id CROUTE-0006`, `route_version 6`, no exclusions, the frozen input as
reviewed bytes, the committed inert input byte-identical to it, and
`capability-selection.seq >= 4`.

It deliberately does **not** pin the whole current Fabric aggregate: that moves
with every later write, and pinning it is the defect that broke the CINST
spent mode when CROUTE-0006 landed.

---

## 11. Tests

| suite | result |
| --- | --- |
| `test-capability-cinv-000003-stage-0-rehearsal.sh` | **new** — 263 PASS, 0 FAIL |
| `test-fabric-freeze-csel-000004-rehearsal.sh` | 0 FAIL (spent-ceremony mode) |
| `test-fabric-freeze-croute-0006-rehearsal.sh` | 0 FAIL (spent) |
| `test-fabric-freeze-cinst-000006-rehearsal.sh` | 0 FAIL (spent) |
| `test-fabric-freeze-artifacts.sh` | 0 FAIL |
| `test-fabric-freeze-gate-execution.sh` | 0 FAIL |
| `test-capability-fabric.sh` | 0 FAIL |
| `test-fabric-route-head.sh` / `route-preflight` / `preflight` / `g11-integrity` | 0 FAIL |
| `test-capability-invoke-preflight.sh` / `invoke-current-eligibility.sh` | 0 FAIL |
| `test-capability-invocation-operation-authority.sh` | 0 FAIL |
| `test-capability-execution-payload-operation-contract.sh` | 0 FAIL |
| `test-capability-execution-authority-gate.sh` / `quota` / `lifecycle` / `transition-action` / `duplicate-result-gate` | 0 FAIL |
| `test-capability-runtime.sh` | 0 FAIL |
| `test-static.sh` | 0 FAIL |
| `tools/dev/run-shellcheck.sh` | clean, exit 0 |

Three ShellCheck `SC2016` findings on the new suite are suppressed in-script
with justifications, per the workflow's stated policy: all three are sed
**addresses** matching literal `${...}` text in the rendered block — text to
find, not expressions to evaluate.

### Harness defects found and fixed

Four, all in the new suite rather than in the artifact, and all found by
running it:

**Comparing a fixture aggregate to production's.** The aggregate digests
`sha256sum` output, which names absolute paths, so a fixture store can never
equal production's. Corrected to compare the fixture against its own
before-state.

**A fixture that could not be torn down.** The staged package tree is copied
with its real modes, which are deliberately read-only; `rm -rf` cannot remove a
file from a directory it may not write. The fixture is now made writable before
teardown.

**Two sabotages that missed their target.** One matched a four-space indent
against a two-space one, so it changed nothing and the block ran the happy path
to completion — which the suite correctly reported as "the block exited 0". The
other used a sed address delimited by `/` on a line containing `/`. Both
corrected.

**A probe read the wrong exit code.** `inspect` on a missing record was read as
exiting 0 because the probe piped it through `head`. It exits 1, and the
ceremony's helper catches it and refuses by name — which is the better
behaviour and is now asserted.

---

## 12. Remaining authority window

```
CADV-000007 valid_until      2026-09-23T06:00:00-05:00
CINST-000006 admitted_until  2026-09-23T06:00:00-05:00
now                          2026-09-19T~22:00-05:00
remaining                    ~3 days 8 hours
```

Still to fit inside it: Stage 0, then Stages 1–3. Gate 1 refuses rather than
extends when the window closes.

## 13. Actions NOT performed

```
Stage 0 against production            NOT performed
/data/kyri/work/g11bcn                NOT created
CINV-000003                           NOT allocated
Stages 1, 2, 3                        NOT executed
CRES for CINV-000003                  NOT created
the payload                           NOT executed
existing Fabric records               unaltered
Trust / Artifact authority            unaltered
Platform Evidence                     unaltered
runtime                               not reinstalled
sudoers                               not modified
Root Authority                        not mounted
ENG-0006 / TrustGateway cutover       not begun
```

Executable Stage 1, 2 and 3 ceremonies are deliberately **not** prepared. Stage
1's baseline is the runtime store as it stands immediately before it, and Stage
1 is what moves it; preparing Stage 1 now would pin a baseline that Stage 0's
acceptance does not change but that Stage 1's own execution would, and the
discipline is that executable authority for a stage waits until its predecessor
is permanently accepted.

## 14. Production no-mutation proof

Measured at the start and again at the end, after every rehearsal and every
sabotage:

```
/var/lib/kyri/fabric          a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5   unchanged
/etc/kyri/fabric              b6a5074a84f70713482efbdec860b392d4f1c3e618a084d5445d47eaab22a610   unchanged
/data/kyri/capability-runtime 159651ee6c98113f182b80cecdff5a83f5782df8ff8e16c6cf30ac91f0ea92fc   unchanged
capability-invocation.seq     2      capability-result.seq  1
/data/kyri/work/g11bcn        absent
CINV-000003                   absent
```

## 15. Known risks

**The window is the binding constraint.** Roughly three days remain and four
stages are left, one of which — Stage 3 — has failed before on this chain's
predecessors and is the only one that can demonstrate execution end to end.

**The rehearsal cannot exercise the container observation.** The two commands
that check the container baseline and the execution image run as
`kyri-capability` through `sudo runuser`, and this session has no passwordless
sudo. They are outside the gated block for exactly that reason, and the operator
must run and return them. The rehearsal's `execution_image_available: false` is
an artifact of the unprivileged rehearsal account, not a statement about
production; the image is pinned by id and the operator's `podman images` output
is what confirms it.

**Stage 0's guarantees are structural, not temporal.** It establishes the file
ownership, mode and link count `open_trusted_regular_file` will check at Stage
1, but those are checked again on the descriptor at Stage 1 — which is the
protection that matters, since anything can happen to a pathname in between.

**A green Stage 0 says nothing about Stage 3.** The first invocation's Stage 2
returned rc=0 and Stage 3 was the step that failed. Each stage is its own
acceptance.

## 16. Readiness for CINV-000003

The Stage 0 ceremony is committed, gated four times, rehearsed whole, and proved
to fail closed at every stage with a stated reason. The payload is committed and
re-verified against the released canonicalizer. The chain it rests on is
complete and currently eligible.

What remains is the reviewer's verification of Stage 0 authority, and then a
single operator Stage 0 — which creates one directory and one file, outside every
governed store, and allocates nothing.
