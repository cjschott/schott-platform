# Git Repository Collector

Observes local git repository state through read-only inspection commands.

- **Plugin ID:** `git-repository`
- **Source type:** `git-repository`
- **Permissions:** `read-repository-files`
- **Network access:** false · **Subprocess:** true (git only) · **Filesystem:** read-only

## Purpose

Reports what a repository checkout currently looks like — which commit, which branch, whether the tree is clean — so verification can compare declared repository facts against observed ones.

## Required inputs

| Option | Meaning |
|---|---|
| `path` | Repository path. **Required**; there is no default, so the collector cannot silently scan the host. |

## Commands executed

Only these, all read-only:

```text
git rev-parse --show-toplevel
git rev-parse HEAD
git symbolic-ref --quiet --short HEAD
git status --porcelain=v1 --untracked-files=all
git tag --points-at HEAD
git remote -v
git ls-files
```

git runs with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` disabled and `GIT_TERMINAL_PROMPT=0`, because a global config can define aliases, hooks, or credential helpers that change what these commands do.

## Collected facts

`repository_root`, `head_sha`, `branch`, `detached`, `is_dirty`, `tracked_file_count`, `modified_file_count`, `untracked_file_count`, `tags_at_head`, `remotes`.

## Not collected

- **File contents.** Only counts and metadata.
- **Commit history, authors, or messages.**
- **Anything from a remote.** No network call is made; `remotes` reports locally configured names only.
- **Stash, reflog, or hook contents.**

## Secret handling

Remote URLs are sanitized before leaving the collector. A remote configured with an embedded credential is common, and emitting it would place a working credential into an evidence record.

```text
https://user:s3cr3t@git.example.invalid/org/repo.git?token=abc
  ->  https://git.example.invalid/org/repo.git
git@github.com:org/repo.git
  ->  ssh://github.com/org/repo.git
```

The entire userinfo section is stripped, not just the password: a username is an identity that does not belong in an operational fact, and half-stripping is harder to reason about. Query strings are dropped. An unrecognised URL shape is redacted rather than guessed at.

Sanitization happens **before** fingerprinting, so a credential never reaches the fingerprint either.

## Failure modes

| Condition | Result |
|---|---|
| `path` missing | `failed` — configuration error |
| Path is not a repository | `failed` |
| No resolvable HEAD | `failed` |
| `git status` fails | `failed` |
| Command exceeds 30s | `failed` — timeout |
| Output exceeds byte ceiling | `failed` — truncation is not accepted silently |

All failures are closed: no partial fact set is emitted.

## Validation

```bash
bash tests/test-initial-collectors.sh
python3 tools/collectors/validate_plugins.py --root .
```

## Example output

Synthetic values:

```json
{
  "collector_id": "git-repository",
  "target": "REPO-0001",
  "status": "success",
  "content_fingerprint": "sha256:<digest>",
  "observations": [
    {"fact": "branch", "value": "main", "provenance": "observed"},
    {"fact": "head_sha", "value": "0000000000000000000000000000000000000000"},
    {"fact": "is_dirty", "value": false},
    {"fact": "remotes", "value": {"origin": "ssh://github.com/example/repo.git"}},
    {"fact": "tracked_file_count", "value": 151}
  ]
}
```

## Boundaries

- **No persistence.** The collector returns a `CollectorResult`; it writes no file.
- **No EVID assignment.** Evidence identity is assigned outside the plugin.
- **No remediation.** There is no code path that changes the repository, and collection is verified to leave HEAD and status byte-identical.
