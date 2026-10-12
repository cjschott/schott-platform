# ENG-0005 G11-AY-A2 — CADV-000004 preparation, 96-hour window

**Status: prepared, awaiting operator freeze.** No production byte was written,
by this preparation or by the superseded one.

Supersedes **[G11-AY-A](2026-09-02-g11-ay-a-cadv-000004-preparation.md)**, which
remains in place as historical evidence and carries a supersession banner. This
report restates only what the reruling changes; everything else stands there.

Branch `arch/eng-0005-execution-transition`, HEAD
`b21b34a`, clean tree, `0/0` against origin.

---

## 1. What changed, and what did not

The reviewer replaced the 48-hour ceremony ruling with **96 hours** before any
freeze or Fabric write — for the reason G11-AY-A §4 raised: two days left too
little room for AY-B, AY-C/D, G11-AZ, G11-BA and the first controlled invoke.

**The superseded candidate was never frozen and never installed.** It must not
be, and it is recorded so it can be recognised and refused:

| | superseded | live |
| --- | --- | --- |
| SHA-256 | `59c5fceeb758d049…9412ba5` | **`130b3724fca731a9186a59c5d601f7ffd8a5520a62ac374af195ca3541b9ecc4`** |
| request digest | `sha256:9e964cb1…32e888` | **`sha256:77025249d1385ec316dc8ebebdf8010b4c5e3107f4b0eb32494e1601667ae834`** |
| `observed_at` | `2026-09-02T10:18:57-05:00` | **`2026-09-02T12:02:14-05:00`** |
| `valid_until` | `2026-09-04T10:18:57-05:00` | **`2026-09-06T12:02:14-05:00`** |
| window | 48h | **96h** |

Both digests differ, so the two are distinguishable by inspection; the byte count
is identical at 672 because only timestamp *values* moved, not their widths.
**Compare the digest, not the size.**

## 2. Ceremony policy

**`ADVERTISEMENT_VALIDITY_POLICY = 96h`** — ceremony policy for G11-AY, and
nothing more.

Re-confirmed rather than assumed: `tools/fabric/` carries **no** validity
default — no `timedelta`, no hour constant, no config key, no schema bound. The
duration is a ceremony's to declare each time, which is exactly why it needed
ruling rather than inheriting.

**Nothing was added to carry it.** No source constant, no config default, no
schema restriction, no runtime change. The 96 hours exists in this report, in
the frozen input's `valid_until`, and in the record that input produces —
nowhere else. `SOURCE_DEFAULT = NONE`.

The window remains bounded, and four independent gates still stand between it
and any execution: the structural admission dependency bound (§5), invoke-time
current eligibility, route and selection authority, and closed sudoers.

## 3. Preserved values, independently re-derived

Not carried over from the superseded preparation:

| | derived from | value |
| --- | --- | --- |
| `CADV_NEXT` | `peek_next_id` on the live store | **CADV-000004** — destination absent |
| `CADV_SUPERSEDES` | the sole unsuperseded advertisement | **CADV-000003** |

Headness was derived rather than assumed: of `CADV-000001..000003`, two appear as
a `supersedes` target and exactly one does not. One head, no fork, no ambiguity.

## 4. The candidate, rebuilt from live governed facts

Every field re-read from the live records at this preparation, not reused:

| field | value | read from |
| --- | --- | --- |
| `capability_host_id` | `CHOST-0001` | host record |
| `capability_package_id` | `CPKG-0001` | package record |
| `contract_id` | `CCON-0001` | `CPKG-0001.contract_id`, cross-checked against `CCON-0001` |
| `satisfied_contract_versions` | `["1.0.0"]` | `CPKG-0001.satisfied_contract_versions` |
| `advertised_resource_profile` | `{architecture: x86-64}` | `CHOST-0001.verified_resource_profile` |
| `supersedes` | `CADV-000003` | derived head |
| `actor` | `CHOST-0001` | the subject's own claim |
| `approving_authority` | **absent** | a self-report may not carry one |

```json
{
  "request_id": "g11ay-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000003",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-02T12:02:14-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-02T12:02:14-05:00",
  "valid_until": "2026-09-06T12:02:14-05:00",
  "supersedes": "CADV-000003",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-02"
  }
}
```

| | |
| --- | --- |
| bytes | **672** |
| SHA-256 | `130b3724fca731a9186a59c5d601f7ffd8a5520a62ac374af195ca3541b9ecc4` |
| request digest | `sha256:77025249d1385ec316dc8ebebdf8010b4c5e3107f4b0eb32494e1601667ae834` |
| destination | `/etc/kyri/fabric/cadv-000004.json`, `root:cschott 0640` |

## 5. Re-run against the 96-hour body

**Fixture** — a full copy of the production Fabric, with its real history.

Accepted: `would_accept: true`, `mutated: false`, `predicted_record_id:
CADV-000004`. Refused, each with its governed reason:

| body | reason |
| --- | --- |
| supersedes `CADV-000002` (already superseded) | `renewal-predecessor-not-current` |
| `valid_until` before `observed_at` | `invalid-validity-window` |
| window closing before `recorded_at` | `invalid-validity-window` |
| unknown `capability_host_id` | `unresolved-reference` |
| naming an `approving_authority` | `unexpected-approving-authority` |
| advertising a profile the host does not verify | `malformed-operation-content` |

The last is new to this run and worth having: a host may not advertise
capabilities its own verified profile does not establish.

**The fixture write then succeeded**, producing `CADV-000004` with
`observed_at 2026-09-02T12:02:14-05:00`, `valid_until 2026-09-06T12:02:14-05:00`
and `supersedes: CADV-000003`.

**The structural bound still binds at the longer window** — checked against the
*written* advertisement's own `valid_until`, not against arithmetic repeated
here:

| `admitted_until` | verdict |
| --- | --- |
| advertisement `valid_until` **+1 second** | **refused** — `admission-window-exceeds-advertisement` |
| advertisement `valid_until` **+48 hours** | **refused** — `admission-window-exceeds-advertisement` |
| **equal** | accepted |
| **24 hours shorter** | accepted |

A longer advertisement window does not loosen the instance bound. It is still
refused at one second, so a 96-hour advertisement cannot produce a 97-hour
admission.

**Live preflight**, read-only against production:

```
predicted_record_id : CADV-000004
destination_exists  : false
would_accept        : true
mutated             : false
request_digest      : sha256:77025249d1385ec316dc8ebebdf8010b4c5e3107f4b0eb32494e1601667ae834
```

The digest is identical across fixture preflight, fixture write and live
preflight — one value for the operator to compare rather than three runs to
trust.

## 6. Production non-mutation

Content manifests, not structural counts, because a same-size sequence
replacement would be invisible to a structural check:

| | |
| --- | --- |
| Fabric content manifest, before → after this preparation | **byte-identical** |
| Trust content manifest, before → after | **byte-identical** |
| Fabric manifest vs. before the *superseded* preparation | **byte-identical** |

That last row is the point: **neither** preparation touched production. The
store is exactly what it was before any of this began.

```
CADV-000004 (record)              absent
seq(capability-advertisement)     3
/etc/kyri/fabric/cadv-000004.json absent
sudoers non-README                0
CINV / CRES                       0 / 0
```

## 7. Operator block — freeze only

Fail-if-exists. It writes the reviewed input and preflights it. It performs
**no** Fabric write.

```bash
bash <<'FREEZE_CADV'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/cadv-000004.json
REVIEWED=130b3724fca731a9186a59c5d601f7ffd8a5520a62ac374af195ca3541b9ecc4
SUPERSEDED=59c5fceeb758d0495300343362a5b73863dcf46d37374704331eb9e8b9412ba5

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11ay-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000003",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-02T12:02:14-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-02T12:02:14-05:00",
  "valid_until": "2026-09-06T12:02:14-05:00",
  "supersedes": "CADV-000003",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-02"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
# The superseded 48-hour candidate is the same length. Refuse it by name rather
# than relying on a size check that cannot tell them apart.
test "${ACTUAL}" != "${SUPERSEDED}" || {
  echo "REFUSE: this is the superseded 48-hour candidate"; rm -f "${TMP}"; exit 1; }
test "${ACTUAL}" = "${REVIEWED}" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed ${REVIEWED}"; rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- frozen input ---\n'
sudo sha256sum "${DEST}"
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"

printf '\n--- /etc/kyri/fabric AFTER ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

printf '\n--- preflight against the FROZEN input (read-only, no Fabric write) ---\n'
cd /opt/schott-platform
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000004.json --approved-directory /etc/kyri/fabric --preflight
FREEZE_CADV
```

Expect 672 bytes at `130b3724…b9ecc4`, and a preflight reporting
`would_accept: true`, `mutated: false`, `predicted_record_id: CADV-000004`, and
request digest `sha256:77025249…7ae834` — **the same digest as §5**. If it moves,
the body moved, and the ceremony stops.

The Fabric write is **not** in this block. It is authorised separately, after
this output is reviewed.

## 8. Validation

No repository change was required by this re-preparation, and none was made. The
suites stand where the repair commit `dade900` left them: quick **102/102**, full
**127/127**, all six workflows green.

## 9. Next

Unchanged by the reruling: after the freeze and the AY-B write, AY-C derives
`CINST-000003` against the **live written** `CADV-000004` — not against this
candidate — and AY-D writes it. `CROUTE-0002` will still name `CINST-000002`, so
the new instance is not routable and no service is restored by G11-AY. Sudoers
stays closed throughout.

Then **G11-AZ**: a `CROUTE` successor and a fresh `CSEL`.
