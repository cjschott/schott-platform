# ENG-0005 G11-BC-O — CADV-000007 production write, verified; CINST-000006 prepared

**Status:** operator action required — CINST-000006 freeze only
**Production mutation by this checkpoint:** none

---

## 1. Source authority

```
branch      arch/eng-0005-execution-transition
HEAD        906b760dc0879364e53fb8ad285f2f15c155431d
origin      906b760dc0879364e53fb8ad285f2f15c155431d
worktree    clean; nothing staged, nothing untracked
```

The G11-BC-N report and its implementation commit are present at that HEAD.

---

## 2. Pre-write reviewed authority

Reviewed and accepted in G11-BC-N:

```
frozen body SHA-256   962555b33e62918f2fbd8dde9d6c26068de0c100436f125b0ba0072cbb6eb81d
bytes                 673
request digest        sha256:f3fe5fa5960f0a623e7da2cd2be860136b039676f1536a4805fec38f2328de62
pre-write aggregate   8f1df4b739ca5dd416fc90fba97401eda7996da22f7b145d0be4d69c46258add
```

---

## 3. Frozen operator input, as it stands

```
/etc/kyri/fabric/cadv-000007.json
root:cschott  0640  673 bytes
sha256 962555b33e62918f2fbd8dde9d6c26068de0c100436f125b0ba0072cbb6eb81d   ✔ matches reviewed
```

---

## 4. Final preflight

As recorded by the reviewer, and consistent with the persisted record:

```
outcome                preflight
would_accept           true
predicted_record_id    CADV-000007
destination_exists     false
mutated                false
rehearsal_reason       null
request_digest         sha256:f3fe5fa5960f0a623e7da2cd2be860136b039676f1536a4805fec38f2328de62
```

---

## 5. Production write result

```
outcome        accepted
reason         null
record_id      CADV-000007
record_kind    capability-advertisement
request_digest sha256:f3fe5fa5960f0a623e7da2cd2be860136b039676f1536a4805fec38f2328de62
request_id     g11bcn-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000006
```

---

## 6. Persisted CADV-000007 semantics

Read back from the live store through the released `inspect` CLI:

| field | value |
| --- | --- |
| `advertisement_id` | CADV-000007 |
| `capability_host_id` | CHOST-0001 |
| `capability_package_id` | CPKG-0001 |
| `contract_id` | CCON-0001 |
| `satisfied_contract_versions` | `['1.0.0']` |
| `advertised_resource_profile` | `{'architecture': 'x86-64'}` |
| `observed_at` | 2026-09-19T06:00:00-05:00 |
| `valid_until` | 2026-09-23T06:00:00-05:00 |
| `supersedes` | CADV-000006 |
| `reason_category` | supersession |
| `recorded_at` | 2026-09-19T06:00:00-05:00 |
| `actor` | CHOST-0001 |
| `request_digest` | `sha256:f3fe5fa5…` ✔ matches reviewed |

CADV-000007 is the **current advertisement head**: the chain runs
CADV-000001 → … → CADV-000006 → CADV-000007, and nothing supersedes it.

---

## 7. Persisted YAML digest

```
/var/lib/kyri/fabric/capability-advertisements/CADV-000007.yaml
sha256 24689fba6e1652e8adecb63eb0c1dabb2e263456067ad4ed0df843914d098d9c   ✔ matches reviewer
```

---

## 8. Sequence transition

```
capability-advertisement.seq   6 -> 7
capability-instance.seq        5   unchanged
capability-route.seq           5   unchanged
capability-selection.seq       3   unchanged
```

Record counts: advertisements 7, instances 5, routes 5, selections 3.

---

## 9. Production mutation accounting

Not inferred from pathnames or sizes. Equal-size sequence replacement is
possible — `capability-advertisement.seq` is 2 bytes before and after — so the
accounting is done by **content**, and by reconstruction rather than by
enumeration.

The live store was copied, `CADV-000007.yaml` removed from the copy, and
`capability-advertisement.seq` rewound to `6`. The canonical aggregate of that
reconstruction is:

```
8f1df4b739ca5dd416fc90fba97401eda7996da22f7b145d0be4d69c46258add
```

which is exactly the reviewed pre-write aggregate. Since the aggregate is a
hash over every file's content, reproducing it proves that **no other file in
the store differs by a single byte**. The complete production mutation was
therefore:

1. creation of `capability-advertisements/CADV-000007.yaml`;
2. advancement of `capability-advertisement.seq` from `6` to `7`.

Both are within the released `register-advertisement` write contract. No
unexpected mutation.

The post-write aggregate, derived with the same canonical command G11-BC-N
used, is:

```
3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28
```

---

## 10. Fabric validation

```
python3 -m tools.fabric.cli validate --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000

status    reported
findings  []
counts    advertisement 7, instance 5, route 5, selection 3,
          contract 1, definition 1, host 1, package 1
```

---

## 11. Trust validation

```
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

valid     true
problems  []
counts    authority 1, record 2, decision 2, lineage 3, evidence 7, audit 4
```

TREC-000001 (host) and TREC-000002 (package) remain the governing records.

---

## 12. No mutation outside Fabric

The CADV-000007 record landed at `2026-09-19 11:34:05 -0500`. Every other
authority's newest file predates that instant, so none of them was touched by
the write:

| authority | newest mtime | aggregate |
| --- | --- | --- |
| `/usr/lib/kyri/python` (runtime) | 2026-09-15 07:03 | `70011c72f8a1c9c4f29111c6ae0f6caa6c8ece6973611a64d0664e437f58e793` |
| `/var/lib/kyri/evidence` (Platform Evidence) | 2026-08-25 10:04 | `62c875851b83ca0d53c8b82469709be530cc6dad2957bb766fdb65fc2b5dc507` |
| `/var/lib/kyri/artifacts` (Artifact authority) | 2026-08-24 15:32 | `ef4297c611a2dd824f1c1e4960e64304f72b04d77c0f5f20dd650b0b3eb410df` |
| `/var/lib/kyri/trust` | 2026-08-26 12:49 | validated above |
| `/var/lib/kyri/implementation-authority` (Root Authority) | 2026-08-14 15:37 | **not mounted** |
| `/data/kyri/capability-runtime` | 2026-09-13 12:57 | cinv.seq 2, cres.seq 1 |

Root Authority has no mount entry. The runtime was not reinstalled. The three
aggregates are recorded here so later checkpoints can compare against a number
rather than a timestamp.

---

## 13. The fresh authority window, at the current wall clock

```
now          2026-09-19T11:42:32-05:00
observed_at  2026-09-19T06:00:00-05:00
valid_until  2026-09-23T06:00:00-05:00
remaining    90h 17m
```

Open, with the whole remaining chain — CINST-000006, CROUTE-0006, CSEL-000004
and CINV-000003 Stages 0 to 3 — to fit inside it. That is a far wider margin
than the G11-BC-M chain ever had.

---

## 14. CINST-000006, prepared

### 14.1 The body was re-derived, not trusted

The G11-BC-N report records CINST-000006's **digest and byte count and nothing
else** — the body itself was never committed. It is the same gap that lost the
Option-B payload, and it is noted again in §16.

So the body was re-derived from first principles: the shape of the accepted
`/etc/kyri/fabric/cinst-000005.json`, the semantics fixed by G11-BC-N, and the
established 15-minute checkpoint ladder. The derivation stands or falls on the
digest:

```
bytes   1269     ✔ reviewed 1269
sha256  6746234a2b1293052c223ff4a3e253286129ddf58b9d8397d1ecf4d04175e162   ✔ reviewed
```

It is also byte-identical to the surviving G11-BC-N rehearsal copy — two
independent derivations agreeing.

`admitted_until` 2026-09-23T06:00:00-05:00 equals CADV-000007's `valid_until`
and does not exceed it. No reviewed field had to change.

### 14.2 Rehearsal

Against a scratch copy reproducing production exactly
(`3bcb5779…`), with live Trust and Evidence read-only:

```
preflight   outcome preflight, would_accept true, mutated false,
            destination_exists false, rehearsal_reason null,
            predicted_record_id CINST-000006,
            request_digest sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372
scratch     outcome accepted, record_id CINST-000006,
write       capability-instance.seq 5 -> 6
chain       CINST-000005 -> CINST-000006, lifecycle admitted, CINST-000006 is HEAD
eligibility 12/12 now; 12/12 at 2026-09-23T05:59; fails closed at 06:00
```

The allocated identity is CINST-000006, not merely the predicted one.
Production was byte-identical before and after.

### 14.3 The artifact

```
provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt
```

**On the filename.** Every artifact here takes the label of the `request_id`
prefix of the body it carries: `g11-bc-m-cinst-000005` carries `g11bcm-`,
`g11-bc-n-cadv-000007` carries `g11bcn-`. This body was reviewed in G11-BC-N
and says `g11bcn-`, and a reviewed byte is not edited to suit a filename.
G11-BC-O is the checkpoint that prepared the artifact — which is what this
report is for. The label names the authority the body belongs to, which is what
a reviewer matches on.

It pins the reviewed digest, byte count, request digest and predicted identity;
the post-CADV baseline `3bcb5779…`; `/etc/kyri/fabric/cadv-000007.json` as the
required predecessor input; and refuses by name both the accepted CINST-000004
input (`5d268f70…`) and the accepted CINST-000005 input (`850af136…`) — the
latter being the dangerous one, since it is the immediate predecessor, it looks
current, and its admission window closed at 2026-09-19T06:00:00-05:00.

### 14.4 Two gates, both before the install

**Gate 1 — wall clock.** The admission window is read out of the rendered body;
the governing advertisement window is read out of the live store through the
released `inspect` CLI. Neither is restated as a constant. It requires
`observed_at <= now < valid_until`, `now < admitted_until`, and
`admitted_until <= valid_until`.

**Gate 2 — current eligibility.** A window being open does not mean the
instance is admissible. The block copies production, applies the candidate to
the copy, and runs the released `compute-eligibility` at `$(date -Is)`,
requiring `eligible true` with no unmet conditions. The copy is discarded;
production is never touched. This is the only context in which CINST-000006
exists to be judged before it is written.

Both gates were exercised in isolation. Gate 1 accepts against the live
CADV-000007 and **refuses** when handed the expired CADV-000006 window — the
precise failure that let the withdrawn G11-BC-M CSEL artifact through.

### 14.5 The suite

136 assertions. Four independent mutation tests confirm the new rules are not
vacuous — each is caught on its own:

| mutation | caught by |
| --- | --- |
| drop `--preflight` from the production call | *runs admit-instance against production 1 times, 1 without --preflight* |
| remove the eligibility gate | *does not recompute current eligibility* / *does not evaluate at the current clock* |
| hardcode the window as a date literal | *the gate restates a window as a constant* |
| remove the wall-clock gate | *has no current-time freshness gate* |

The preflight rule is now scoped to **production** rather than counting
occurrences: a block may run its subcommand against a scratch copy — the
eligibility gate must — but may touch `/var/lib/kyri/fabric` exactly once, and
only with `--preflight`. Continuation lines are joined first so each invocation
is judged whole.

---

## 15. Actions not performed

Not frozen, not written, not created, not allocated, not altered:

- CINST-000006 was **not** frozen into `/etc/kyri/fabric` and **not** written to
  production;
- CROUTE-0006 and CSEL-000004 executable freeze artifacts were **not** prepared
  — their production baselines do not exist yet;
- CINV-000003 was not allocated; nothing was staged, invoked, executed or
  recovered;
- no immutable Fabric record was altered;
- Trust, Artifact authority, Platform Evidence, sudoers and the installed
  runtime were not modified; Root Authority was not mounted;
- no TrustGateway cutover; ENG-0006 not begun.

---

## 16. Readiness, and one thing still open

CINST-000006 is ready for the operator freeze. The artifact is committed, the
body renders to the reviewed digest from the committed file, both gates are
proved in both directions, and the whole suite is green from a clean clone.

**Still open:** the CROUTE-0006 and CSEL-000004 bodies exist as digests in the
G11-BC-N report and as bytes nowhere in the repository. Their executable
artifacts cannot be prepared yet — their baselines do not exist — but that is a
reason to withhold the *freeze block*, not the *body*. This checkpoint had to
re-derive CINST-000006 from first principles for exactly this reason, and it
only worked because the derivation could be checked against a reviewed digest.
Recommend committing the two remaining bodies as inert reviewed inputs at the
next checkpoint, the way the CINV-000003 payload now is.

---

## 17. Write plan

```
 1  freeze  CADV-000007   done
 2  write   CADV-000007   done, accepted, verified above
 3  freeze  CINST-000006  baseline 3bcb5779...   <- prepared, awaiting operator
 4  write   CINST-000006  -> reviewer accepts
 5  freeze  CROUTE-0006   baseline = aggregate after step 4
 6  write   CROUTE-0006   -> reviewer accepts
 7  freeze  CSEL-000004   baseline = aggregate after step 6
 8  write   CSEL-000004   -> reviewer accepts
 9  review  the committed CINV-000003 payload
10  CINV-000003 Stages 0-3, each separately authorised
```

Freeze → reviewer → write → reviewer → next object. Unchanged.
