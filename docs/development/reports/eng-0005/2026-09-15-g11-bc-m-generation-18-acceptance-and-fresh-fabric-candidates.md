# ENG-0005 G11-BC-M — Generation 18 accepted; the Fabric chain re-prepared fresh

**Checkpoint:** G11-BC-M (acceptance + preparation only)
**Date:** 2026-09-15
**Branch:** `arch/eng-0005-execution-transition`

Generation 18 is installed and accepted from its own bytes. The guard it exists
to deploy was re-proved through the **installed** library, not the repository.

The G11-BC-J Fabric candidates are superseded and four fresh bodies are prepared
in their place. Nothing was written: no Fabric record, no CINV, no CRES, no
execute, no recover, no Trust, sudoers, helper, image or handoff change.

---

## 1. Generation 18, accepted from installed bytes

```
GEN18_INSTALLED_ACCEPTED=YES
```

| required | measured |
| --- | --- |
| `tools/capability/evidence.py` | `a571ad02ace56dbb93a5cc9385a4b2cca4e5c1922fa16bfa9f59848a25a386f6` ✔ |
| `tools/capability/coordinator.py` | `acb80cb93084b2b196d6b806b278128458be8947a9575eac7c7c509e9f045585` ✔ |
| mode / owner | both `0444 root:root` ✔ |
| helper compatibility | `compatible` ✔ |
| blocking | 0 ✔ |
| `supervision_ready` | `true` ✔ |
| library object count | 81 — the declared 80 plus the one helper-ceremony creation, unchanged |
| Fabric aggregate | `3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b` — identical to G11-BC-J |
| Trust aggregate | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` — unchanged |

### 1.1 `HOST_GENERATION=18`, derived rather than asserted

All **46** installed modules under `/usr/lib/kyri/python/tools/capability/` were
compared against the reviewed Generation-18 authority
`88a1e484f063ad0c4bb5d05ddac6de2df623491c`:

```
46 installed modules compared against 88a1e484f063
  (no differences)
```

At G11-BC-L the same comparison showed exactly two differences — the two objects
this generation moves. There are now none. The host is at Generation 18 because
its bytes are the authority's bytes, not because a ceremony said so.

### 1.2 Grants and sudoers

```
-r--r----- root:root  482  /etc/sudoers.d/kyri-exec-launch
-r--r----- root:root  487  /etc/sudoers.d/kyri-exec-reconcile
```

Both execution grants present at their original mtimes; **no
`kyri-exec-verify`** — the verification grant is absent as required; no other
`kyri-*` grant. Generation 18 touched none of them, and neither
sudoers-pinned entrypoint is a matrix row.

---

## 2. The guard, proved from installed code

Driven through `/usr/lib/kyri/python`, with the loaded modules' own paths and
digests printed so there is no doubt which code answered:

```
coordinator loaded from: /usr/lib/kyri/python/tools/capability/coordinator.py
            sha256     : acb80cb93084b2b196d6b806b278128458be8947a9575eac7c7c509e9f045585
evidence    loaded from: /usr/lib/kyri/python/tools/capability/evidence.py
            sha256     : a571ad02ace56dbb93a5cc9385a4b2cca4e5c1922fa16bfa9f59848a25a386f6
```

The invocation and result records are the **production bytes**, copied read-only
into a temporary store at `0400`:

```
modelled: CINV-000001.yaml 1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
modelled: CINV-000002.yaml 923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
modelled: CRES-000001.yaml 18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d

execute(CINV-000002): TerminalResultExists
  "a terminal result already exists for CINV-000002 (CRES-000001,
   outcome provider-error); this adapter performs one attempt"
  boundaries reached: NONE
```

The recording stub's single method stands for the whole forbidden sequence —
helper launch, privileged transition, container creation, provider start,
handoff ownership mutation — and is reached zero times.

```
CINV_000002_REEXECUTE_PREEXEC_REFUSAL_INSTALLED=PASS
```

And a first execution is not blocked:

```
execute(CINV-000003, no terminal result): boundaries ['PRIVILEGED LAUNCH/…: CINV-000003']
FIRST_EXECUTION_NOT_FALSE_BLOCKED=PASS
```

Production was not invoked.

---

## 3. Finality

| | |
| --- | --- |
| `CINV-000002.yaml` | `923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa` ✔ |
| `CRES-000001.yaml` | `18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d` ✔ |
| CINV sequence | 2 ✔ |
| CRES sequence | 1 ✔ |
| CINV-000002 | **SPENT_AND_RESOLVED** |
| CRES-000001 | **FINAL** |

Re-execution is not permitted, and as of Generation 18 that is enforced before
the privilege boundary rather than after the workload (§2).

---

## 4. Next identities

Read from the live sequence files, not inferred:

| counter | value | next |
| --- | --- | --- |
| `capability-advertisement.seq` | 5 | **CADV-000006** |
| `capability-instance.seq` | 4 | **CINST-000005** |
| `capability-route.seq` | 4 | **CROUTE-0005** |
| `capability-selection.seq` | 3 | **CSEL-000004** |
| `capability-invocation.seq` | 2 | **CINV-000003** |
| `capability-result.seq` | 1 | **CRES-000002** |

Confirmed a second time by inventory. The identities are unchanged from
G11-BC-J because no Fabric record was written; only the **bodies** are new.

### 4.1 The window

Fresh instants, anchored at already-elapsed times so the blocks can be run the
moment they are authorised (rendered at 07:05 local; the latest instant is
06:45):

```
CADV-000006   observed_at / recorded_at  2026-09-15T06:00:00-05:00
              valid_until                2026-09-19T06:00:00-05:00   (4 days)
CINST-000005  admitted_at / recorded_at / evaluated_at  2026-09-15T06:15:00-05:00
              admitted_until             2026-09-19T06:00:00-05:00
CROUTE-0005   recorded_at                2026-09-15T06:30:00-05:00
CSEL-000004   recorded_at / evaluated_at 2026-09-15T06:45:00-05:00
```

Four days is the accepted precedent (CADV-000004 and -000005 both used it) and
is not an escalation. Every instant is a **literal**, so the bodies do not decay
and the digests below are what an operator renders tomorrow — but the *lease*
does run from 2026-09-15T06:00, which is why §13 puts the whole sequence
immediately after acceptance.

`MAXIMUM_FABRIC_VALIDITY_POLICY` remains **OPEN** and does not block ENG-0005.

---

## 5. CADV-000006

| | |
| --- | --- |
| `supersedes` | CADV-000005 |
| `request_id` | `g11bcm-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000005` |
| **frozen file SHA256** | `223d6ec3dbcfa686d32be07d4b6d5b01613de04a14b6bb563f845442ab7348ec` |
| **bytes** | 673 |
| **request digest** | `sha256:ab8ba79975e440239bbeee90154dab7bf296a4e85a91152d85a2d748d6515ced` |

Preflight against an isolated copy of production: `would_accept true`,
`destination_exists false`, `predicted_record_id CADV-000006`.

---

## 6. CINST-000005

| | |
| --- | --- |
| `supersedes` | CINST-000004 |
| `advertisement_id` | CADV-000006 |
| `admission_decision_id` | `eng-0005-cinst-000005-admission` |
| binding root | CAPDEF-0001 / CCON-0001 / CPKG-0001 / CHOST-0001, versions `["1.0.0"]`, TREC-000002 + TREC-000001 |
| **frozen file SHA256** | `850af1361812ee04212c6c525a276868ae5ab81883291367ebc18cee91fda8da` |
| **bytes** | 1269 |
| **request digest** | `sha256:be0daf493301139aabb7ef6224b93203d744545665ef6f470a8d6236713ede8b` |

**Requested scope == effective scope**, compared field-for-field on the record
the rehearsal write actually produced:

```
requested: {"permitted_capabilities": ["CAPDEF-0001"],
            "permitted_data_classifications": ["internal"],
            "permitted_operations": ["execute"],
            "permitted_targets": ["HOST-0001"]}
effective: identical
verdict:   IDENTICAL -- no silent narrowing
```

**`admitted_until` equals the advertisement's `valid_until`** —
`2026-09-19T06:00:00-05:00`, the maximum the engine permits. Equality is
preferred, per the checkpoint, and nothing in the source or the accepted policy
gives a reason to admit for less than the advertisement stands.

---

## 7. CROUTE-0005

| | |
| --- | --- |
| `supersedes` | CROUTE-0004 |
| `route_version` | **5** |
| `candidate_instances` | `["CINST-000005"]` — the new live binding root and nothing else |
| **frozen file SHA256** | `6d8311e51560081a765bdb2bce5aacb1b0f296138198c272f26d3200de3f713a` |
| **bytes** | 678 |
| **request digest** | `sha256:c2ded2c50ee8cee42d9a18faaef85a03d697b136c160f2f25ab9589ff9169bfb` |

Eligibility was required to be fully green **before** the route was accepted,
evaluated at the route's own `recorded_at` with CADV-000006 and CINST-000005
applied to the copy:

```
eligible: True | unmet: [] | reasons: [] | 12 of 12 met
```

---

## 8. CSEL-000004

| | |
| --- | --- |
| route | CROUTE-0005 (version 5) |
| **frozen file SHA256** | `60857d684434657e6b26207308ba630d7007bf1564910d6fadcd91ba3f80dffd` |
| **bytes** | 605 |
| **request digest** | `sha256:86bd92d17cc06271b904be6db2355baa0434bfae7484f1afe10842430df2e479` |
| **`selected_instance_id`** | **`CINST-000005`** |

`would_accept: true` is not accepted alone. The preflight reports
`selected_instance_id` itself, so the freeze block pins the two facts
**independently**:

```
test "${DIGEST}"   = "sha256:86bd92d17cc06271b904be6db2355baa0434bfae7484f1afe10842430df2e479"
test "${SELECTED}" = "CINST-000005"
```

A selection that accepted but resolved to some other instance satisfies the
first and fails the second.

---

## 9. The payload — Option B, unchanged

**Every value recomputes identically to the accepted candidate.** Nothing is
stale, so no fresh payload was derived.

```
PAYLOAD_RAW_SHA256        9b7a603ca06da5b378a0b1d3a251fc4074f86192c61567109ec4687db003656f
PAYLOAD_RAW_BYTES         372
PAYLOAD_CANONICAL_DIGEST  be85d58fc410c9de2e501e4721a524b92b4a83865eb4be34db38346262b60749
PAYLOAD_CANONICAL_BYTES   343
PAYLOAD_OPERATION         verify-execution-boundary
```

The §9 condition — *"if any value changes due only to stale narrative/timestamps
tied to the old chain"* — is **not triggered**, and that is worth stating
precisely rather than assuming:

- The payload **carries no timestamp at all**, so lease age cannot reach it.
- It references **none** of `CINV-000002`, `CADV-000005`, `CINST-000004`,
  `CROUTE-0004`, `CSEL-000003` — checked token by token.
- The chain it names is `CADV-000006 / CINST-000005 / CROUTE-0005 / CSEL-000004`
  and `CINV-000003` — the identities prepared here, unchanged because no Fabric
  record was written and no counter moved.

The one thing that could be called stale is the `g11bcj-` label and the note's
"ENG-0005 G11-BC-J" prefix. Those name the checkpoint that **prepared and got
this payload accepted**, which is a true historical fact and not a reference to
the expired chain. Rewriting them would churn a digest the reviewer pinned in
this checkpoint's own header, for cosmetics. Left unchanged, deliberately.

---

## 10. The payload contract, reproved

Against the **installed** Generation-18 library and the governed package:

```
result_content from: /usr/lib/kyri/python/tools/capability/execution/result_content.py
OPERATIONS         : ('verify-execution-boundary',)
Fabric permitted_operations (CINST-000005): ['execute']
distinct namespaces: YES -- no shared member

coordinator admits the payload: verify-execution-boundary  digest be85d58f…
provider exit code: 0
result validates  : verify-execution-boundary | payload_digest be85d58f…
provider with the Fabric verb 'execute': refused, exit 1
```

```
PAYLOAD_PROVIDER_CONTRACT=PASS
```

Two closed vocabularies, sharing a field name and no members. Both are correct
simultaneously: `operation: execute` passes the Fabric scope gate on the CINV
while the payload carries `verify-execution-boundary` for the provider. The
governed package tree was left with no compiled member.

---

## 11. Operator observation block — read-only, run before CINV-000003

Not required for candidate preparation, and it was not run here: it needs the
execution identity's rootless Podman store, which this session has no privilege
for. It is part of the operator gate before any Stage 3.

```bash
# READ-ONLY. Run immediately before authorising CINV-000003 execution and
# return the complete output. Pulls nothing, builds nothing, removes nothing.
set -Eeuo pipefail

sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman images --no-trunc \
  --format '{{.ID}} {{.Repository}}:{{.Tag}}'
#   require: 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
#            localhost/kyri-capability-execution:g5
#   Do NOT pull, build, load or retag anything.

sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
#   require: NO kyri-CINV-* container
#   historical trackb-* may remain and must NOT be removed
```

---

## 12. The freeze blocks

Four blocks, each refusing its destination if it exists, rendering exact
reviewed bytes, checking digest and byte count, naming superseded bodies by
digest, installing only into `/etc/kyri/fabric`, running a read-only preflight,
and proving `/var/lib/kyri/fabric` byte-identical afterwards.

### 12.1 The named refusals are load-bearing, and that was verified

The G11-BC-J bodies are superseded but **not expired** — their window runs to
2026-09-17T19:00. Re-rendering the BC-J advertisement reproduces digest
`a55e1c38f237c45558b48f28c8b5d7084fa0d9df02cc5fb659d03e1b3a49013d`, and
preflighting it against a copy of production returns:

```
would_accept: true
predicted_record_id: CADV-000006
```

**The engine would accept it.** A stale paste is a live risk today, not a
theoretical one, and the named refusal is the only thing between it and an
immutable record carrying a lease that is two days used. Each block therefore
names both the superseded BC-J body and the accepted predecessor input.

### 12.2 CADV-000006

```bash
bash <<'FREEZE_CADV'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/cadv-000006.json
REVIEWED=223d6ec3dbcfa686d32be07d4b6d5b01613de04a14b6bb563f845442ab7348ec
REVIEWED_BYTES=673

# Bodies that are NOT this one, refused BY NAME. The first is the G11-BC-J
# candidate, superseded for lease age and STILL ACCEPTED BY THE ENGINE -- proven,
# not assumed.
SUPERSEDED_BCJ=a55e1c38f237c45558b48f28c8b5d7084fa0d9df02cc5fb659d03e1b3a49013d
SUPERSEDED_BCJ_DRAFT=3d9ed12316d94d114857e1068cf2a0ea74d9d1a0fd8468c9164bc81254ecfb75
ACCEPTED_CADV5=ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

sudo test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11bcm-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000005",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-15T06:00:00-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-15T06:00:00-05:00",
  "valid_until": "2026-09-19T06:00:00-05:00",
  "supersedes": "CADV-000005",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-15"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
case "${ACTUAL}" in
  "${SUPERSEDED_BCJ}")
    echo "REFUSE: this is the SUPERSEDED G11-BC-J candidate (lease age)"; rm -f "${TMP}"; exit 1 ;;
  "${SUPERSEDED_BCJ_DRAFT}")
    echo "REFUSE: this is the SUPERSEDED G11-BC-J 21:30 draft"; rm -f "${TMP}"; exit 1 ;;
  "${ACCEPTED_CADV5}")
    echo "REFUSE: this is the already-accepted CADV-000005 input"; rm -f "${TMP}"; exit 1 ;;
esac
test "${ACTUAL}" = "${REVIEWED}" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed ${REVIEWED}"; rm -f "${TMP}"; exit 1; }
test "$(wc -c < "${TMP}")" = "${REVIEWED_BYTES}" || {
  echo "REFUSE: rendered $(wc -c < "${TMP}") bytes, reviewed ${REVIEWED_BYTES}"; rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- frozen input ---\n'
sudo sha256sum "${DEST}"; sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"

printf '\n--- read-only preflight (NO Fabric write) ---\n'
cd /opt/schott-platform
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file cadv-000006.json --approved-directory /etc/kyri/fabric --preflight

printf '\n--- production Fabric must be byte-identical to before ---\n'
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
echo "expect 3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b  -"
FREEZE_CADV
```

Expected: `would_accept true`, `mutated false`, `predicted_record_id
CADV-000006`, `destination_exists false`, `request_digest sha256:ab8ba799…`.

### 12.3 CINST-000005 — committed as its own artifact

**Corrected after review.** This section originally gave CINST, CROUTE and CSEL
as a table of digests rather than as literal bodies and executable blocks. A
digest without the bytes it names is not a reviewable artifact: the 1269 bytes
existed nowhere in the repository, so nobody could re-render them and the freeze
block's own `test "${ACTUAL}" = "${REVIEWED}"` had nothing to check against.

The CINST-000005 body and its complete block are now committed at

```
provisioning/fabric/g11-bc-m-cinst-000005-freeze.txt
```

and `tests/test-fabric-cinst-000005-freeze-artifact.sh` renders the committed
heredoc and asserts the digest (`850af136…`), the byte count (1269), every
accepted authority field, and that both named refusals are distinct from the
reviewed body — so "the committed block produces the accepted body" is a checked
fact in CI rather than a claim here. 23 assertions.

The candidate itself is unchanged: same timestamps, same `request_id`, same
digest, same request digest. Rehearsed against scratch copies of the **current**
production Fabric and Trust — the ones with CADV-000006 written — returning
`predicted_record_id CINST-000005` and
`request_digest sha256:be0daf49…`.

One value did have to move. The block pins `/var/lib/kyri/fabric` unchanged at
**`e542651a4c6f2afd27b6c1141f75b6433f6f348267477608b24658710758c56b`**, not the
`3fa32b83…` in §12.2: CADV-000006 has since been written, and pinning the
pre-CADV aggregate would have made the block refuse every time.

### 12.4 CROUTE-0005 — committed as its own artifact

Committed once CINST-000005 was written and accepted, in the same shape as
§12.3:

```
provisioning/fabric/g11-bc-m-croute-0005-freeze.txt
```

The candidate is unchanged — `recorded_at 2026-09-15T06:30:00-05:00`,
`route_version 5`, `candidate_instances ["CINST-000005"]`, digest
`6d8311e5…` at 678 bytes, request digest `sha256:c2ded2c5…`. Rehearsed against a
scratch copy of the current stores: `predicted_record_id CROUTE-0005`,
`request_digest sha256:c2ded2c5…`, store unchanged.

Its baseline pin is **`712730063d90f83d86b097aefc7fca5df36a443c8c84a3ab67396611db70d38c`**
— the aggregate with CADV-000006 and CINST-000005 written and CROUTE-0005 not.
That is a different value from the CINST block's `e542651a…`, and necessarily
so: each block pins the store as it stands when that step runs. This is why the
artifacts are committed one step at a time rather than all at once, and the
suite now asserts that no two artifacts share a baseline.

Current eligibility was reconfirmed against the **live** Fabric at the route's
own reviewed instant, with the accepted CADV-000006 and CINST-000005 in place:
`eligible: True`, `unmet: []`, 12 of 12 conditions met.

### 12.5 CSEL-000004

Still tabular. It is step 10, and its baseline pin does not exist until
CROUTE-0005 is written — pinning anything now would bake in a value already
known to be wrong. It gets the same treatment when its step is reached:

| block | `DEST` | `REVIEWED` | bytes | superseded BC-J | accepted predecessor |
| --- | --- | --- | --- | --- | --- |
| CSEL | `/etc/kyri/fabric/csel-000004.json` | `60857d68…80dffd` | 605 | `0f2b38d360adc17bec48d8b4c6558eb0d4daf461ebcfad518c078025b2fdef93` | `700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e` |

The CSEL preflight adds `--trust-store-root /var/lib/kyri/trust` and will pin,
independently of the request digest:

```bash
SELECTED="$(… --preflight | python3 -c 'import json,sys; print(json.load(sys.stdin)["selected_instance_id"])')"
test "${SELECTED}" = "CINST-000005" || { echo "REFUSE: the selection resolved to ${SELECTED}"; exit 1; }
```

The bodies are exactly those rehearsed in §5–§8; the digests above are what
`sha256sum` returns for them.

---

## 13. The write plan — prepared, not authorised

No batching. Each record is frozen, written and **accepted** before the next is
prepared, so a refusal stops the chain at a reviewable point.

```
 1  freeze  CADV-000006      →  return the preflight output
 2  write   CADV-000006
 3  ACCEPT  CADV-000006      →  reviewer
 4  freeze  CINST-000005
 5  write   CINST-000005
 6  ACCEPT  CINST-000005     →  reviewer
 7  freeze  CROUTE-0005
 8  write   CROUTE-0005
 9  ACCEPT  CROUTE-0005      →  reviewer
10  freeze  CSEL-000004
11  write   CSEL-000004
12  ACCEPT  CSEL-000004      →  reviewer
13  Stage 0  the corrected payload at /data/kyri/work/g11bcm/
14  Stage 1  allocate CINV-000003        (expect rc=1; that is success)
15  Stage 2  authorise launch
16  Stage 3  execute                     ← §11 observation block runs first
```

Steps 4, 7 and 10 re-derive each body's digest against the record actually
written, because a freeze prepared before its predecessor exists is a freeze
against a store that has since moved.

---

## 14. Gaps left open

```
DURABLE_PROVIDER_DIAGNOSTICS_GAP=OPEN   — does not block CINV-000003
MAXIMUM_FABRIC_VALIDITY_POLICY=OPEN     — does not block ENG-0005
PAYLOAD_OPERATION_AUTHORITY_GAP=OPEN    — no authority cross-checks the payload's
                                          operation against Fabric; §10 and the
                                          regression suite are what stand in
```

Neither was implemented here.

---

## 14.1 The succession sweep held

Worth recording, because it is the first time this class has been tested by an
actual installation rather than discovered by one. G11-BC-L extended four
successor lists ahead of Generation 18 landing:

```
test-capability-execution-generation14-installer.sh
test-capability-execution-helper-ceremony.sh
test-capability-execution-generation13-packaging.sh
test-capability-execution-generation12-packaging.sh
```

The host has now moved to Generation 18, and **no host-only suite went red**.
Quick validation passed 116/116 against the new host with no edits. On the five
previous occasions this class surfaced, it surfaced as a red suite after an
installation; this time the installation was uneventful.

`generation13-packaging` was the one that would have broken: Generation 13's
declared targets for `evidence.py` and `coordinator.py` are exactly the digests
Generation 18 replaced, and no successor in its lists declared them.

---

## 15. Production non-mutation

| | required | measured |
| --- | --- | --- |
| `HOST_GENERATION` | 18 | 18 |
| `CINV-000002.yaml` | `923ff0d7…` | unchanged |
| `CRES-000001.yaml` | `18ba4c34…` | unchanged |
| CINV / CRES sequence | 2 / 1 | 2 / 1 |
| CADV / CINST / CROUTE / CSEL sequences | unchanged | 5 / 4 / 4 / 3 |
| CINV-000003, CRES-000002 | absent | absent |
| Fabric aggregate | unchanged | `3fa32b83…` |
| Trust aggregate | unchanged | `53605e4e…` |
| `/etc/kyri/fabric` | unchanged | 20 entries |
| sudoers | unchanged | two grants, no verify grant |

No Fabric write, no Trust write, no `execute`, no `recover`, no image change, no
sudoers change, no handoff change, no Podman call. Every mutating engine call
ran against a copy under the session scratch directory.

---

## 15.1 The lease, as it stands

```
now                 2026-09-18T07:17:37-05:00
CADV-000006 / CINST-000005 expire   2026-09-19T06:00:00-05:00
remaining           22h 42m
```

Not extended and not rewritten by this checkpoint. Everything still ahead — this
freeze, the route write and its acceptance, the CSEL freeze/write/acceptance,
and CINV-000003 Stages 0 to 3 — has to fit inside that. It is workable at the
cadence the chain has been moving, and it is no longer comfortable.

If the window closes first, the correct response is a fresh renewal, not an
extension: the records are immutable and the lease is the thing that says how
long the reviewer's judgement stands.

---

## 16. Next

Reviewer accepts these candidates → the operator runs **step 1 only** (freeze
CADV-000006) and returns its output → acceptance → step 4, and so on down §13.

The lease runs from 2026-09-15T06:00 and expires 2026-09-19T06:00. The whole
§13 sequence, including Stage 3, fits comfortably inside it if it starts now;
it does not if it waits.

Still prepared and unauthorised, independent of this: the G11-BC-G evidence
remediation.
