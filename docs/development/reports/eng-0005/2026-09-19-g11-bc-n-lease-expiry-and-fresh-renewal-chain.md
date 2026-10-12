# ENG-0005 G11-BC-N — lease expiry, artifact withdrawal, and the fresh renewal chain

**Status:** operator action required — CADV-000007 freeze only
**Production mutation:** none

---

## 1. What happened

The G11-BC-M authority expired at `2026-09-19T06:00:00-05:00` with the chain
three records in and the fourth unwritten. CADV-000006, CINST-000005 and
CROUTE-0005 are written and accepted; CSEL-000004 was never frozen, CINV-000003
was never allocated.

Eligibility of CINST-000005 at the current clock:

```
eligible  False
unmet     ['ELIG-6', 'ELIG-7']
reasons   ['advertisement-not-fresh', 'admission-window-expired']
met       10 of 12
```

Those are the two expected failures and there are no others. CROUTE-0005 is
still a valid record; it simply routes to an instance nothing can now admit.

---

## 2. The artifact that did not fail closed

This is the substantive finding of the checkpoint, and it was found by
rehearsing rather than by reasoning.

The committed G11-BC-M CSEL-000004 freeze artifact was rehearsed against
production **after** the lease expired. Every one of its seven pins still held,
and its preflight returned `would_accept true` with
`selected_instance_id CINST-000005`.

The cause is not a defect. The selection carried a reviewed `evaluated_at` of
`2026-09-15T06:45:00-05:00`, and the Fabric engine judges each request at the
instant the request names. `tools/fabric/admission.py` says why, in terms:

> Reading the current time here would make the verdict depend on when the
> request was replayed rather than on what it says, so a body accepted once
> could be refused later without a single byte of it changing.

That is the correct rule for an append-only store. Its consequence is that
**nothing inside the engine will ever tell an operator that the authority they
are about to act under has lapsed.** A backdated `evaluated_at` kept an expired
chain executable, and the only thing standing between that and an immutable
record was a human remembering the date.

Left in place the block would have installed a frozen input binding to an
expired instance and then blocked its own replacement by occupying
`/etc/kyri/fabric/csel-000004.json`.

**Its siblings did not need withdrawing.** The CINST-000005 and CROUTE-0005
artifacts refuse at their first step, because both records are written and
`sudo test ! -e "${DEST}"` finds the destination occupied. The CSEL artifact was
reachable precisely because it was the one step that never completed.

---

## 3. The withdrawal

`provisioning/fabric/g11-bc-m-csel-000004-freeze.txt` is now a tombstone. It
exits nonzero before reaching any command, states that the G11-BC-M authority
expired, states that it must not be used, and names the commit where the
reviewed bytes remain recoverable:

```
77670b71749cd051cb1a0825ca93163dda04b982
git show 77670b7...:provisioning/fabric/g11-bc-m-csel-000004-freeze.txt
```

Verified: that path at that commit still renders the reviewed body at 605 bytes,
`60857d68…`. The historical evidence is intact and attributable; what is gone is
the executable copy. The suite additionally proves that **no** file under
`provisioning/fabric` renders those bytes any more.

---

## 4. The current-time gate

Every G11-BC-N artifact carries an independent wall-clock check ahead of its
install:

```
observed_at <= NOW < valid_until
```

which is the same half-open interval the engine applies at
`observed_at <= recorded_at < valid_until`, evaluated against the operator's
clock instead of the pinned instant. Three properties matter:

- **It reads the window out of the rendered body**, not from a restated
  constant, so it cannot drift from the bytes it guards.
- **It precedes the install.** A refusal after the file is in
  `/etc/kyri/fabric` has already left a stale frozen input in the destination.
- **The pinned `recorded_at` / `evaluated_at` are unchanged.** This is operator
  safety layered on top, not a second eligibility model.

Where an instance exists to judge, later artifacts add `compute-eligibility` at
the current clock on top of the window check. CADV-000007 does not: CINST-000006
does not exist until step 3. For CSEL-000004 the suite will require **both** the
reviewed preflight resolving `selected_instance_id CINST-000006` **and** current
eligibility of CINST-000006 at the operator's clock.

The regression that proves it works runs the committed gate against the expired
G11-BC-M window and requires a refusal — and against an open window and requires
acceptance, so the gate cannot degrade into a brick. A mutation test confirmed
the suite fails when the gate is stripped.

---

## 5. The fresh chain

Identities verified from live sequence files, not assumed:

| | sequence | next |
| --- | --- | --- |
| advertisement | 6 | **CADV-000007** |
| instance | 5 | **CINST-000006** |
| route | 5 | **CROUTE-0006** |
| selection | 3 | **CSEL-000004** |

Window `2026-09-19T06:00:00-05:00` → `2026-09-23T06:00:00-05:00`, beginning
exactly where the old claim ended. Preserved unchanged: CAPDEF-0001, CPKG-0001,
CHOST-0001, CCON-0001, version 1.0.0, operation `execute`, classification
`internal`, target HOST-0001, locality `local-only`, TREC-000001/TREC-000002.

| record | bytes | file SHA256 | request digest |
| --- | --- | --- | --- |
| CADV-000007 | 673 | `962555b3…` | `sha256:f3fe5fa5…` |
| CINST-000006 | 1269 | `6746234a…` | `sha256:c9444952…` |
| CROUTE-0006 | 678 | `cd7a1f9a…` | `sha256:4a81d1c7…` |
| CSEL-000004 | 605 | `d04171c5…` | `sha256:2856ff77…` |

All four rehearsed as a staged chain against scratch copies: each preflighted,
then written into the scratch store so the next had its predecessor. Resolution:
`route_id CROUTE-0006`, `route_version 6`, `considered ['CINST-000006']`,
`excluded []`, `selected CINST-000006`.

CINST-000006 eligibility in the rehearsal store: **12/12 now**, **12/12 at
05:59 on 23 Sep**, and fails closed at exactly **06:00** with the same two
reasons. The half-open window is correct at both ends.

**CSEL-000004 keeps its identity and changes its bytes** — `d04171c5…`, not
`60857d68…`. The old digest must be refused by name wherever it appears.

---

## 6. The CINV-000003 payload, committed as bytes

The reviewed Option-B payload could not be recovered. Its digests were recorded
in three reports; its 372 bytes were never committed and exist nowhere on this
host — searched by content hash across the repository, `/data/kyri` and the
operator home. It was regenerated for the new chain and re-reviewed.

This time the bytes are committed, at
`provisioning/execution/g11-bc-n-cinv-000003-payload.json`:

```
operation          verify-execution-boundary
raw bytes          300
raw sha256         d01faccc67b83c60051348422861c121211a4079f7748572bad0a4882575a569
canonical bytes    271
canonical digest   591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
```

The canonicalizer was validated before it was trusted: recomputing the on-disk
CINV-000002 payload reproduces that record's stored `payload_digest`
`sha256:e2914a90…` exactly. The suite now asserts all five values.

The same lesson as the freeze artifacts, in a second place: *a digest without
its bytes is not a reviewable artifact.*

---

## 7. What is committed, and what deliberately is not

Committed: the **CADV-000007** freeze artifact only, pinned to the current
production baseline `8f1df4b739ca…`.

Not committed: executable CINST-000006, CROUTE-0006 and CSEL-000004 freeze
artifacts. Each pins the store as it stands when its step runs, and those three
aggregates do not exist yet. Committing them now would bake in three values
already known to be wrong — the same discipline that produced the one-step-at-a-
time cadence in G11-BC-M.

---

## 8. The write plan

```
 1  freeze  CADV-000007   baseline 8f1df4b739ca...   <- prepared, awaiting review
 2  write   CADV-000007   -> reviewer accepts
 3  freeze  CINST-000006  baseline = aggregate after step 2
 4  write   CINST-000006  -> reviewer accepts
 5  freeze  CROUTE-0006   baseline = aggregate after step 4
 6  write   CROUTE-0006   -> reviewer accepts
 7  freeze  CSEL-000004   baseline = aggregate after step 6
 8  write   CSEL-000004   -> reviewer accepts
 9  review  the committed CINV-000003 payload
10  CINV-000003 Stages 0-3, each separately authorised
```

Freeze → reviewer → write → reviewer → next object. Unchanged.

---

## 9. Note for the reviewer

Ruling 7 gave the canonical digest as
`591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b` — 63 hex
characters. The value is 64; the trailing `3` was dropped in transcription. The
committed artifact and the suite both carry the full
`591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3`, which is
what the released canonicalizer returns for the accepted bytes. The raw digest
and both byte counts in that ruling were correct.

The four-day window was kept as directed and not widened.
