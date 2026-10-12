# G11-BC-P — the CINST-000006 freeze artifact failed live, and why

ENG-0005. 2026-09-19. Branch `arch/eng-0005-execution-transition`.

The operator executed the committed CINST-000006 freeze artifact. Both of its
gates were broken, and the first one failed **open**. No production write was
authorised and none occurred, but the artifact that G11-BC-O prepared and the
reviewer accepted could not have gated anything. This withdraws it as executable
authority, explains all three faults from first principles, proves each one by
running it, and replaces the two gates.

The reviewed CINST-000006 body is **unchanged**. The investigation found nothing
wrong with its bytes; the faults were entirely in the shell and Python that were
supposed to judge it.

---

## 1. Starting source and production authority

| | |
| --- | --- |
| HEAD at start | `b4d2df93493e3ed1e2331374898c6ce2aab2478e` |
| branch | `arch/eng-0005-execution-transition` |
| origin | same commit; tree clean |
| accepted prior report | `docs/development/reports/eng-0005/2026-09-19-g11-bc-o-cadv-000007-production-write-and-cinst-000006-preparation.md` |
| artifact under investigation | `provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt` |
| artifact blob at HEAD | `f4bea3ecac9d4a260c353e9ef8e1357839ce788e` |
| artifact sha256 at HEAD | `b2ec1da21174ad75c33d97a6ba433da5a32a3935a76e29a4e77a8b4114ac130f` |
| implementation commit | `e78c67857503daf877f9aaa9c5242c60011578d8` |
| corrected artifact sha256 | `a97c9f0d81928048aa65ea556118775c85f90a24d900ef2288bd95d32e2f28d9` |

Production, verified read-only before anything was touched:

```
/etc/kyri/fabric/cinst-000006.json                        absent
/var/lib/kyri/fabric/capability-instances/CINST-000006.yaml   absent
capability-instance.seq                                   5
capability-advertisement.seq                              7
capability-route.seq                                      5
capability-selection.seq                                  3
counts: CADV 7, CINST 5, CROUTE 5, CSEL 3
aggregate: 3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28
```

`fabric validate` reports no findings. `trust validate-store` reports
`"valid": true`, no problems. CADV-000007 is the advertisement head, persisted
sha256 `24689fba…d098d9c`, `valid_until 2026-09-23T06:00:00-05:00`, request
digest `sha256:f3fe5fa5…2328de62`.

Every authority outside Fabric matches the aggregate G11-BC-O recorded, so
nothing outside Fabric has moved since:

| authority | aggregate | agrees with G11-BC-O |
| --- | --- | --- |
| `/usr/lib/kyri/python` | `70011c72f8a1c9c4f29111c6ae0f6caa6c8ece6973611a64d0664e437f58e793` | yes |
| `/var/lib/kyri/evidence` | `62c875851b83ca0d53c8b82469709be530cc6dad2957bb766fdb65fc2b5dc507` | yes |
| `/var/lib/kyri/artifacts` | `ef4297c611a2dd824f1c1e4960e64304f72b04d77c0f5f20dd650b0b3eb410df` | yes |
| `/data/kyri/capability-runtime` | cinv.seq 2, cres.seq 1 | yes |
| Root Authority | not mounted | yes |

---

## 2. The operator command

```bash
cd /opt/schott-platform
sed -n '45,246p' provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt
```

and the printed block pasted into the shell. That is the ceremony this session
issued at the end of the preceding checkpoint, and it is what the operator ran.

---

## 3. The live failure

```text
--- current-time freshness gate ---
Traceback (most recent call last):
  ...
  advert = json.load(sys.stdin)["records"][0]
  ...
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)

--- current eligibility gate ---
  File "<string>", line 5
    print(f"eligible {d[\"eligible\"]} | ...)
                         ^
SyntaxError: unexpected character after line continuation character
...
REFUSE: CINST-000006 is not eligible at the current clock
```

The SSH session then closed, because the block runs under `set -Eeuo pipefail`
in the operator's own interactive shell and the inner `bash` exited nonzero.

Two things in that transcript matter more than the tracebacks.

**Gate 1 did not stop the block.** Its Python process died, and the next thing
printed is Gate 2's banner. The refusal handler attached to Gate 1 never ran.

**Gate 2's refusal is not a judgement.** "CINST-000006 is not eligible at the
current clock" is what the block prints when its eligibility *check* fails to
compile. The candidate's actual eligibility was never computed. The block
refused, which is the safe direction, but it refused for a reason that has
nothing to do with the candidate — and the same construct would have printed the
same sentence for an ineligible instance, an eligible one, or no instance at all.

---

## 4. No production or frozen-input mutation occurred

Measured after the live failure and again after every rehearsal in this
checkpoint, including the deliberately sabotaged ones:

```
/var/lib/kyri/fabric aggregate   3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28
                                 (identical to the accepted baseline)
/etc/kyri/fabric aggregate       aa4a2d00aa90f98c93823493b32fd9e4b34c31e2de5114aba9b8c5808ee87698
                                 (identical before and after)
/etc/kyri/fabric/cinst-000006.json                            absent
/var/lib/kyri/fabric/capability-instances/CINST-000006.yaml   absent
capability-instance.seq                                       5
```

This is not an inference from where the block stopped. The block stopped inside
Gate 2, which is *before* its `sudo install`, so no frozen input was created;
and Gate 2's only production-capable operation runs against a copy in a
temporary directory. Both facts are confirmed by aggregate rather than by
reading the control flow. `tests/test-fabric-freeze-cinst-000006-rehearsal.sh`
re-asserts all four lines above every time it runs.

---

## 5. Root cause — Gate 1

The committed construct:

```bash
GATE="$(python3 - "${TMP}" <<'GATE_PY'
...
advert = json.load(sys.stdin)["records"][0]
...
GATE_PY
<<<"${ADVERT}"
)" || { printf '%s\n' "${GATE}"; echo "REFUSE: ..."; rm -f "${TMP}"; exit 1; }
```

`python3 - "${TMP}" <<'GATE_PY'` is a complete command. Its heredoc body runs to
the `GATE_PY` terminator, and the command ends at the newline that follows
`<<'GATE_PY'`. The `<<<"${ADVERT}"` on the *next* line is therefore **not a
second redirection of `python3`**. It is a new command — one consisting of a
redirection and no words at all, which bash executes as a null command.

Two consequences, from that one fact.

`python3 -` reads its program from stdin, and stdin is the heredoc. By the time
the program runs, that stream is spent. `json.load(sys.stdin)` reads an empty
stream and raises `JSONDecodeError: Expecting value: line 1 column 1 (char 0)` —
the exact message the operator saw. The advertisement was never read by
anything: the here-string's data was opened as the null command's stdin and
discarded.

Reproduced, with a *valid* advertisement supplied:

```
File "<stdin>", line 4, in <module>
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
```

**Root cause:** the program source and the advertisement data were routed
through the same channel (stdin), and the construct intended to supply the
second one was parsed as a separate command.

---

## 6. Root cause — Gate 2

```bash
printf '%s\n' "${ELIG}" | python3 -c '
...
print(f"eligible {d[\"eligible\"]} | {met} of {len(d[\"conditions\"])} met | ...")
...
'
```

The program is inside **single quotes**. Bash performs no processing inside
single quotes, so the backslashes are literal and Python receives
`d[\"eligible\"]` inside an f-string expression. A backslash is not permitted
where the expression expects a quote, and the tokenizer reports it as a line
continuation:

```
  File "<string>", line 5
    print(f"eligible {d[\"eligible\"]} | ...)
                         ^
SyntaxError: unexpected character after line continuation character
```

Reproduced on this host (Python 3.12.3) with a valid, *eligible* result on
stdin: the fragment still exits 1, and the block still prints "CINST-000006 is
not eligible at the current clock".

**Root cause:** shell-level escaping was applied inside a context that does no
unescaping, producing Python that does not compile. The escaping was never
needed — the inner quotes are double, the outer are single, and they do not
collide.

---

## 7. Root cause — Gate 1's failure did not propagate

This is the security-relevant one, and it has the same origin as §5.

A command substitution takes the exit status of the **last command** it
contains. Inside `$( … )` there were two commands: `python3`, which exited 1,
and the word-less `<<<"${ADVERT}"` redirection, which exited 0. The last one
won, so `$( … )` reported success, `|| { … }` did not fire, and `set -e` saw
nothing wrong.

Isolated:

```
A: $(python3 -c 'sys.exit(7)')                     -> exit=7    status propagates
B: $(python3 -c 'sys.exit(7)'  <newline>  <<<"x")  -> exit=0    masked
C: <<<"data" as a command on its own               -> exit=0    null command
```

So a single misplaced here-string both prevented the gate from reading its
input *and* prevented the gate from being able to fail. Gate 1 could not have
refused anything, for any reason, in the committed form. It was not a weak gate;
it was not a gate.

**Root cause:** the gate's exit status was taken from a command substitution
whose final command was an unrelated null redirection, so the gate's own status
was discarded.

### 7.1 Why the suite did not catch any of this

`tests/test-fabric-freeze-artifacts.sh` passed 136 assertions over this
artifact. Two structural reasons:

1. It asserted the gate's **text** and executed the gate's **program** with argv
   it constructs itself. It never executed the shell construct that feeds the
   program — and all three faults live in that construct, not in the program.
2. Its regression loop selected a gated artifact with `break`, taking the first
   row with a gated window. That is **CADV-000007**, whose gate is
   single-channel (one file argument, no stdin data) and was sound. The
   CINST-000006 gate below it was never extracted and never run by anything.

Worse, the extraction shape the loop uses passes the window fixture as `argv[1]`
and leaves stdin inherited. Against a two-channel gate that crashes — so the
"refuses the expired window" assertion would have *passed for the wrong reason*,
reporting a refusal that was really a crash. A test that cannot distinguish a
refusal from a crash is not evidence about a gate.

Both are fixed in §9.

---

## 8. RED evidence

Captured against the committed bytes (blob `f4bea3ec…`) **before** any source
was modified.

### 8.1 The defects, reproduced directly

`RED 1/3` — the committed Gate-1 construct, handed a valid advertisement:

```
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
GATE variable contents: []
*** SENTINEL: CONTROL REACHED GATE 2 ***
outer block exit status: 0
```

`RED 2` — the committed Gate-2 fragment, handed a valid eligible result:

```
SyntaxError: unexpected character after line continuation character
REFUSE: CINST-000006 is not eligible at the current clock
gate-2 fragment exit status: 1
```

### 8.2 The new suites, run against the pre-correction artifact

`tests/test-fabric-freeze-gate-execution.sh` — **42 FAIL, 18 PASS**, including:

```
FAIL: gate 1 construct returned success on: an expired advertisement
FAIL: gate 1 construct failed silently: an expired advertisement
FAIL: gate 1 construct returned success on: inspect itself failing
FAIL: gate 1 construct did not refuse deterministically
FAIL: ...g11-bc-n-cinst-000006-freeze.txt: a here-string follows a heredoc terminator
FAIL: ...g11-bc-n-cinst-000006-freeze.txt: a backslash appears inside an f-string expression
```

`tests/test-fabric-freeze-cinst-000006-rehearsal.sh` — **12 FAIL, 22 PASS**,
reproducing the operator's transcript from the committed block and proving the
propagation defect at the block level:

```
FAIL: the whole block failed (status 1): ^ SyntaxError: unexpected character
      after line continuation character REFUSE: CINST-000006 is not eligible…
FAIL: gate 1: the governing advertisement has expired: gate 2 RAN after gate 1 failed
FAIL: gate 1: inspect itself fails: gate 2 RAN after gate 1 failed
FAIL: the gate-1 refusal was not deterministic
```

Production was verified unchanged during the RED runs as well.

---

## 9. The correction

Only the CINST-000006 artifact and the tests that judge it. The reviewed body,
the baseline pin, the named refusals, the required predecessor input, the
preflight-only production operation and the `g11-bc-n` label are untouched.

### 9.1 Gate 1

Two inputs, two channels. The rendered body is `argv[1]`, the live inspect
output is `argv[2]`, and stdin carries the program and nothing else. No command
in the gate takes a second input redirection.

The inspect call writes to its own file and is checked on its own line, so a
failure of the released CLI refuses rather than yielding an empty file. The gate
then runs as a plain command under `if !`, so its status is its own:

```bash
python3 -m tools.fabric.cli inspect … > "${GATE_ADVERT}" \
  || { echo "REFUSE: could not inspect CADV-000007 in the live store"
       rm -f "${TMP}"; exit 1; }

if ! python3 - "${TMP}" "${GATE_ADVERT}" <<'GATE_PY'
…
GATE_PY
then
  echo "REFUSE: current-time freshness gate failed"
  rm -f "${TMP}"; exit 1
fi
```

The program refuses by name on every failure mode rather than raising: an
unreadable or non-JSON input, an inspect result that is not exactly one record,
a record that is not CADV-000007, a body that does not bind CADV-000007, a
missing field, an instant that does not parse, and — new — an instant carrying
**no timezone offset**, which is refused rather than guessed. Any unhandled
error still exits nonzero on its own.

The window rules are unchanged in substance:

```
observed_at <= now < valid_until
now < admitted_until
admitted_until <= valid_until
```

### 9.2 Gate 2

The eligibility result is written to a file and read as `argv[1]`, the same
separation Gate 1 uses; the program arrives on a quoted heredoc, so bash does no
processing on it and there is no backslash anywhere in it. Every value is bound
to a plain name before it is formatted, so no f-string contains a quote or a
bracket in its expression part.

It requires `eligible is True`, `unmet == []` and a non-empty condition list,
reports the met count it actually counted, and refuses with a reason otherwise.
It too runs under `if !`.

### 9.3 The prose typo — non-behavioural

Line 24 read `3bcb577900fc...` for the abbreviated baseline; the digits are
transposed. It is a **comment**. The executable pin
`FABRIC_BEFORE=3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28`
was correct before this checkpoint and is unchanged. Corrected to `3bcb57790fc7…`
because the artifact was open. **This changed no behaviour.**

### 9.4 The tests

**`tests/test-fabric-freeze-gate-execution.sh`** (new, portable, 63 assertions).
Executes rather than reads. Keeps both G11-BC-O constructs verbatim and runs
them, so the live failure stays reproducible from the repository. Extracts the
live gates by marker and runs the Gate-1 *program* against 15 fixtures and the
Gate-1 *shell construct* against 7 failure injections, requiring every failure to
exit nonzero **and** not reach a sentinel standing for Gate 2. Runs the Gate-2
check against 6 fixtures. Asserts stage order on the artifact, and that both
gates run as plain commands under `if !`. Two structural detectors refuse the
returning shapes in every freeze artifact — and each detector is first run
against the shape it exists to catch, so a detector that has stopped detecting
fails here instead of passing quietly.

**`tests/test-fabric-freeze-cinst-000006-rehearsal.sh`** (new, host-only, 37
assertions). Runs the whole operator block, extracted between `bash
<<'FREEZE_CINST'` and `FREEZE_CINST`, against a fixture copied from the
production stores, with three substitutions and nothing else: the Fabric root,
the frozen-input root, and `FABRIC_BEFORE` (forced by the second — the aggregate
digests `sha256sum` output, which names absolute paths, so it is root-dependent
by construction). `sudo` is shimmed to run its arguments directly. Trust and
Evidence stay pointed at the real stores, which the block only reads. Then each
stage is sabotaged in turn and the suite asserts where control stopped.
Registered in `tests/host-only.manifest`.

**`tests/test-fabric-freeze-artifacts.sh`** (modified). The regression loop now
covers **every** gated row instead of breaking at the first, and detects each
gate's arity from the gate itself (`sys.argv[2]` present or not), building the
fixture shape that gate actually takes — so a two-channel gate is judged by its
refusal and not by a crash. The "reads its windows from authority" check counted
`fromisoformat(` call sites and demanded two; that is a proxy for the property,
not the property, and it punished the correct refactor — one parse helper called
four times reads more windows from authority than two open-coded calls and
scored worse. It now counts the window **fields** read out of data, scoped to
the gate program so a field named in a comment cannot stand in for one the gate
reads.

Both new suites are registered in `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml`. The validator checks its own step count against a
declared total and fails rather than printing a total it did not meet, so
adding two suites required re-measuring it: quick 117 → 119, full 142 → 144.
Both were measured by running the validator, not incremented on the assumption
that a new suite runs in both modes — which is what that file's own comment
asks for, because suites added to full mode are skipped in quick mode.

---

## 10. GREEN evidence

| suite | result |
| --- | --- |
| `test-fabric-freeze-gate-execution.sh` | 63 PASS, 0 FAIL |
| `test-fabric-freeze-cinst-000006-rehearsal.sh` | 37 PASS, 0 FAIL |
| `test-fabric-freeze-artifacts.sh` | 141 PASS, 0 FAIL |
| `test-capability-fabric.sh` | 538 PASS, 0 FAIL |
| `test-fabric-instance-admission-integrity.sh` | 38 PASS, 0 FAIL |
| `test-fabric-admission-dependency-bound.sh` | 44 PASS, 0 FAIL |
| `test-capability-invoke-current-eligibility.sh` | 49 PASS, 0 FAIL |
| `test-capability-invoke-preflight.sh` | 36 PASS, 0 FAIL |
| `test-capability-execution-payload-operation-contract.sh` | 13 PASS, 0 FAIL |
| `test-static.sh` | 840 PASS, 0 FAIL |
| `tools/dev/run-shellcheck.sh` | clean, exit 0 |
| `tests/test-docs-static.sh` | 993 PASS, 0 FAIL |
| `tools/dev/run-validation.sh --quick` | passed, 119/119 steps |
| `tools/dev/run-validation.sh` (full) | passed, 144/144 steps |

Three ShellCheck findings on the new suite are suppressed in-script with
justifications, per the workflow's stated policy: one `SC1003` (the trailing
backslash is a BRE literal, which is the point) and two `SC2016` (literal text
to find in the artifact, not expressions to expand).

---

## 11. The whole operator block, rehearsed

Against a fixture copied from the production stores, the corrected block runs to
completion:

```
ok  observed_at <= now < valid_until
ok  now < admitted_until <= valid_until
ok  eligible true, no unmet conditions
ok  CINST-000006 eligible at the current clock
ok  predicted_record_id CINST-000006
ok  request_digest      sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372
```

and the suite independently asserts of that run:

- the rendered block references no production Fabric or frozen-input path;
- the installed frozen input is `6746234a…4175e162`, 1269 bytes, mode 0640;
- the `admit-instance` stayed a preflight — `would_accept true, mutated false`;
- no instance record was written even in the fixture, and the fixture's
  `capability-instance.seq` is still 5.

Eligibility against a scratch copy of live production, computed independently of
the block: `eligible True | 12 of 12 met | unmet []`, matching the artifact's
EXPECTED footer.

The read-only portions were also exercised against live production: the released
`inspect` of CADV-000007 returns the window the gate reads, and `admit-instance`
plus `compute-eligibility` were run against a **copy** of the live store. No
`/etc/kyri/fabric/cinst-000006.json` was created. The operator freeze was not
performed.

---

## 12. Fail closed, by stage

Each case sabotages exactly one released command's output and asserts where
control stopped. "Gate 2 ran" is detected by Gate 2's own banner; "the install
ran" by the frozen input's existence.

| sabotage | exits nonzero | states a refusal | gate 2 runs | install runs | fixture store |
| --- | --- | --- | --- | --- | --- |
| gate 1: advertisement expired | yes | yes | **no** | **no** | byte-identical |
| gate 1: `inspect` itself fails | yes | yes | **no** | **no** | byte-identical |
| gate 2: candidate not eligible | yes | yes | yes | **no** | byte-identical |

An expired advertisement stops the block before Gate 2 and before the install on
**3 of 3** runs. At the construct level, the gate refuses an expired window on
**5 of 5** runs. Under the committed G11-BC-O artifact, both gate-1 rows above
read "gate 2 RAN after gate 1 failed".

The required statements hold, executably:

- **If Gate 1 fails, Gate 2 does not run and the install does not run.**
- **If Gate 2 fails, the install does not run.**

---

## 13. The CINST body is unchanged

Rendered from the corrected artifact's heredoc and compared byte-for-byte with
the body rendered from the committed artifact at HEAD:

```
bytes   1269      reviewed 1269
sha256  6746234a2b1293052c223ff4a3e253286129ddf58b9d8397d1ecf4d04175e162   reviewed
diff    (no output — byte-identical)
```

The request digest the preflight resolves is unchanged:
`sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372`, and
the predicted record id is `CINST-000006`.

Nothing in §5–§7 implicated the body. All three faults were in the machinery
around it.

---

## 14. Test totals

| | |
| --- | --- |
| new assertions added | 100 (63 gate-execution + 37 rehearsal) |
| freeze-artifact suite | 136 → 141 |
| suites added | 2 |
| suites modified | 1 |
| host-only suites declared | 34 → 35 |
| RED before correction | 42 FAIL (gate execution), 12 FAIL (rehearsal) |
| GREEN after correction | 0 FAIL in both |

---

## 15. Production no-mutation proof

Measured at the start of this checkpoint and again at the end, after every
rehearsal and every sabotage run:

```
/var/lib/kyri/fabric   3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28   unchanged
/etc/kyri/fabric       aa4a2d00aa90f98c93823493b32fd9e4b34c31e2de5114aba9b8c5808ee87698   unchanged
capability-instance.seq                                       5   unchanged
/etc/kyri/fabric/cinst-000006.json                            absent
/var/lib/kyri/fabric/capability-instances/CINST-000006.yaml   absent
CROUTE-0006, CSEL-000004, CINV-000003                         not created, not allocated
```

Trust, Platform Evidence, Artifact authority and the installed runtime match the
aggregates recorded in §1, so none of them was touched either. Root Authority
remains unmounted. No sudoers change, no runtime reinstall, no staging, no
invocation.

---

## 16. Known remaining risks

**The window is the binding constraint.** CADV-000007 expires
`2026-09-23T06:00:00-05:00`. The freeze, the write, CROUTE-0006, CSEL-000004 and
CINV-000003 Stages 0–3 all have to fit inside it, and one ceremony has already
been spent on a defect. Gate 1 refuses rather than extends when it closes.

**The rehearsal is not the production run.** It substitutes two roots and shims
`sudo`. What it cannot exercise is the privileged `install` as root and the real
`/etc/kyri/fabric` permissions; those remain first exercised in the live
ceremony. The substitutions are mechanical and asserted (the rendered block is
checked to contain no production path), but they are substitutions.

**`FABRIC_BEFORE` is root-dependent by construction**, because the aggregate
digests `sha256sum` output including absolute paths. That is correct for pinning
a specific store and is why the rehearsal must compute its own. Anyone reusing
this pattern under a different root must do the same or the check will fail for
the wrong reason.

**The structural detectors are narrow on purpose.** They refuse two specific
spellings that cost a ceremony. They do not make shell quoting safe in general,
and no test in this repository does. The defence that generalises is §9.4's
first paragraph: gates are executed, not read.

**Gate 2 still copies the whole production store per run.** It is correct and
it is not cheap; on a larger store the freeze would get slow. Not a problem at
5 instances.

---

## 17. The corrected operator ceremony

**Step 1 — confirm you are executing the reviewed artifact.**

```bash
cd /opt/schott-platform
git rev-parse HEAD                    # expect e78c67857503daf877f9aaa9c5242c60011578d8
                                      # (or a later commit that does not touch this artifact)
git status --porcelain                # expect no output
sha256sum provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt
                                      # expect a97c9f0d81928048aa65ea556118775c85f90a24d900ef2288bd95d32e2f28d9
```

**Step 2 — print the block.** The line range has moved; the header is
commentary and is not pasted.

```bash
sed -n '45,375p' provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt
```

**Step 3 — paste that output into the shell**, as-is, in one paste. It will
prompt for sudo.

Expected:

```
gate 1         observed_at <= now < valid_until, now < admitted_until <= valid_until
gate 2         CINST-000006 eligible, 12 of 12, against a copy of production
frozen input   6746234a2b1293052c223ff4a3e253286129ddf58b9d8397d1ecf4d04175e162
               /etc/kyri/fabric/cinst-000006.json  root:cschott  640  1269 bytes
preflight      would_accept true, mutated false, destination_exists false,
               predicted_record_id CINST-000006,
               request_digest sha256:c9444952…
fabric         3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28
```

Any line beginning `REFUSE:` means stop and return the console output. Do not
retry and do not edit the artifact. The `admit-instance` **write** is a separate
authorisation and is not in this block.

---

## 18. Actions not performed

- `/etc/kyri/fabric/cinst-000006.json` was **not** installed;
- CINST-000006 was **not** written to production;
- CROUTE-0006 and CSEL-000004 were **not** created or written, and no executable
  freeze artifact was prepared for either — their baselines do not exist;
- CINV-000003 was **not** allocated; nothing was staged or invoked;
- no immutable Fabric record was modified;
- Trust, Artifact authority and Platform Evidence were **not** altered;
- the runtime was **not** reinstalled; sudoers was **not** modified; Root
  Authority was **not** mounted;
- ENG-0006 was **not** begun; no TrustGateway cutover.

The G11-BC-O follow-up requirement — preserving the reviewed CROUTE-0006 and
CSEL-000004 bodies as inert committed inputs — is **not** discharged here. It
remains open for its own checkpoint, unchanged by this correction.
