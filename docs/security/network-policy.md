# Network Policy

Host firewall policy for `schai`. **All firewall commands below are documented
for manual execution only and are not applied by any repository script.** Docker
publishes container ports at the host level, and UFW rules interact with
Docker's own iptables chains, so every change here requires **host-level
verification** by the operator.

## Approved source ranges

Set by explicit platform-owner decision for the current flat homelab LAN:

| Purpose | Range |
|---|---|
| Approved application range (LiteLLM `4000/tcp`) | `192.168.86.0/24` |
| Approved management range (SSH `22/tcp`) | `192.168.86.0/24` |

Both are the same today only because the homelab is a single flat network.
**Narrow these values when VLANs or additional routed networks are introduced** —
the application range and the management range are independent decisions and
should diverge as soon as the topology allows. Do not widen either range, and do
not infer a range from any pre-existing rule.

## Port model

| Port | Service | Intended access |
|---|---|---|
| `22/tcp` | SSH | Trusted management systems only |
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

3. **Allow approved clients to port 4000** (never open it to the world):

   ```bash
   # Keep SSH first so you cannot lock yourself out.
   sudo ufw allow from 192.168.86.0/24 to any port 22 proto tcp \
     comment 'SSH from trusted LAN'
   sudo ufw allow from 192.168.86.0/24 to any port 4000 proto tcp \
     comment 'LiteLLM from trusted LAN'
   ```

4. **Remove any legacy 11434 allowance** now that LiteLLM is the entry point:

   ```bash
   # List rules with numbers, read the number of the 11434 rule, then delete it
   # by that literal number. Substitute the real digit — passing the placeholder
   # text verbatim is a shell syntax error and deletes nothing.
   sudo ufw status numbered
   sudo ufw delete 2                        # example: 11434 shown as rule [ 2]
   sudo ufw status numbered                 # re-check: rules renumber after a delete
   ```

5. **Verify Ollama is not reachable remotely.** From an approved client (not the
   host), confirm the connection is refused/times out:

   ```bash
   curl -sS --max-time 5 http://schai:11434/api/tags   # expect failure
   ```

6. **Retain SSH access before enabling or reloading UFW**, then enable/reload:

   ```bash
   sudo ufw status
   sudo ufw enable        # or: sudo ufw reload
   ```

## Rollback considerations

- Always add the SSH allow rule **before** enabling or reloading UFW so a bad
  rule cannot lock you out.
- Keep a second console/session open while changing rules.
- If a client loses access to port `4000`, re-check the approved-range scope
  with `sudo ufw status numbered` and correct the specific rule rather than
  disabling the firewall wholesale.
- Because Docker manages its own iptables chains, always re-verify actual
  reachability at the host level after any change:
  `sudo ufw status numbered` **and** an on-network `curl` test.

## Docker and UFW interaction

**UFW does not reliably filter Docker-published ports.** Docker inserts its own
rules into the `DOCKER-USER` and `DOCKER` iptables chains, which are evaluated
before UFW's `ufw-user-input` chain. A `ufw allow from <range> to any port 4000`
rule therefore documents intent, but **may not by itself prevent an
out-of-range host from reaching published port `4000/tcp`**.

For the `v0.1.0` baseline this is a **recorded, accepted limitation**:

- The host has no public IPv4 address and no public/NAT exposure is configured
  as part of this task; the only global IPv6 address is an `fd00::/8` unique
  local address, which is not internet-routable.
- Port `4000` is therefore reachable only from the local LAN regardless of the
  UFW rule, and the LAN is the approved range.
- Port `11434` is **not published at all** by `ai/compose.yaml`, so no Docker
  chain can expose it — its protection does not depend on UFW.

A persistent `DOCKER-USER` policy that genuinely enforces the approved range at
the packet level is **deferred to a separately designed network-hardening
enhancement**. It is out of scope for `v0.1.0`. Until then, treat the UFW rule
for `4000/tcp` as declarative and verify actual reachability empirically.

## Verification checklist

- [ ] SSH remained available throughout the change.
- [ ] `4000/tcp` is reachable from an approved client in `192.168.86.0/24`.
- [ ] `11434/tcp` is not reachable from any remote host.
- [ ] The legacy `11434/tcp` allow rule has been deleted.
- [ ] `http://schai:4000/v1` works for an approved client with a valid key.
- [ ] Reachability was verified empirically, not inferred from `ufw status`
      (see [Docker and UFW interaction](#docker-and-ufw-interaction)).
