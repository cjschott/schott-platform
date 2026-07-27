# Network Policy

Host firewall policy for `schai`. **All firewall commands below are documented
for manual execution only and are not applied by any repository script.** Docker
publishes container ports at the host level, and UFW rules interact with
Docker's own iptables chains, so every change here requires **host-level
verification** by the operator.

Replace every `<placeholder>` with your real values. Do **not** assume the exact
subnet — the examples use clearly marked placeholders such as
`<approved-subnet>`.

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
   sudo ufw allow from <management-subnet> to any port 22 proto tcp
   sudo ufw allow from <approved-subnet> to any port 4000 proto tcp
   ```

4. **Remove any legacy 11434 allowance** now that LiteLLM is the entry point:

   ```bash
   # List rules with numbers, then delete the specific 11434 rule.
   sudo ufw status numbered
   sudo ufw delete allow 11434/tcp          # or: sudo ufw delete <rule-number>
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
- If a client loses access to port `4000`, re-check the `<approved-subnet>`
  scope with `sudo ufw status numbered` and correct the specific rule rather
  than disabling the firewall wholesale.
- Because Docker manages its own iptables chains, always re-verify actual
  reachability at the host level after any change:
  `sudo ufw status numbered` **and** an on-network `curl` test.

## Verification checklist

- [ ] SSH remained available throughout the change.
- [ ] `4000/tcp` is reachable only from `<approved-subnet>`.
- [ ] `11434/tcp` is not reachable from any remote host.
- [ ] `http://schai:4000/v1` works for an approved client with a valid key.
