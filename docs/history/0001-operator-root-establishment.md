# 0001 - Operator Root Authority Establishment

Status: Permanent Historical Record
Date: 2026-08-03
Platform Version: v0.9.6

---

## Purpose

This document records the establishment of Kyri's first immutable Operator Root Authority.

This is a historical record only.

It must never be edited after creation except through explicit superseding historical records.

---

## Repository

Repository:
schott-platform

Repository SHA:
c70cb42eeda249335b972566341b0c0036964cd3

Tag:
v0.9.6

---

## Root Authority

Authority ID:
TAUTH-000001

Type:
operator-root

Display Name:
Operator Root Authority

Lineage:
TLIN-000001
(Note: runtime allocated the lineage identifier but did not persist a lineage record. This is documented as a released implementation defect.)

---

## Ceremony

Operator:
Christopher Schott

Host:
schai

Store:
 /var/lib/kyri/trust

Input Root:
 /etc/kyri/trust

Identity Reference:
file-reference:///etc/kyri/operator-identity/operator-root.yaml

Verification Method:
Out-of-band fingerprint verification

---

## Evidence

Evidence IDs:

TEVID-000001
TEVID-000002
TEVID-000003
TEVID-000004
TEVID-000005

Audit Event:

TAUDIT-000001

---

## Known Deviations

• Missing lineage record persistence
• validate-store performs directory creation
• Gateway remains in code-owned-policy mode until TrustGateway cutover

---

## Significance

This ceremony establishes Kyri's first immutable trust root.

All future trust decisions originate from this authority.

No runtime trust cutover occurred during this ceremony.

Fabric Runtime, Capability Runtime, and Health Runtime remain intentionally blocked until TrustGateway cutover.

This document is intended to remain a permanent historical record.