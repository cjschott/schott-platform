"""Turning a governed package into a verified tree, or refusing.

**A governed package is an immutable directory tree.** Generation 9 staged one
regular file and named it the package, while every consumer downstream — the
launch bridge's ``O_DIRECTORY`` open, `validate_package`, the worker snapshot,
the `/kyri/package` bind mount — required a tree. The regular-file resolver was
the outlier, and Generation 10 removes it rather than converting between the
two shapes: a conversion layer would be a second answer to the question *what
is the package*, and there is only one.

**The source path is discovery input. The staged tree is the answer.** The
source root is opened once through the reviewed trusted-source primitive and
walked through *that descriptor*, so a pathname is never re-resolved for
authoritative bytes. A pathname read twice is two different questions asked of
whoever can write the directory.

**The commitment is computed over the staged tree, not the source.** The source
may be mutated while it is being read; that cannot be prevented and is not
worth pretending about. What closes it is that the identity is derived from the
immutable copy that will actually reach execution, and the walk refuses a
source that changed underneath it. The same discipline the worker snapshot
already uses, applied one plane earlier.

**What the integrity claim actually is**, stated the way the specification
states it rather than flatteringly: the staged tree matches the commitment
declared by a manifest that was read from a repository satisfying the
trusted-source ownership, mode, and link contract, and that manifest is
coherently bound to the governed package identities the Fabric evidence already
verified. The manifest is **not** an independent cryptographic root of trust,
and nothing here should be read as claiming it is. Stronger governed content
binding is Deferred F.

**Staging is content-addressed, so no caller-controlled name becomes an
identity.** The tree is built under a runtime-chosen temporary name, committed,
tightened, and installed with one rename at ``tree-sha256-<hex>``. A rename
onto an existing non-empty directory fails, so publication never overwrites. A
tree already there is validated and reused, or refused — never repaired, never
replaced, never chmod'ed back into shape.

**This module writes in one place and for one reason:** the staging root. It
creates no capability record, allocates no identity, and touches nothing on the
source side. It reads and hashes a tree; it never imports, loads, or runs one,
whatever the bytes happen to look like.
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from .rehearsal import is_rehearsing
from ..common.trusted_source import (TraversalReason, TraversalRefused,
                                     TrustedSourceError,
                                     open_trusted_directory,
                                     open_trusted_regular_file, walk_tree)
from .execution.package_contract import (MAXIMUM_AGGREGATE_BYTES,
                                         MAXIMUM_ENTRIES, MAXIMUM_FILE_BYTES,
                                         PackageError, inspect_package)

# Hard architecture limits for schema version 2. Raising any is a decision, not
# a constant edit made under pressure. The tree bounds are the package
# contract's own: staging and validation disagreeing about how large a package
# may be would mean a tree that stages and then refuses to run.
MANIFEST_MAXIMUM_BYTES = 65536
PACKAGE_MAXIMUM_DEPTH = 32

MANIFEST_SCHEMA_VERSION = 2

# Closed schema: exactly these, and an unknown field refuses. A manifest that
# tolerates fields nobody reviewed is one whose meaning grows unnoticed.
#
# Version 2 renames the digest field. Version 1's `artifact_sha256` meant the
# SHA-256 of one regular file's bytes, and this value is a tree commitment
# instead — a materially different claim. Carrying the old name would be a
# manifest that lies about what it committed to, and there are no governed
# package records anywhere to be broken by correcting it before the first one
# exists.
MANIFEST_FIELDS = ("schema_version", "capability_package_id", "contract_id",
                   "capability_id", "artifact_reference", "package_tree_sha256")

# Two closed schemes, each meaning exactly one object kind. `file:` resolves to
# a regular file and `tree:` to a directory, so neither can be read as the
# other by a consumer that guessed.
_FILE_SCHEME = "file:"
_TREE_SCHEME = "tree:"

_HEX = frozenset("0123456789abcdef")
_DIGEST_PREFIX = "sha256:"
_DIGEST_LENGTH = len(_DIGEST_PREFIX) + 64
_STAGED_PREFIX = "tree-sha256-"
_DIRECTORY_MODE = 0o500
_MEMBER_MODE = 0o400
_STAGING_MODE = 0o700
_CHUNK = 1024 * 256

_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_CREATE_FLAGS = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | os.O_CLOEXEC)

REASON_GRAMMAR = "artifact-reference-outside-grammar"
REASON_MANIFEST_ABSENT = "manifest-reference-absent"
REASON_MANIFEST_UNREADABLE = "manifest-not-readable"
REASON_MANIFEST_MALFORMED = "manifest-not-valid-json"
REASON_MANIFEST_SCHEMA = "manifest-schema-invalid"
REASON_MANIFEST_IDENTITY = "manifest-identity-mismatch"
REASON_TREE_UNREADABLE = "package-tree-not-readable"
REASON_TREE_UNGOVERNED = "package-tree-not-governed"
REASON_TREE_MUTATED = "package-tree-mutated-during-staging"
REASON_SUBSTITUTION = "substitution-detected"
REASON_STAGING_ROOT = "staging-root-unusable"
REASON_STAGED_UNUSABLE = "staged-tree-unusable"
REASON_STAGED_COLLISION = "staged-commitment-collision"


@dataclass(frozen=True)
class StagedPackage:
    """Verified preparation facts. Nothing here runs anything.

    ``staged_path`` is an absolute coordinator-owned **directory**, and
    ``package_tree_sha256`` is the commitment `inspect_package` derived from
    exactly that directory. The pair is the whole S4 to S5 contract: S5 opens
    the path with ``O_DIRECTORY`` and revalidates it through the same primitive
    that produced the commitment.
    """

    supported: bool
    reason: str | None = None
    capability_package_id: str | None = None
    contract_id: str | None = None
    capability_id: str | None = None
    package_tree_sha256: str | None = None
    staged_path: str | None = None
    manifest_version: int | None = None


def _refused(reason: str) -> StagedPackage:
    return StagedPackage(False, reason)


def _relative_from_reference(reference: Any, scheme: str) -> str | None:
    """The relative path a reference names under ``scheme``, or ``None``.

    Nothing is inferred. A reference without the scheme, with an authority, or
    naming an absolute path is refused rather than interpreted charitably.
    """
    if not isinstance(reference, str):
        return None
    if not reference.startswith(scheme):
        return None
    remainder = reference[len(scheme):]
    if not remainder or remainder != remainder.strip():
        return None
    if remainder.startswith("/") or remainder.startswith("//"):
        return None
    if "\x00" in remainder:
        return None
    candidate = PurePosixPath(remainder)
    if candidate.is_absolute():
        return None
    parts = [part for part in candidate.parts if part not in ("", ".")]
    if not parts or any(part == ".." for part in parts):
        return None
    return remainder


def _valid_digest(value: Any) -> bool:
    """`sha256:` and exactly sixty-four lowercase hexadecimal characters."""
    if not isinstance(value, str) or len(value) != _DIGEST_LENGTH:
        return False
    if value[:len(_DIGEST_PREFIX)] != _DIGEST_PREFIX:
        return False
    return all(character in _HEX for character in value[len(_DIGEST_PREFIX):])


def _bounded_read(descriptor: int, limit: int) -> bytes:
    """At most `limit` bytes, refusing rather than truncating past it."""
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(descriptor, min(_CHUNK, limit + 1 - total))
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > limit:
            raise TrustedSourceError("the source exceeds its bound while reading")
        chunks.append(chunk)


def _validated_manifest(body: Any, evidence) -> tuple[dict[str, Any] | None, str | None]:
    """Schema version 2, closed, and bound to the verified identities."""
    if not isinstance(body, dict):
        return None, REASON_MANIFEST_MALFORMED
    if set(body) != set(MANIFEST_FIELDS):
        return None, REASON_MANIFEST_SCHEMA

    version = body["schema_version"]
    # A bool is an int in Python; a manifest saying `true` is not saying `2`.
    if isinstance(version, bool) or not isinstance(version, int):
        return None, REASON_MANIFEST_SCHEMA
    if version != MANIFEST_SCHEMA_VERSION:
        return None, REASON_MANIFEST_SCHEMA

    for field in ("capability_package_id", "contract_id", "capability_id",
                  "artifact_reference"):
        if not isinstance(body[field], str) or not body[field]:
            return None, REASON_MANIFEST_SCHEMA
    if not _valid_digest(body["package_tree_sha256"]):
        return None, REASON_MANIFEST_SCHEMA
    if _relative_from_reference(body["artifact_reference"], _TREE_SCHEME) is None:
        return None, REASON_MANIFEST_SCHEMA

    # Bound to what the Fabric already verified, not to what it claims itself.
    if (body["capability_package_id"] != evidence.capability_package_id
            or body["contract_id"] != evidence.contract_id
            or body["capability_id"] != evidence.capability_id
            or body["artifact_reference"] != evidence.artifact_reference):
        return None, REASON_MANIFEST_IDENTITY
    return body, None


def _usable_staging_root(staging_root: Any, coordinator_uid: int) -> Path | None:
    """The staging root, if it is the coordinator's and no one else's."""
    try:
        root = Path(staging_root)
        entry = root.lstat()
    except (TypeError, OSError):
        return None
    if not stat.S_ISDIR(entry.st_mode) or stat.S_ISLNK(entry.st_mode):
        return None
    if entry.st_uid != coordinator_uid:
        return None
    if entry.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return None
    return root


def _commitment_of(path: Path) -> str:
    """The commitment of the tree at ``path``, through its own descriptor."""
    handle = os.open(path, _DIR_FLAGS)
    try:
        return _DIGEST_PREFIX + inspect_package(handle).digest
    finally:
        os.close(handle)


def _existing_staged(final: Path, digest: str, coordinator_uid: int) -> str | None:
    """Whether a tree already there may be reused, or why it may not.

    Returns `None` when it is sound and reusable. Nothing is repaired: a staged
    tree that disagrees with its own commitment is reported, not replaced.
    """
    try:
        entry = final.lstat()
    except OSError:
        return REASON_STAGED_UNUSABLE
    if stat.S_ISLNK(entry.st_mode) or not stat.S_ISDIR(entry.st_mode):
        return REASON_STAGED_UNUSABLE
    if entry.st_uid != coordinator_uid:
        return REASON_STAGED_UNUSABLE
    if stat.S_IMODE(entry.st_mode) != _DIRECTORY_MODE:
        return REASON_STAGED_UNUSABLE
    try:
        present = _commitment_of(final)
    except PackageError:
        # A partially staged tree cannot reach this name — publication is one
        # rename of an already-committed tree — so a tree here that will not
        # validate is residue nobody can account for. It is reported, and it is
        # emphatically not removed: silently deleting what somebody else put
        # there is how a cleanup becomes an attack.
        return REASON_STAGED_UNUSABLE
    except OSError:
        return REASON_STAGED_UNUSABLE
    # The one place the word collision is literal: this identity is derived
    # from a commitment, and what is here does not commit to it.
    return None if present == digest else REASON_STAGED_COLLISION


def _write_member(name: str, body: bytes, dir_fd: int) -> None:
    """Create one staged file exclusively and write it whole, or refuse."""
    handle = os.open(name, _CREATE_FLAGS, _MEMBER_MODE, dir_fd=dir_fd)
    try:
        written = 0
        while written < len(body):
            step = os.write(handle, body[written:])
            if step <= 0:
                raise OSError(f"the staged member {name!r} stopped before the end")
            written += step
        os.fsync(handle)
    finally:
        os.close(handle)


def _materialise(tree, staging: Path) -> None:
    """Write the walked tree into the coordinator's staging directory.

    Every directory the walk saw is created, including ones that hold only
    other directories, so the copy is the tree rather than a flattening of it.
    Modes are tightened afterwards, deepest first, because a directory set
    read-only before its children are written cannot receive them.
    """
    for relative in tree.directories:
        os.makedirs(staging.joinpath(*relative), mode=_STAGING_MODE)
    for member in tree.files:
        parent = staging.joinpath(*member.relative_path[:-1])
        handle = os.open(parent, _DIR_FLAGS)
        try:
            _write_member(member.relative_path[-1], member.data, handle)
            os.fsync(handle)
        finally:
            os.close(handle)
    for relative in sorted(tree.directories, key=len, reverse=True):
        os.chmod(staging.joinpath(*relative), _DIRECTORY_MODE)
    os.chmod(staging, _DIRECTORY_MODE)


def resolve_and_stage_package(*, evidence, approved_artifact_root: Any,
                              trusted_source_uid: Any, staging_root: Any,
                              coordinator_uid: Any) -> StagedPackage:
    """Verify the governed package tree and stage it by its commitment.

    A supported result means a tree was verified and published. **It is not
    permission to execute it** — no adapter exists, and this module could not
    reach one if it did.
    """
    if not isinstance(coordinator_uid, int) or isinstance(coordinator_uid, bool):
        return _refused(REASON_STAGING_ROOT)
    root = _usable_staging_root(staging_root, coordinator_uid)
    if root is None:
        return _refused(REASON_STAGING_ROOT)

    if evidence.manifest_reference is None:
        return _refused(REASON_MANIFEST_ABSENT)
    manifest_relative = _relative_from_reference(evidence.manifest_reference,
                                                 _FILE_SCHEME)
    tree_relative = _relative_from_reference(evidence.artifact_reference,
                                             _TREE_SCHEME)
    if manifest_relative is None or tree_relative is None:
        return _refused(REASON_GRAMMAR)

    # --- the manifest, from its own descriptor ------------------------------
    try:
        handle = open_trusted_regular_file(
            approved_artifact_root, manifest_relative,
            expected_uid=trusted_source_uid, require_single_link=True,
            maximum_bytes=MANIFEST_MAXIMUM_BYTES, refuse_oversize=True)
    except TrustedSourceError:
        return _refused(REASON_MANIFEST_UNREADABLE)
    try:
        raw = _bounded_read(handle, MANIFEST_MAXIMUM_BYTES)
    except (TrustedSourceError, OSError):
        return _refused(REASON_MANIFEST_UNREADABLE)
    finally:
        os.close(handle)

    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return _refused(REASON_MANIFEST_MALFORMED)
    manifest, reason = _validated_manifest(body, evidence)
    if reason is not None:
        return _refused(reason)
    expected_digest = manifest["package_tree_sha256"]
    final = root / f"{_STAGED_PREFIX}{expected_digest[len(_DIGEST_PREFIX):]}"

    # --- a tree already published under this commitment ---------------------
    #
    # Asked before the source is read, not after: the staged tree is
    # re-inspected in full and must commit to exactly this identity, so walking
    # the source again would answer a question already answered — and would
    # build a second complete copy only to discard it.
    if final.exists() or final.is_symlink():
        problem = _existing_staged(final, expected_digest, coordinator_uid)
        if problem is not None:
            return _refused(problem)
        return _supported(manifest, evidence, expected_digest, final)

    # --- the source tree, opened once and walked through that descriptor ----
    #
    # `open_trusted_directory` refuses a source root that is a symlink, a
    # regular file, or anything outside the approved root. `walk_tree` refuses
    # every descendant symlink, FIFO, socket, device, hard link and mount
    # crossing, and refuses a file that changed while it was being read — which
    # is the mutation-during-staging case, detected rather than raced.
    try:
        source = open_trusted_directory(approved_artifact_root, tree_relative,
                                        expected_uid=trusted_source_uid)
    except TrustedSourceError:
        return _refused(REASON_TREE_UNREADABLE)
    try:
        try:
            walked = walk_tree(
                source, maximum_depth=PACKAGE_MAXIMUM_DEPTH,
                maximum_entries=MAXIMUM_ENTRIES, maximum_files=MAXIMUM_ENTRIES,
                maximum_file_bytes=MAXIMUM_FILE_BYTES,
                maximum_total_bytes=MAXIMUM_AGGREGATE_BYTES)
        except TraversalRefused as error:
            return _refused(REASON_TREE_MUTATED
                            if error.reason is TraversalReason.RACED
                            else REASON_TREE_UNREADABLE)
        except OSError:
            return _refused(REASON_TREE_UNREADABLE)
    finally:
        os.close(source)

    # A rehearsal has now done every read the write does: the manifest is
    # validated, the destination is known, and the source tree has been walked
    # in full with every symlink, size, depth and race refusal applied. The next
    # statement is the first irreversible one, so this is where it stops. The
    # commitment reported is the manifest's, which is exactly the identity the
    # published tree would be required to carry.
    if is_rehearsing():
        return _supported(manifest, evidence, expected_digest, final)

    # --- build, commit, and publish with one rename -------------------------
    #
    # The commitment is derived from the finished copy rather than from the
    # source, so the identity names the immutable tree that reaches execution.
    # The name is chosen only once that commitment exists, which is why the
    # tree is built somewhere the runtime named and moved afterwards.
    staging = Path(tempfile.mkdtemp(dir=str(root), prefix=".staging-"))
    published = False
    try:
        try:
            _materialise(walked, staging)
        except OSError:
            return _refused(REASON_STAGED_UNUSABLE)

        try:
            observed = _commitment_of(staging)
        except PackageError:
            return _refused(REASON_TREE_UNGOVERNED)
        except OSError:
            return _refused(REASON_STAGED_UNUSABLE)
        if observed != expected_digest:
            return _refused(REASON_SUBSTITUTION)

        try:
            # `rename` onto an existing non-empty directory fails, so this
            # never replaces a published tree. What it is not is a general
            # atomic install: an empty directory at the name would be
            # replaced, which is why the published-tree check above runs first
            # and the installed tree is re-verified below.
            os.rename(staging, final)
            published = True
        except OSError:
            # Another caller published under this commitment first. Validate
            # theirs rather than assuming, and never replace it. Our own copy
            # stays as residue: two coordinators racing on one commitment is
            # something an operator should be able to see happened.
            problem = _existing_staged(final, expected_digest, coordinator_uid)
            if problem is not None:
                return _refused(problem)
            return _supported(manifest, evidence, expected_digest, final)
    finally:
        # The only staging tree this removes is one it exclusively created and
        # did not publish. A refused staging tree is left where an operator can
        # find it, under a name no consumer resolves.
        if not published:
            _abandon(staging)

    # --- the published tree, re-verified ------------------------------------
    problem = _existing_staged(final, expected_digest, coordinator_uid)
    if problem is not None:
        return _refused(problem)
    return _supported(manifest, evidence, expected_digest, final)


def _abandon(staging: Path) -> None:
    """Leave an unpublished staging tree readable to the operator who owns it."""
    try:
        os.chmod(staging, _STAGING_MODE)
    except OSError:
        pass


def _supported(manifest, evidence, digest: str, final: Path) -> StagedPackage:
    return StagedPackage(
        True, None,
        capability_package_id=evidence.capability_package_id,
        contract_id=evidence.contract_id,
        capability_id=evidence.capability_id,
        package_tree_sha256=digest,
        staged_path=str(final),
        manifest_version=manifest["schema_version"],
    )
