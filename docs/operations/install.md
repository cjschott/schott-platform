# Installation — clean Ubuntu 24.04 host

Clean installation of the AI Platform Baseline on `schai` (Ubuntu 24.04). The
canonical deployment path is `/opt/schott-platform`.

> **Static vs runtime.** `bash tests/test-static.sh` and
> `scripts/validate-config.sh` are static checks. Everything from "Deploy the
> stack" onward is a **runtime** step that requires the `schai` host with Docker,
> the GPU, and a real `ai/.env`. Static tests never require `schai`, a Docker
> daemon, or secrets.

## 1. Prerequisites

### Docker Engine and Docker Compose v2

```bash
docker --version
docker compose version
```

Both must succeed. `docker compose version` (with a space) confirms the
Compose **v2** plugin, which the scripts require.

### NVIDIA driver and Container Toolkit

Confirm the host driver and the container toolkit are installed:

```bash
nvidia-smi
nvidia-ctk --version
```

`nvidia-smi` must list the Tesla P4. The NVIDIA Container Toolkit is required for
GPU passthrough into the Ollama container.

### GPU verification

`nvidia-smi` on the host is a prerequisite; GPU visibility **inside** the
container is verified after deployment (see step 6).

## 2. Clone or update the repository

```bash
sudo mkdir -p /opt/schott-platform
sudo chown "$USER" /opt/schott-platform
git clone https://github.com/cjschott/schott-platform.git /opt/schott-platform
cd /opt/schott-platform
# Or, if it already exists:
# cd /opt/schott-platform && git pull
```

## 3. Create the local secret file

Copy the sanitized template to a local `ai/.env` (never committed):

```bash
cp ai/.env.example ai/.env
```

Generate a strong `LITELLM_MASTER_KEY` and write it into `ai/.env` **without
echoing it into shell history** where practical. For example, generate and
insert it in one step:

```bash
# Timezone in this environment is America/Chicago.
umask 077
KEY="$(openssl rand -hex 32)"
sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${KEY}|" ai/.env
unset KEY
```

Then restrict permissions to the deployment operator only:

```bash
chmod 600 ai/.env
ls -l ai/.env    # expect -rw------- and correct ownership
```

Do not print the key, commit `ai/.env`, or paste the key into chat, tickets, or
command history. See [../../security/SECURITY.md](../../security/SECURITY.md).

### Migrating from a legacy Ollama deployment (existing hosts only)

**Clean installs: skip this section.** The default in `ai/.env.example` already
creates the platform volume `schott-platform-ollama-models`, and no file needs
editing.

A host that already ran Ollama — a standalone `docker run`, a hand-written
Compose file, or an earlier project directory — keeps its downloaded models in
an existing Docker volume under a different, host-specific name. Deploying
without adopting it starts Ollama against a **new, empty** volume and forces a
full re-download of every model. The repository never hardcodes such a name;
set it in the protected local `ai/.env` instead.

1. Find the existing volume:

   ```bash
   docker volume ls
   ```

   A legacy standalone deployment in a directory named `ollama` typically
   produces `ollama_ollama-data`.

2. Confirm it is the one holding the model blobs before adopting it:

   ```bash
   docker volume inspect <volume-name>
   sudo du -sh "$(docker volume inspect -f '{{ .Mountpoint }}' <volume-name>)"
   ```

   Expect a mountpoint containing `models/blobs` and a size in the tens of GB.
   You can also confirm which volume the running legacy container uses:

   ```bash
   docker inspect -f '{{ range .Mounts }}{{ .Name }} -> {{ .Destination }}{{ end }}' <container>
   ```

3. Point the stack at it in `ai/.env` (never in a committed file):

   ```bash
   # in ai/.env — example legacy name; use the one you confirmed above
   OLLAMA_VOLUME_NAME=ollama_ollama-data
   ```

   Set the same value in `ai/ollama/.env` if you also use the isolated
   troubleshooting stack, so both inspect the same model data.

4. Stop the legacy Ollama deployment **before** deploying this stack. Two Ollama
   servers must never write to the same volume concurrently:

   ```bash
   docker stop <legacy-container>       # and disable whatever restarts it
   ```

5. Verify the rendered volume name resolves as intended, then continue with
   validation below:

   ```bash
   docker compose --env-file ai/.env -f ai/compose.yaml config | grep -A2 '^volumes:'
   ```

After deployment, `ollama list` should show the pre-existing models with no
re-download, and step 6's pulls become no-ops.

> **Warning — an adopted volume is deleted by `docker compose down -v`.**
> Because the volume carries an explicit name rather than a Compose-managed
> project-prefixed one, `down -v` (and `docker volume rm`) destroys the adopted
> model data just as readily as platform-created data. Use `down` without `-v`.
> Nothing in this repository ever runs `down -v`.

## 4. Validate configuration (static)

```bash
bash scripts/validate-config.sh
```

This verifies required tooling and files, refuses a missing `ai/.env`, refuses an
empty `LITELLM_MASTER_KEY` (without printing it), checks shell syntax, and
renders the Compose configuration. Fix every reported error before deploying.

## 5. Deploy the stack (runtime — requires schai)

```bash
./scripts/deploy-schai.sh
```

`deploy-schai.sh` re-runs validation, pulls images, starts the stack detached,
waits (bounded) for Ollama and LiteLLM to become healthy, then runs
`scripts/health-check.sh`. It never modifies firewall rules.

## 6. Verify the GPU and pull the required models

Confirm the Tesla P4 is visible inside the Ollama container:

```bash
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama nvidia-smi
```

Pull (or verify) all three required models. On a fresh host these are not yet
present:

```bash
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull qwen3:8b
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull qwen3:30b
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull nomic-embed-text
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama list
```

The models map to the aliases `local-fast`, `local-general`, and `local-embed`.

## 7. Run health checks (runtime — requires schai)

```bash
./scripts/health-check.sh
```

This verifies LiteLLM liveness, that unauthenticated `/v1/models` is rejected,
that authenticated `/v1/models` succeeds, a `local-fast` completion, a
`local-embed` vector, and `local-general` in the inventory.

For extended validation (a bounded `local-general` completion), add `--deep`:

```bash
./scripts/health-check.sh --deep
```

## 8. Firewall (manual only)

Repository scripts never change firewall rules. Apply the host firewall
transition manually per
[../security/network-policy.md](../security/network-policy.md).

## Next steps

- Day-to-day operations: [operations.md](operations.md)
- Recovery: [recovery.md](recovery.md)
