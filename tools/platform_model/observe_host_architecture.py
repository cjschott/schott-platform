#!/usr/bin/env python3
"""S0: observe a host's instruction-set architecture and render the evidence.

**Three independent observations, all of them required.** `uname -m`, `lscpu`,
and `dpkg --print-architecture` are asked separately and must agree after
normalisation. Falling back to whichever one answered would turn a corroborated
fact into a single unreviewed reading, so a missing tool, a failing command, an
empty answer, or a disagreement all refuse.

**The canonical value is not decided here.** Each raw reading is passed to the
committed Fabric host-observation normaliser, which owns the mapping from what
a host tool says to what Fabric governs. This module never contains the mapping
and never spells the canonical token as a literal: if the governed vocabulary
changes, this ceremony follows without being edited.

**`amd64` is accepted here and only here.** `dpkg --print-architecture` reports
it for this ISA, and that is a host tool describing this machine. The identical
string read off a container image is a different plane's fact and never reaches
this ceremony, which runs no container tooling at all.

**It writes nothing by default.** The candidate record goes to stdout for
review. Publication into the declarative evidence layer requires naming a root
explicitly, allocates the lowest unused six-digit identifier, refuses to
overwrite, writes atomically, and re-reads and re-validates what it wrote.

Governed by:
  platform-model/schemas/evidence.schema.yaml
  docs/standards/evidence-standard.md
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - environment guard
    print("ERROR: PyYAML is required. Install it with requirements-ci.txt.",
          file=sys.stderr)
    raise SystemExit(2)

from tools.fabric.resources import normalise_host_architecture  # noqa: E402
from tools.platform_model import evidence_fingerprint  # noqa: E402

# The ceremony that produced the record. Lowercase kebab-case, the convention
# every collector identifier in this repository follows. Deliberately not
# `linux-host`: that names the SSH collector plugin, and claiming its identity
# for an operator-run local ceremony would be a false provenance.
COLLECTOR = "s0-host-architecture"
SOURCE_TYPE = "command-output"
GOVERNED_FIELD = "architecture"
NORMALISATION_RULE = "tools/fabric/resources.py::normalise_host_architecture"
API_VERSION = "schott-platform/v1"

# Each observation names the command exactly as an operator would run it, so a
# reviewer can reproduce the reading rather than trust this file's summary.
OBSERVATIONS: tuple[tuple[str, str, list[str]], ...] = (
    ("uname_m", "uname -m", ["uname", "-m"]),
    ("lscpu_architecture", "LC_ALL=C lscpu | sed -n 's/^Architecture: *//p'",
     ["sh", "-c", "LC_ALL=C lscpu | sed -n 's/^Architecture: *//p'"]),
    ("dpkg_architecture", "dpkg --print-architecture",
     ["dpkg", "--print-architecture"]),
)

EVIDENCE_ID = re.compile(r"^EVID-([0-9]{6})$")
IDENTIFIER_WIDTH = 6
FILE_MODE = 0o644


class CeremonyError(Exception):
    """The observation cannot be trusted, so no evidence is produced."""


def observe(command: list[str]) -> str:
    """One reading, or refuse. Never returns a guess or a partial answer."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        raise CeremonyError(f"{command[0]!r} is not available on this host") from None
    except subprocess.TimeoutExpired:
        raise CeremonyError(f"{' '.join(command)} did not answer") from None
    if done.returncode != 0:
        raise CeremonyError(
            f"{' '.join(command)} exited {done.returncode}")
    value = done.stdout.strip()
    if not value:
        raise CeremonyError(f"{' '.join(command)} produced no output")
    return value


def collect() -> tuple[dict[str, Any], str]:
    """Every observation, normalised and agreed, or refuse.

    Returns the facts block and the canonical value. The canonical value is
    whatever the shared normaliser returned; this function never names it.
    """
    sources: list[dict[str, str]] = []
    canonical: set[str] = set()
    for name, display, command in OBSERVATIONS:
        raw = observe(command)
        governed = normalise_host_architecture(raw)
        if governed is None:
            raise CeremonyError(
                f"{display} reported {raw!r}, which is not a recognised host "
                "architecture observation")
        sources.append({"source": name, "command": display, "raw_value": raw})
        canonical.add(governed)

    if len(canonical) != 1:
        raise CeremonyError(
            "the observations do not agree after normalisation: "
            + ", ".join(sorted(canonical)))

    value = canonical.pop()
    return {
        "observations": sources,
        "governed_field": GOVERNED_FIELD,
        "canonical_value": value,
        "normalization_rule": NORMALISATION_RULE,
        "all_sources_consistent": True,
    }, value


def build(*, target: str, collected_at: str, identifier: str,
          facts: dict[str, Any]) -> dict[str, Any]:
    """The candidate record, with its fingerprint computed over the ruled six."""
    record: dict[str, Any] = {
        "api_version": API_VERSION,
        "kind": "Evidence",
        "id": identifier,
        "type": "evidence",
        "target": target,
        "source_type": SOURCE_TYPE,
        "collector": COLLECTOR,
        "collected_at": collected_at,
        "status": "success",
        "facts": facts,
        "provenance": {"class": "observed", "observed_at": collected_at},
        "sensitivity": "public",
        "retention": "3650d",
        "redaction": {"performed": False},
        "references": [],
    }
    record["content_fingerprint"] = evidence_fingerprint.fingerprint(record)
    return record


def next_identifier(directory: Path) -> str:
    """The lowest unused six-digit declarative identifier.

    Derived from what is on disk rather than assumed, and deliberately not the runtime
    observation store's sequence: that allocator owns a store outside the
    repository and refuses to sit inside one.
    """
    used: set[int] = set()
    if directory.is_dir():
        for path in sorted(directory.glob("*.yaml")):
            try:
                document = yaml.safe_load(path.read_text(encoding="utf-8"))
            except yaml.YAMLError as error:
                raise CeremonyError(
                    f"{path} is not readable YAML, so no identifier can be "
                    f"derived safely: {error}") from None
            match = EVIDENCE_ID.match(str((document or {}).get("id", "")))
            if match:
                used.add(int(match.group(1)))
    candidate = 1
    while candidate in used:
        candidate += 1
    return f"EVID-{candidate:0{IDENTIFIER_WIDTH}d}"


def filename_for(identifier: str, slug: str) -> str:
    return f"{identifier.lower()}-{slug}.yaml"


def render(record: dict[str, Any]) -> str:
    return yaml.safe_dump(record, sort_keys=False, default_flow_style=False,
                          allow_unicode=True)


def publish(record: dict[str, Any], directory: Path, slug: str) -> Path:
    """Write the record once, atomically, and prove what landed.

    The temporary is created in the destination directory so the rename is
    within one filesystem, and `os.link` publishes it: link refuses an existing
    destination where rename would replace it, and a ceremony must never
    overwrite an evidence record it did not write.
    """
    directory.mkdir(parents=True, exist_ok=True)
    final = directory / filename_for(record["id"], slug)
    if final.exists() or final.is_symlink():
        raise CeremonyError(f"{final} already exists; refusing to overwrite it")

    body = render(record)
    handle, temporary = tempfile.mkstemp(dir=str(directory), prefix=".s0-",
                                         suffix=".tmp")
    published = False
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, FILE_MODE)
        try:
            os.link(temporary, final)
            published = True
        except FileExistsError:
            raise CeremonyError(
                f"{final} appeared while it was being written; refusing to "
                "overwrite it") from None
    finally:
        # A failed publication leaves no partial artefact behind, and a
        # successful one leaves only the record.
        try:
            os.unlink(temporary)
        except OSError:
            pass
        if not published and final.exists():
            try:
                os.unlink(final)
            except OSError:
                pass

    # Read back what actually landed and re-derive its fingerprint. Writing and
    # believing are different acts. A record that fails here is one this call
    # created moments ago and nobody else has seen, so it is removed rather
    # than left as an artefact that validates against nothing.
    try:
        written = yaml.safe_load(final.read_text(encoding="utf-8"))
        if written != record:
            raise CeremonyError(f"{final} does not read back as it was written")
        if evidence_fingerprint.fingerprint(written) != written["content_fingerprint"]:
            raise CeremonyError(f"{final} does not verify against its own fingerprint")
    except Exception:
        try:
            os.unlink(final)
        except OSError:
            pass
        raise
    return final


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Observe host architecture and render declarative evidence.")
    parser.add_argument("--target", default="HOST-0001",
                        help="the platform-model entity the evidence is about")
    parser.add_argument("--collected-at",
                        help="RFC 3339 instant with an offset; defaults to now")
    parser.add_argument("--slug", default="schai-host-architecture",
                        help="filename slug used only when publishing")
    parser.add_argument("--publish-to", metavar="DIRECTORY",
                        help="publish into this evidence directory; without it "
                             "the candidate is printed and nothing is written")
    args = parser.parse_args(argv)

    collected_at = args.collected_at or datetime.now(timezone.utc).isoformat()

    try:
        facts, _ = collect()
        directory = Path(args.publish_to) if args.publish_to else None
        identifier = next_identifier(directory) if directory else "EVID-000001"
        record = build(target=args.target, collected_at=collected_at,
                       identifier=identifier, facts=facts)
        if directory is None:
            # Default: review, not publication.
            sys.stdout.write(render(record))
            print("# candidate only: nothing was written. Publish with "
                  "--publish-to <directory>.", file=sys.stderr)
            return 0
        final = publish(record, directory, args.slug)
    except CeremonyError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except evidence_fingerprint.FingerprintError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"published {final}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
