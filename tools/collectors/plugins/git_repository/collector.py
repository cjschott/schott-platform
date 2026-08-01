"""Git repository collector — local, read-only.

Runs a fixed set of read-only `git` inspection commands against a repository
path supplied by the orchestrator. It never contacts a remote: every approved
command reads local refs, the index, or the working tree. `fetch`, `pull`,
`push`, `clone`, `checkout`, `reset`, and `clean` are absent from the approved
set, so there is no code path that mutates or reaches the network.

Remote URLs are sanitized before they leave this module. A remote configured
with an embedded credential is common, and emitting it would put a working
credential into an evidence record.

File contents are never collected — only counts and metadata.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from ...base import CollectorPlugin
from ...command_runner import run_read_only_command
from ...exceptions import CollectorConfigurationError, CollectorExecutionError
from ...models import CollectionContext, CollectorManifest, Observation
from ...normalizer import normalize_observations
from ...redaction import redact_text

GIT_TIMEOUT_SECONDS = 30

# Every command this collector may run. Read-only by construction: none writes
# a ref, touches the working tree, or contacts a remote.
APPROVED_COMMANDS: dict[str, tuple[str, ...]] = {
    "toplevel": ("git", "rev-parse", "--show-toplevel"),
    "head_sha": ("git", "rev-parse", "HEAD"),
    "branch": ("git", "symbolic-ref", "--quiet", "--short", "HEAD"),
    "status": ("git", "status", "--porcelain=v1", "--untracked-files=all"),
    "tags_at_head": ("git", "tag", "--points-at", "HEAD"),
    "remotes": ("git", "remote", "-v"),
    "tracked_files": ("git", "ls-files"),
}

MANIFEST = CollectorManifest(
    id="git-repository",
    name="Git Repository Collector",
    version="0.1.0",
    source_type="git-repository",
    description=(
        "Observes local git repository state through read-only inspection "
        "commands. Never contacts a remote and never collects file contents."
    ),
    permissions=("read-repository-files",),
    capabilities=("CAP-0002",),
    supported_targets=("repository",),
    network_access=False,
    subprocess_access=True,
    filesystem_access="read-only",
    secret_requirements=(),
    output_contract=(
        "repository_root", "head_sha", "branch", "detached", "is_dirty",
        "tracked_file_count", "modified_file_count", "untracked_file_count",
        "tags_at_head", "remotes",
    ),
    lifecycle="production",
)

# scheme://[user[:pass]@]host[:port]/path
REMOTE_URL = re.compile(
    r"^(?P<scheme>[a-zA-Z][a-zA-Z0-9+.\-]*)://(?:[^@/]*@)?(?P<host>[^/:\s]+)(?::\d+)?(?P<path>/[^\s?#]*)?"
)
SCP_STYLE = re.compile(r"^(?:[^@\s]+@)?(?P<host>[^:/\s]+):(?P<path>[^\s?#]+)$")


def sanitize_remote_url(url: str) -> str:
    """Strip credentials and query strings from a remote URL.

    Usernames are removed too: a username is not a secret on its own, but it is
    an identity that does not belong in an operational fact, and stripping the
    whole userinfo section is simpler to reason about than stripping half.
    """
    text = str(url).strip()
    if not text:
        return "unknown"

    match = REMOTE_URL.match(text)
    if match:
        path = (match.group("path") or "").split("?")[0].split("#")[0]
        return f"{match.group('scheme')}://{match.group('host')}{path}"

    match = SCP_STYLE.match(text)
    if match:
        return f"ssh://{match.group('host')}/{match.group('path').split('?')[0]}"

    if text.startswith("/") or text.startswith("."):
        return "local-path"

    # Unrecognised shape: redact rather than guess, since an unparsed string
    # may still carry an embedded credential.
    cleaned, _ = redact_text(text)
    return cleaned


class GitRepositoryCollector(CollectorPlugin):
    """Collects declared-repository facts from a local git checkout."""

    @property
    def manifest(self) -> CollectorManifest:
        return MANIFEST

    def validate_configuration(self, context: CollectionContext) -> None:
        options = context.options or {}
        raw_path = options.get("path")
        if not raw_path:
            raise CollectorConfigurationError(
                "git-repository requires an explicit 'path' option; there is no default "
                "target path, so the collector cannot silently scan the host"
            )
        path = Path(str(raw_path)).expanduser()
        if not path.is_dir():
            raise CollectorConfigurationError("repository path does not exist or is not a directory")

    def _run(self, key: str, cwd: Path):
        return run_read_only_command(
            APPROVED_COMMANDS[key],
            cwd=cwd,
            timeout_seconds=GIT_TIMEOUT_SECONDS,
            allowed_executables={"git"},
            # git must not read user or system config: a global config can define
            # aliases, hooks, or credential helpers that change what these
            # commands do.
            sanitized_environment={
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
            },
        )

    def collect(self, context: CollectionContext) -> dict[str, Any]:
        cwd = Path(str((context.options or {})["path"])).expanduser().resolve()

        toplevel = self._run("toplevel", cwd)
        if not toplevel.succeeded:
            message, _ = redact_text(toplevel.stderr or "not a git repository")
            raise CollectorExecutionError(f"not a git repository: {message}")

        root = Path(toplevel.stdout.strip())

        head = self._run("head_sha", root)
        if not head.succeeded:
            raise CollectorExecutionError("repository has no resolvable HEAD")

        branch = self._run("branch", root)
        status = self._run("status", root)
        if not status.succeeded:
            raise CollectorExecutionError("git status failed")
        tags = self._run("tags_at_head", root)
        remotes = self._run("remotes", root)
        tracked = self._run("tracked_files", root)

        status_lines = [line for line in status.stdout.splitlines() if line.strip()]
        untracked = [line for line in status_lines if line.startswith("??")]
        modified = [line for line in status_lines if not line.startswith("??")]

        remote_names: dict[str, str] = {}
        for line in remotes.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                remote_names.setdefault(parts[0], sanitize_remote_url(parts[1]))

        detached = not branch.succeeded or not branch.stdout.strip()

        return {
            "repository_root": str(root),
            "head_sha": head.stdout.strip(),
            "branch": "detached" if detached else branch.stdout.strip(),
            "detached": detached,
            "is_dirty": bool(status_lines),
            "tracked_file_count": len([l for l in tracked.stdout.splitlines() if l.strip()]),
            "modified_file_count": len(modified),
            "untracked_file_count": len(untracked),
            "tags_at_head": sorted(t.strip() for t in tags.stdout.splitlines() if t.strip()),
            "remotes": dict(sorted(remote_names.items())),
        }

    def normalize(self, raw_result: Any, context: CollectionContext) -> list[Observation]:
        return normalize_observations(
            raw_result,
            source="git-repository",
            collected_at=context.collected_at,
            sensitivity="internal",
        )
