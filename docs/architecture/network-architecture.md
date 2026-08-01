# Network Architecture

## Purpose

This document defines the logical network zones and trust boundaries used by the Schott Platform. It describes policy intent, not a complete inventory of every device.

## Current Address Plan

| Zone | Address range | Purpose |
|---|---|---|
| Management Network | `192.168.86.2-99` | Administrative systems and infrastructure services |
| Reserved | `192.168.86.100-149` | Static reservations and future platform services |
| DHCP | `192.168.86.150-254` | General client devices |
| Full LAN | `192.168.86.0/24` | Current flat routed network |

The Management Network is an exact host range. It must not be approximated with a wider CIDR such as `192.168.86.0/25`.

## Trust Boundaries

### Administrative plane

Administrative services are reachable only from the Management Network. Examples include:

- SSH
- Proxmox VE
- Proxmox Backup Server
- TrueNAS administration
- Grafana administration
- Kyri administration

### Application plane

Application-facing services may be reachable from a broader approved range when the service requires it. LiteLLM on `4000/tcp` is currently reachable from the full LAN, `192.168.86.0/24`.

### Private service plane

Backend services that do not require direct client access remain private to their host or container network. Ollama on `11434/tcp` is private to Docker networking and must not be remotely reachable.

## Reference Host

`schai` is the reference implementation for the initial network-hardening standard. New controls are designed, implemented, validated, documented, and automated there before wider rollout.

## Future VLAN Mapping

The logical policy is intentionally separated from the current physical topology. When VLANs are introduced, the Management Network should map to `VLAN10` without changing the security principle: administrative access originates only from the management zone.

The future migration should replace literal source ranges with named inventory variables or zone abstractions rather than duplicating firewall logic.

## Policy Principles

1. Administrative access is restricted by source.
2. Services are exposed only to the smallest range required.
3. Backend services remain private unless there is an approved design change.
4. Runtime behavior is verified empirically, especially for Docker-published ports.
5. Proven configuration is converted into Ansible before rollout to additional hosts.
