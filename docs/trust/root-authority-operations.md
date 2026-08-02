# Operator Root Authority Operations

Every trust chain terminates at an **Operator Root Authority** that is external
to Kyri, human-controlled, and established out of band.

> **Kyri may persist a declaration that an external root exists. Kyri must not
> establish the external identity itself.** A platform that can establish its
> own root has no root — it has a variable.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md).

## What the runtime does and does not do

**Does:** record that a root exists, what was verified about it, by whom, when,
against which independent channel, and on what evidence.

**Does not:** verify anything, resolve the identity, contact anything, or guess.
There is no interactive prompt, no environment-variable identity, and no
implicit current user.

## Declaring the root

Root declaration requires an explicit input file in an approved directory.
Containment is checked after full resolution, so a symlink pointing out of the
directory is refused rather than followed.

```yaml
---
# All identities below are synthetic references.
display_name: Operator Root Authority
external_identity_reference: secret-source://approved/operator-root
verification_method: out-of-band-physical-verification
verification_details:
  subject_property: operator-root-identity
  observed_value_reference: /approved/evidence/root-observed.txt
  comparison_source: in-person-verification-record
  performed_by: operator-role-reference
  performed_at: 2026-08-02T09:00:00-05:00
evidence_references:
  - kind: attestation
    reference: /approved/evidence/root-attestation.txt
    recorded_at: 2026-08-02T09:00:00-05:00
created_at: 2026-08-02T09:00:00-05:00
provenance:
  class: declared
  source: operator-out-of-band
```

```bash
python3 -m tools.trust.cli init-root \
    --store-root /var/lib/kyri/trust \
    --input-file root.yaml \
    --approved-directory /etc/kyri/approved
```

**`external_identity_reference` is a reference.** No username, email, key
material, or certificate content is required by the schema or accepted by the
runtime. Credential material anywhere in the file is refused outright, and the
refusal never echoes the value.

## What is refused

| Attempt | Result |
|---|---|
| A second active root | Refused — two roots is no root |
| Missing evidence references | Refused before anything is written |
| Missing verification details | Refused before anything is written |
| Inline credential material | Refused; value never echoed |
| Input file outside the approved directory | Refused after resolution |
| A store root inside the repository | Refused |
| Overwriting an existing record | Refused; the write is the refusal |

## What cannot be done at all

- **Deleting the root** — no delete method exists anywhere in the package.
- **Updating the root** — no update method exists.
- **Superseding the root** — deliberately not implemented in v0.9.3. Replacing
  the thing every chain terminates at deserves its own review, not a side
  effect of running a command twice.
- **Self-approval** — the root has no `approved_by` field pointing at itself,
  and a decision whose subject is its own actor is refused.

## The concrete identity is not in the architecture

ADR-0011 defines the *role*. The concrete external identity is bound here, at
declaration time, by an operator — not written into a document where it would
outlive whoever currently holds it.

## Related

- [Trust Plane runtime overview](runtime-overview.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
