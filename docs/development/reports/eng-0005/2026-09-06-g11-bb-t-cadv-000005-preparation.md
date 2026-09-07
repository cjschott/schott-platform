# ENG-0005 G11-BB-T — CADV-000005 preparation

**Status: `CADV-000005` is prepared, digest-pinned and rehearsed against
production read-only. It is NOT written.** Nothing under `/var/lib/kyri/fabric`
or `/etc/kyri/fabric` was created or changed by this checkpoint, and no Fabric
sequence was spent.

```
CADV_ID                  CADV-000005          supersedes CADV-000004
CADV_PREFLIGHT           PASS                 would_accept true, mutated false
PRODUCTION_CADV_WRITE    NOT_PERFORMED
FABRIC_MUTATION          NONE
PREMATURE_SELECTION_AUTHORISED   NO
```

Branch `arch/eng-0005-execution-transition`.

---

## 0. Interruption recovery

The first attempt at this checkpoint was cut off mid-run by a connection
failure. State was reconstructed from durable evidence before anything else,
and **nothing had escaped**:

```
git status --short                       clean
HEAD                                     875da854d5b97e069742eb51241eb91f773fca16  (G11-BB-S report)
branch / ahead-behind                    arch/eng-0005-execution-transition  0 / 0
BB-T report                              absent
BB-T implementation or test changes      none
candidate/freeze artefact in the repo    none
/etc/kyri/fabric/cadv-000005.json        absent  (16 files, unchanged since 2026-09-03)
CADV-000005 in /var/lib/kyri/fabric      absent  (4 records, newest CADV-000004)
capability-advertisement.seq             4
fabric aggregate                         7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96
trust  aggregate                         53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f

INTERRUPTION_RECOVERY                 PASS
INTERRUPTED_RUN_PRODUCTION_MUTATION   NO
INTERRUPTED_RUN_REPO_CHANGES          none
INTERRUPTED_RUN_SCRATCH_RECOVERED     NO — regenerated from scratch, deliberately
```

Both aggregates are the values BB-R and BB-S recorded. **No scratch state was
trusted.** Every candidate body, digest and rehearsal below was regenerated in
this run, which is why the candidate carries fresh instants and a different
digest from the interrupted draft. That draft is named and refused by the freeze
block (§5).

## 1. Live state, re-derived from the authorities

Not copied from the handoff. Read from the store and its sequence files:

```
capability-advertisement   seq=4   next=CADV-000005    unsuperseded=[CADV-000004]
capability-instance        seq=3   next=CINST-000004   unsuperseded=[CINST-000003]
capability-route           seq=3   next=CROUTE-0004    unsuperseded=[CROUTE-0003]
capability-selection       seq=2   next=CSEL-000003    unsuperseded=[CSEL-000001, CSEL-000002]

fabric  validate     valid, findings []
trust   validate     valid, problems []
nothing under /var/lib/kyri/fabric or /var/lib/kyri/trust written since CSEL-000002
```

Heads are derived by supersession — the record no other record supersedes — not
by identifier order. `CSEL-000001` and `CSEL-000002` are both unsuperseded and
that is not a fork: a selection carries no `supersedes` field.

The Capability Runtime, unchanged:

```
CINV-000001 sha256   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV seq 1           CRES count 0        next CINV-000002    next CRES-000001
validate_store       findings ()
supervision_ready    true       helper compatibility compatible, blocking []
```

```
FABRIC_VALID                YES
TRUST_VALID                 YES
FABRIC_UNEXPECTED_MUTATION  NO
CURRENT_LEASE_STATE         EXPIRED   (CADV-000004.valid_until = 2026-09-06T12:02:14-05:00)
```

## 2. The candidate

Fresh instants, a deliberate 96-hour window, and the accepted scope carried
across unchanged: `CHOST-0001`, `CPKG-0001`, `CCON-0001` at `1.0.0`, and the
`x86-64` architecture that is the single dimension `EVID-000001` establishes for
this target.

```
CADV_ID             CADV-000005
CADV_SUPERSEDES     CADV-000004
OBSERVED_AT         2026-09-06T21:30:00-05:00
RECORDED_AT         2026-09-06T21:30:00-05:00
VALID_UNTIL         2026-09-10T21:30:00-05:00
VALIDITY_DURATION   96h
CADV_FROZEN_SHA256  ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad
CADV_FROZEN_BYTES   673
CADV_REQUEST_DIGEST sha256:83cd12eb1418935e2fdfedaaf9fbbfa19107bd76b996630333d01fe91710f95a
```

```json
{
  "request_id": "g11bbt-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000004",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-06T21:30:00-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-06T21:30:00-05:00",
  "valid_until": "2026-09-10T21:30:00-05:00",
  "supersedes": "CADV-000004",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-06"
  }
}
```

*The block above is the file verbatim. Extracted from this report and hashed, it
is `ee862cc2…` at 673 bytes — and so is the heredoc in §5. The layout is
load-bearing: reflowing it changes the digest and the freeze block refuses.*

**The window is judged against `recorded_at`, never against a clock.**
`admission.py:1382` requires `observed_at <= recorded_at < valid_until` and says
why in its own comment: *"Reading the current time here would make the verdict
depend on when the request was replayed rather than on what it says, so a body
accepted once could be refused later without a single byte of it changing."*
So the frozen body does not decay — an operator running it tomorrow gets the
same verdict. What the clock does govern is *eligibility at use*, which is why
the 96 hours must cover the whole remaining chain: `CINST-000004`, `CROUTE-0004`,
`CSEL-000003` and `CINV-000002` stages 0–3 plus post-invoke acceptance.

### 2.1 96 hours is a reviewer decision, not an enforced bound

**There is no maximum-window policy in the engine.** The only window rules are
the two ordering constraints above and the downstream bound
`admitted_until <= advertisement.valid_until`. A ten-year window was rehearsed
and **accepted** (§3, N6c). The requested "validity window beyond allowed policy
→ REFUSE" case therefore cannot be demonstrated: there is no such policy to
violate. 96 h is chosen by review, matching the bound G11-AY-A2 set for
`CADV-000004`, and nothing mechanical would stop a wider one. Recorded as a
follow-up in §7, not fixed here — it does not block `CADV-000005`.

## 3. Negative battery

Every row is a **read-only preflight against the production store**. Production
Fabric was byte-identical before and after the whole battery
(`7c53efcd…` → `7c53efcd…`), and every row reports `mutated=false`.

| # | input | `would_accept` | reason |
| --- | --- | --- | --- |
| — | **the reviewed candidate** | **true** | control, `predicted_record_id=CADV-000005` |
| N1 | supersedes the already-superseded `CADV-000003` | false | `renewal-predecessor-not-current` |
| N1b | supersedes the oldest `CADV-000001` | false | `renewal-predecessor-not-current` |
| N1c | supersedes a `CADV` that does not exist | false | `unresolved-reference` |
| N2 | wrong package `CPKG-0002` | false | `unresolved-reference` |
| N3 | wrong host `CHOST-0002` | false | `unresolved-reference` |
| N3b | actor is not the advertising host | false | `actor-is-not-the-subject` |
| N4 | unknown field name in the body | refused | `the decision body does not match this operation` (CLI boundary, rc=2) |
| N4b | profile is a string, not a mapping | false | `malformed-operation-content` |
| N5 | profile claims more than `CHOST-0001` verifies | false | `resource-dimension-not-governed` |
| N5b | profile disagrees with the verified architecture | false | `malformed-operation-content` |
| N6 | window closes before it opens | false | `invalid-validity-window` |
| N6b | `recorded_at` outside its own window | false | `invalid-validity-window` |
| N6d | `observed_at` after `recorded_at` | false | `invalid-validity-window` |
| **N6c** | **ten-year window** | **true** | **no maximum-window policy exists — see §2.1** |
| N7 | names an `approving_authority` | false | `unexpected-approving-authority` |
| N9 | the accepted `CADV-000004` input, replayed | false | `renewal-predecessor-not-current` |

`N5` is the "profile outside verified CHOST capability" case: adding
`gpu_accelerators` is refused because `CHOST-0001` verifies exactly one
dimension, `architecture`, and no governed Evidence proves another.

**Already-spent sequence (N8), against a throwaway copy of the live store.**
The fixture write returned request digest `sha256:83cd12eb…` — **identical to
the live preflight** — and then:

| # | input | `would_accept` | reason | predicted |
| --- | --- | --- | --- | --- |
| N8 | the same body, replayed once `CADV-000005` is spent | false | `renewal-predecessor-not-current` | `CADV-000006` |
| N8b | a different `request_id` after it is spent | false | `renewal-predecessor-not-current` | `CADV-000006` |

A double-run is safe: once `CADV-000005` exists, `CADV-000004` is superseded and
the body cannot land twice.

### 3.1 Three bodies the engine will NOT distinguish

**This is the reason the freeze block pins the file digest.** Replayed against
production:

| body | file sha256 | request digest | engine verdict |
| --- | --- | --- | --- |
| **the reviewed BB-T candidate** | `ee862cc2…` | `sha256:83cd12eb…` | accept |
| the superseded **BB-S §11** candidate | `5d16ca93…` | `sha256:df41bd94…` | **accept** |
| the superseded **BB-T interruption draft** | `fa3f30da…` | `sha256:803ef3f8…` | **accept** |
| the accepted `CADV-000004` input | `130b3724…` | `sha256:77025249…` | refuse |

The two superseded candidates are well formed and supersede the right
predecessor, so the engine takes them. Only the freeze block's digest check
stands between a stale paste and an immutable record nobody reviewed — and all
three are refused **by name** in §5.

*(The `5d16ca93…` value is the one the committed BB-S report records. Its bytes
lived only in that run's scratch and were not re-derived here; the pin is
therefore committed evidence rather than a re-measurement, and it is stated that
way.)*

### 3.2 The request digest does not cover `request_id`

Two bodies differing **only** in `request_id` — different files, `ee862cc2…` and
`63690d60…` — produce the **identical** request digest
`sha256:83cd12eb1418935e2fdfedaaf9fbbfa19107bd76b996630333d01fe91710f95a`.

The digest witnesses the decision *content*; `request_id` is the replay key and
is outside it. So the request digest is not a witness for the request identity
and not a witness for the frozen file. Matching it is necessary and **not
sufficient** — this is why §5 pins `CADV_FROZEN_SHA256` and the byte count as
well, and why §3.1's stale candidates are caught by file digest rather than by
request digest. This joins the existing family of follow-ups in §7.

## 4. Live preflight

Against the production store, read-only:

```json
{
  "destination": "/var/lib/kyri/fabric/capability-advertisements/CADV-000005.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "register-advertisement",
  "outcome": "preflight",
  "predicted_record_id": "CADV-000005",
  "record_kind": "capability-advertisement",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:83cd12eb1418935e2fdfedaaf9fbbfa19107bd76b996630333d01fe91710f95a",
  "request_id": "g11bbt-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000004",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

**Read `would_accept`, not `outcome`** — `outcome` reads `preflight` whether the
rehearsal accepted or refused.

The `register-advertisement` write was **not** performed and is not authorised
by this checkpoint.

## 5. The operator freeze block

**It writes exactly one path, `/etc/kyri/fabric/cadv-000005.json`, and performs
no Fabric write.** The only command it runs against `/var/lib/kyri/fabric` is a
`--preflight` and a read-only aggregate.

Verified before publication: the heredoc was extracted and hashed, and it
renders `ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad` at
673 bytes — byte-identical to the rehearsed candidate. Each refusal arm was
exercised against a real body:

```
the reviewed body                accepted -> install
the BB-S §11 candidate           REFUSE: SUPERSEDED G11-BB-S §11 candidate
the interrupted BB-T draft       REFUSE: SUPERSEDED G11-BB-T recovery draft
the accepted CADV-000004 input   REFUSE: already-accepted CADV-000004 input
any other body                   REFUSE: rendered <actual>…, reviewed ee862cc2d9d9…
```

```bash
bash <<'FREEZE_CADV'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/cadv-000005.json
REVIEWED=ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad
REVIEWED_BYTES=673

# Bodies that are NOT this one, refused BY NAME rather than by a generic
# mismatch. The Fabric engine accepts the first two -- both are well formed and
# both supersede CADV-000004 -- so this block is the only thing between a stale
# paste and an immutable record nobody reviewed.
SUPERSEDED_BBS=5d16ca93dae33c10c72398b34649f6112e0a7056cb2f7586f492cf6ce876f8a1
SUPERSEDED_DRAFT=fa3f30da9532dabdf640817ca6708a6eb42a02951b42e9fab1f0de131a7fd366
ACCEPTED_CADV4=130b3724fca731a9186a59c5d601f7ffd8a5520a62ac374af195ca3541b9ecc4

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

sudo test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11bbt-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000004",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-06T21:30:00-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-06T21:30:00-05:00",
  "valid_until": "2026-09-10T21:30:00-05:00",
  "supersedes": "CADV-000004",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-06"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
case "${ACTUAL}" in
  "${SUPERSEDED_BBS}")
    echo "REFUSE: this is the SUPERSEDED G11-BB-S §11 candidate, not the reviewed G11-BB-T one"
    rm -f "${TMP}"; exit 1 ;;
  "${SUPERSEDED_DRAFT}")
    echo "REFUSE: this is the SUPERSEDED G11-BB-T interruption-recovery draft"
    rm -f "${TMP}"; exit 1 ;;
  "${ACCEPTED_CADV4}")
    echo "REFUSE: this is the already-accepted CADV-000004 input"
    rm -f "${TMP}"; exit 1 ;;
esac
test "${ACTUAL}" = "${REVIEWED}" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed ${REVIEWED}"; rm -f "${TMP}"; exit 1; }
test "$(wc -c < "${TMP}")" = "${REVIEWED_BYTES}" || {
  echo "REFUSE: rendered $(wc -c < "${TMP}") bytes, reviewed ${REVIEWED_BYTES}"
  rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- frozen input ---\n'
sudo sha256sum "${DEST}"
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"

printf '\n--- /etc/kyri/fabric AFTER ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

printf '\n--- preflight against the FROZEN input (read-only; NO Fabric write) ---\n'
cd /opt/schott-platform
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file cadv-000005.json --approved-directory /etc/kyri/fabric --preflight

printf '\n--- production Fabric must be byte-identical to before ---\n'
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
echo "expect 7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96  -"
FREEZE_CADV
```

### 5.1 Expected output

```
/etc/kyri/fabric BEFORE   16 entries, newest csel-000002.json  (2026-09-03)
frozen input              ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad
                          /etc/kyri/fabric/cadv-000005.json  root:cschott  640  673 bytes
/etc/kyri/fabric AFTER    17 entries; cadv-000005.json is the only addition
preflight                 would_accept true, mutated false,
                          predicted_record_id CADV-000005, destination_exists false,
                          request_digest sha256:83cd12eb1418935e2fdfedaaf9fbbfa19107bd76b996630333d01fe91710f95a
fabric aggregate          7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96
```

`root:cschott 0640` matches every one of the sixteen accepted inputs already in
that directory; live policy was read, not assumed.

## 6. Downstream chain — derived for review only, nothing frozen

Next identities, from the live sequence authorities:

```
NEXT_CINST   CINST-000004    supersedes CINST-000003, advertisement CADV-000005,
                             admitted_until READ BACK from the written CADV-000005
NEXT_CROUTE  CROUTE-0004     supersedes CROUTE-0003, route_version 4,
                             candidate_instances [CINST-000004]
NEXT_CSEL    CSEL-000003     request class only; resolves against CROUTE-0004,
                             expected selected_instance_id CINST-000004
```

**None of these is frozen, preflighted or authorised here.** Each gets its own
stage gate: write, then independent acceptance, then the next preparation.

```
PREMATURE_SELECTION_AUTHORISED = NO
```

A selection input carries **no** `route_id`. It names a request class and the
route is resolved at selection time, so the same reviewed bytes mean different
things before and after the route write — and G11-BB-S §11.4 measured the
consequence: run against a store whose route head is still `CROUTE-0003`, a
selection body is **accepted**, spends the identity, binds the stale route and
records `selected_instance_id: null`. The `CSEL-000003` preparation checkpoint
must therefore occur **only after `CROUTE-0004` is written and independently
verified**, and the same applies to `CINST-000004`, whose `admitted_until` must
be read back from the written `CADV-000005` rather than recomputed.

## 7. Follow-ups carried forward, not solved here

None blocks `CADV-000005`.

- A route may name a **superseded** instance and the engine accepts it (BB-S
  §11.4). The chain is ordered around this; step L must read
  `candidate_instances` back.
- The selection request digest **does not witness the resolved route**.
- **New here:** the request digest does not witness `request_id` either (§3.2),
  so it is not a witness for the frozen file. The freeze block pins the file
  digest and byte count for this reason.
- **New here:** there is **no maximum validity-window policy** (§2.1, N6c). A
  ten-year advertisement is accepted. The 96-hour bound is a review decision.
- Scope intersection silently narrows rather than refusing an unsupported
  requested scope (`SCOPE_INTERSECTION_ESCALATION=NO`,
  `SCOPE_INTERSECTION_SILENT_NARROWING=YES`, `FOLLOW_UP_REQUIRED=YES`).

## 8. Validation

No source, test or provisioning file changed in this checkpoint — it adds this
report only. Counts are fresh from this run.

```
FOCUSED FABRIC SUITES   15 suites, 9589 assertions, 0 FAIL
  advertisement-preflight 74   preflight 67   resources 121   host-admission 27
  admission-dependency-bound 44   instance-admission-integrity 38
  route-head 30   route-preflight 71   g11-integrity 91
  capability-fabric 538   fabric-runtime 8336   invoke-current-eligibility 49
  evidence-authority 49   package-manifest 37   runtime-install-closure 17

LOCAL_QUICK   PASS
LOCAL_FULL    PASS
GITHUB CI     6/6
CLEAN CLONE   PASS

production Fabric before/after the whole checkpoint
  7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   byte-identical
production Trust before/after
  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   byte-identical
```

## 9. Next

```
FRESH_FABRIC_RENEWAL_AUTHORISED   NO
PRODUCTION_CADV_WRITE             NOT_PERFORMED
CINV_000001_RESUME_AUTHORISED     NO
CINV_000002_PREPARED              NO
CINV_000002_SPENT                 NO
```

Reviewer accepts this preparation; the operator then runs the §5 freeze block
and returns its output. The `register-advertisement` write is a separate
authorised step and is not in that block.
