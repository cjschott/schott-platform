# Network Policy

Host firewall policy for `schai`. **All firewall commands below are documented
for manual execution only and are not applied by any repository script.** Docker
publishes container ports at the host level, and UFW rules interact with
Docker's own iptables chains, so every change here requires **host-level
verification** by the operator.

## Related standards

This policy implements and must remain consistent with:

- [Network Architecture](../architecture/network-architecture.md)
- [Linux Server Security Standard](../standards/linux-server-security-standard.md)
- [Service Exposure Standard](../standards/service-exposure-standard.md)
- [ADR-0001: schai as the Reference Host](../decisions/ADR-0001-schai-reference-host.md)

## Approved source ranges

Set by explicit platform-owner decision for the current flat homelab LAN:

| Purpose | Range |
|---|---|
| Approved application range (LiteLLM `4000/tcp`) | `192.168.86.0/24` |
| Management address pool | `192.168.86.2-192.168.86.99` |
| DHCP client pool | `192.168.86.150-192.168.86.254` |

The management address pool and application range are separate policy scopes.
They overlap today only because the platform currently uses a flat LAN.
Administrative access must originate from an explicitly approved management
host within `192.168.86.2-192.168.86.99`; membership in the broader `/24` does
not by itself authorize SSH access.

UFW does not accept the human-readable range `192.168.86.2-192.168.86.99` as a
single source expression. Until a management VLAN provides a dedicated CIDR,
create SSH rules for specific approved management host addresses. Do not replace
this requirement with a broader `/24` rule merely for convenience.

## Policy alignment

This document enforces the Service Exposure Standard.

| Service | Classification | Required exposure |
|---|---|---|
| SSH | Administrative | Approved management hosts only |
| LiteLLM | Application | `192.168.86.0/24` |
| Ollama | Private | Internal Docker network only |

LiteLLM is the approved application gateway. Ollama must never be exposed
directly to a remote host.

## Port model

| Port | Service | Intended access |
|---|---|---|
| `22/tcp` | SSH | Explicitly approved management hosts only |
| `4000/tcp` | LiteLLM | Approved application subnets/hosts only |
| `11434/tcp` | Ollama | **Private** — internal Docker network only, never remote |

- `4000/tcp` (LiteLLM) is the **only** application-facing port. Applications use
  `http://schai:4000/v1`.
- `11434/tcp` (Ollama) is **private** in the integrated stack (`ai/compose.yaml`
  publishes no Ollama host port). Any legacy host allowance for `11434` is a
  migration leftover and must be removed once LiteLLM is validated.

## Staged transition

Perform these stages in order. **Retain SSH access throughout** — never enable
or reload UFW in a way that could drop your management session.

1. **Verify LiteLLM locally** on the host before changing any firewall rule:

   ```bash
   ./scripts/health-check.sh
   ```

2. **Verify an approved remote client** can reach the gateway (from that
   client):

   ```bash
   curl -sS -H "Authorization: Bearer <key>" http://schai:4000/v1/models
   ```

3. **Allow approved clients** without broadening administrative access:

   ```bash
   # Add one rule for each explicitly approved management host.
   # Replace the example address with the real management host address.
   sudo ufw allow from 192.168.86.12 to any port 22 proto tcp \
     comment 'SSH from approved management host'

   sudo ufw allow from 192.168.86.0/24 to any port 4000 proto tcp \
     comment 'LiteLLM from application LAN'
   ```

4. **Remove any legacy 11434 allowance** now that LiteLLM is the entry point:

   ```bash
   # List rules with numbers, read the number of the 11434 rule, then delete it
   # by that literal number. Substitute the real digit — passing placeholder
   # text verbatim is a shell syntax error and deletes nothing.
   sudo ufw status numbered
   sudo ufw delete 2                        # example: 11434 shown as rule [ 2]
   sudo ufw status numbered                 # re-check: rules renumber after a delete
   ```

5. **Verify Ollama is not reachable remotely.** From an approved client (not the
   host), confirm the connection is refused or times out:

   ```bash
   curl -sS --max-time 5 http://schai:11434/api/tags   # expect failure
   ```

6. **Retain SSH access before enabling or reloading UFW**, then enable or reload:

   ```bash
   sudo ufw status
   sudo ufw enable        # or: sudo ufw reload
   ```

## Rollback considerations

- Always add and test the approved SSH host rule **before** enabling or
  reloading UFW so a bad rule cannot lock you out.
- Keep a second console or session open while changing rules.
- If a client loses access to port `4000`, re-check the approved application
  scope with `sudo ufw status numbered` and correct the specific rule rather
  than disabling the firewall wholesale.
- Because Docker manages its own iptables chains, always re-verify actual
  reachability at the host level after any change:
  `sudo ufw status numbered` **and** an on-network `curl` test.

## Docker and UFW interaction

**UFW does not reliably filter Docker-published ports.** Docker inserts its own
rules into the `DOCKER-USER` and `DOCKER` iptables chains, which are evaluated
before UFW's `ufw-user-input` chain. A UFW source rule for port `4000` therefore
documents intent, but **may not by itself prevent an out-of-range host from
reaching published port `4000/tcp`**.

For the current flat-LAN baseline this is a recorded, accepted limitation:

- The host has no public IPv4 address and no public or NAT exposure is
  configured as part of this policy.
- Port `4000` is therefore reachable only from the local LAN, which is the
  approved application range.
- Port `11434` is **not published at all** by `ai/compose.yaml`, so no Docker
  chain can expose it; its protection does not depend on UFW.

A persistent `DOCKER-USER` policy that enforces approved source ranges at the
packet level remains a separately designed network-hardening enhancement. Until
then, treat the UFW rule for `4000/tcp` as declarative and verify actual
reachability empirically.

## Future architecture

The current implementation uses the flat `192.168.86.0/24` network. Future
revisions will replace literal address ranges with VLAN and security-zone policy
definitions while preserving the same exposure classifications and trust model.

The management network should eventually have its own CIDR so administrative
rules can be expressed and enforced without per-host exceptions.

## Reference host

Firewall policy is implemented and validated on `schai` before being converted
into reusable Ansible automation. `schai` remains the canonical implementation
as defined by ADR-0001.

## Verification checklist

- [ ] SSH remained available throughout the change.
- [ ] SSH is reachable only from explicitly approved management hosts.
- [ ] `4000/tcp` is reachable from an approved client in `192.168.86.0/24`.
- [ ] `11434/tcp` is not reachable from any remote host.
- [ ] The legacy `11434/tcp` allow rule has been deleted.
- [ ] `http://schai:4000/v1` works for an approved client with a valid key.
- [ ] Reachability was verified empirically, not inferred from `ufw status`
      (see [Docker and UFW interaction](#docker-and-ufw-interaction)).
