"""Turning a governed package into verified bytes, or refusing.

**The source path is discovery input. The staged object is the answer.** The
two are joined by exactly one descriptor: the artefact is opened once through
the reviewed trusted-source primitive, its digest computed from that
descriptor, and the staged copy written from that same descriptor. The source
pathname is never reopened for authoritative bytes, because a pathname read
twice is two different questions asked of whoever can write the directory.

**What the integrity claim actually is**, stated the way the specification
states it rather than flatteringly: the staged bytes match the digest declared
by a manifest that was read from a repository satisfying the trusted-source
ownership, mode, and link contract, and that manifest is coherently bound to
the governed package identities the Fabric evidence already verified. The
manifest is **not** an independent cryptographic root of trust, and nothing
here should be read as claiming it is. Stronger governed content binding is
Deferred F.

**Staging is content-addressed, so no caller-controlled name becomes an
identity.** The final object lives at `sha256-<hex>/artifact`, mode `0400`
inside a `0700` directory, published by exclusive link so an existing object is
never overwritten. An object already there is validated and reused, or refused
— never repaired, never replaced, never chmod'ed back into shape.

**This module writes in one place and for one reason:** the staging root. It
creates no capability record, allocates no identity, and touches nothing on the
source side. It reads and hashes an artefact; it never imports, loads, or runs
one, whatever the bytes happen to look like.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from ..common.trusted_source import (TrustedSourceError,
                                     open_trusted_regular_file)

# Hard architecture limits for schema version 1. Raising either is a decision,
# not a constant edit made under pressure.
MANIFEST_MAXIMUM_BYTES = 65536
ARTIFACT_MAXIMUM_BYTES = 268435456

MANIFEST_SCHEMA_VERSION = 1

# Closed schema: exactly these, and an unknown field refuses. A manifest that
# tolerates fields nobody reviewed is one whose meaning grows unnoticed.
MANIFEST_FIELDS = ("schema_version", "capability_package_id", "contract_id",
                   "capability_id", "artifact_reference", "artifact_sha256")

_SCHEME = "file:"
_HEX = frozenset("0123456789abcdef")
_DIGEST_PREFIX = "sha256:"
_DIGEST_LENGTH = len(_DIGEST_PREFIX) + 64
_STAGED_NAME = "artifact"
_DIRECTORY_MODE = 0o700
_ARTIFACT_MODE = 0o400
_CHUNK = 1024 * 256

REASON_GRAMMAR = "artifact-reference-outside-grammar"
REASON_MANIFEST_ABSENT = "manifest-reference-absent"
REASON_MANIFEST_UNREADABLE = "manifest-not-readable"
REASON_MANIFEST_MALFORMED = "manifest-not-valid-json"
REASON_MANIFEST_SCHEMA = "manifest-schema-invalid"
REASON_MANIFEST_IDENTITY = "manifest-identity-mismatch"
REASON_ARTIFACT_UNREADABLE = "artifact-not-readable"
REASON_ARTIFACT_OVERSIZE = "artifact-too-large"
REASON_SUBSTITUTION = "substitution-detected"
REASON_STAGING_ROOT = "staging-root-unusable"
REASON_STAGED_UNUSABLE = "staged-object-unusable"
REASON_STAGED_COLLISION = "staged-digest-collision"


@dataclass(frozen=True)
class StagedArtifact:
    """Verified preparation facts. Nothing here runs anything."""

    supported: bool
    reason: str | None = None
    capability_package_id: str | None = None
    contract_id: str | None = None
    capability_id: str | None = None
    artifact_sha256: str | None = None
    staged_path: str | None = None
    manifest_version: int | None = None


def _refused(reason: str) -> StagedArtifact:
    return StagedArtifact(False, reason)


def _relative_from_reference(reference: Any) -> str | None:
    """The relative path a `file:` reference names, or `None`.

    Nothing is inferred. A reference without the scheme, with an authority, or
    naming an absolute path is refused rather than interpreted charitably.
    """
    if not isinstance(reference, str):
        return None
    if not reference.startswith(_SCHEME):
        return None
    remainder = reference[len(_SCHEME):]
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


def _bounded_digest_and_copy(descriptor: int, destination: int | None,
                             limit: int) -> str:
    """Hash from one descriptor, optionally copying the same bytes out.

    The bound is enforced **while reading**, not from the size the descriptor
    reported: a file that grows between `fstat` and the read must not slip past
    on the strength of what it used to be.
    """
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(descriptor, _CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise TrustedSourceError("the artefact exceeds its bound while reading")
        digest.update(chunk)
        if destination is not None:
            offset = 0
            while offset < len(chunk):
                offset += os.write(destination, chunk[offset:])
    return f"{_DIGEST_PREFIX}{digest.hexdigest()}"


def _validated_manifest(body: Any, evidence) -> tuple[dict[str, Any] | None, str | None]:
    """Schema version 1, closed, and bound to the verified identities."""
    if not isinstance(body, dict):
        return None, REASON_MANIFEST_MALFORMED
    if set(body) != set(MANIFEST_FIELDS):
        return None, REASON_MANIFEST_SCHEMA

    version = body["schema_version"]
    # A bool is an int in Python; a manifest saying `true` is not saying `1`.
    if isinstance(version, bool) or not isinstance(version, int):
        return None, REASON_MANIFEST_SCHEMA
    if version != MANIFEST_SCHEMA_VERSION:
        return None, REASON_MANIFEST_SCHEMA

    for field in ("capability_package_id", "contract_id", "capability_id",
                  "artifact_reference"):
        if not isinstance(body[field], str) or not body[field]:
            return None, REASON_MANIFEST_SCHEMA
    if not _valid_digest(body["artifact_sha256"]):
        return None, REASON_MANIFEST_SCHEMA
    if _relative_from_reference(body["artifact_reference"]) is None:
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


def _existing_staged(final: Path, digest: str, coordinator_uid: int) -> str | None:
    """Whether an object already there may be reused, or why it may not.

    Returns `None` when it is sound and reusable. Nothing is repaired: a staged
    object that disagrees with its own digest is reported, not replaced.
    """
    try:
        entry = final.lstat()
    except OSError:
        return REASON_STAGED_UNUSABLE
    if stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode):
        return REASON_STAGED_UNUSABLE
    if entry.st_uid != coordinator_uid:
        return REASON_STAGED_UNUSABLE
    if stat.S_IMODE(entry.st_mode) != _ARTIFACT_MODE:
        return REASON_STAGED_UNUSABLE
    # Link count is deliberately not checked here. Exclusive publication links
    # the temporary into place and then removes it, so a concurrent caller sees
    # two links for an instant during entirely correct operation. What keeps a
    # second link from being an attack is the enclosing 0700 coordinator-owned
    # directory, not a count observed at a moment nobody controls.
    try:
        handle = os.open(final, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError:
        return REASON_STAGED_UNUSABLE
    try:
        present = _bounded_digest_and_copy(handle, None, ARTIFACT_MAXIMUM_BYTES)
    except TrustedSourceError:
        return REASON_STAGED_COLLISION
    finally:
        os.close(handle)
    # The one place the word collision is literal: this identity is derived
    # from a digest, and what is here does not hash to it.
    return None if present == digest else REASON_STAGED_COLLISION


def resolve_and_stage_package(*, evidence, approved_artifact_root: Any,
                              trusted_source_uid: Any, staging_root: Any,
                              coordinator_uid: Any) -> StagedArtifact:
    """Verify the governed package's artefact and stage it by content.

    A supported result means bytes were verified and published. **It is not
    permission to execute them** — no adapter exists, and this module could not
    reach one if it did.
    """
    if not isinstance(coordinator_uid, int) or isinstance(coordinator_uid, bool):
        return _refused(REASON_STAGING_ROOT)
    root = _usable_staging_root(staging_root, coordinator_uid)
    if root is None:
        return _refused(REASON_STAGING_ROOT)

    if evidence.manifest_reference is None:
        return _refused(REASON_MANIFEST_ABSENT)
    manifest_relative = _relative_from_reference(evidence.manifest_reference)
    artifact_relative = _relative_from_reference(evidence.artifact_reference)
    if manifest_relative is None or artifact_relative is None:
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
    expected_digest = manifest["artifact_sha256"]

    # --- the artefact, opened once ------------------------------------------
    try:
        source = open_trusted_regular_file(
            approved_artifact_root, artifact_relative,
            expected_uid=trusted_source_uid, require_single_link=True,
            maximum_bytes=ARTIFACT_MAXIMUM_BYTES, refuse_oversize=True)
    except TrustedSourceError as error:
        return _refused(REASON_ARTIFACT_OVERSIZE if "larger" in str(error)
                        else REASON_ARTIFACT_UNREADABLE)

    try:
        try:
            observed = _bounded_digest_and_copy(source, None, ARTIFACT_MAXIMUM_BYTES)
        except TrustedSourceError:
            return _refused(REASON_ARTIFACT_OVERSIZE)
        except OSError:
            return _refused(REASON_ARTIFACT_UNREADABLE)
        if observed != expected_digest:
            return _refused(REASON_SUBSTITUTION)

        final_directory = root / f"sha256-{expected_digest[len(_DIGEST_PREFIX):]}"
        final = final_directory / _STAGED_NAME

        if final.exists() or final.is_symlink():
            problem = _existing_staged(final, expected_digest, coordinator_uid)
            if problem is not None:
                return _refused(problem)
            return _supported(manifest, evidence, expected_digest, final)

        # --- publish, from the same descriptor ------------------------------
        try:
            os.lseek(source, 0, os.SEEK_SET)
        except OSError:
            return _refused(REASON_ARTIFACT_UNREADABLE)

        # The temporary name is the runtime's, never the caller's.
        descriptor, temporary = tempfile.mkstemp(dir=str(root), prefix=".staging-",
                                                 suffix=".tmp")
        published = False
        try:
            copied = _bounded_digest_and_copy(source, descriptor,
                                              ARTIFACT_MAXIMUM_BYTES)
            if copied != expected_digest:
                return _refused(REASON_SUBSTITUTION)
            os.fsync(descriptor)
            os.fchmod(descriptor, _ARTIFACT_MODE)
            os.close(descriptor)
            descriptor = None

            try:
                final_directory.mkdir(mode=_DIRECTORY_MODE, exist_ok=True)
            except OSError:
                return _refused(REASON_STAGED_UNUSABLE)

            try:
                # `link` refuses an existing destination; `rename` would
                # replace it. Publication must never overwrite.
                os.link(temporary, final)
                published = True
            except FileExistsError:
                # Another caller published the same content first. Validate
                # theirs rather than assuming, and never replace it.
                problem = _existing_staged(final, expected_digest, coordinator_uid)
                if problem is not None:
                    return _refused(problem)
                published = True
            except OSError:
                return _refused(REASON_STAGED_UNUSABLE)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            # The only temporary this ever removes is one it exclusively
            # created and successfully published. A failed publication's
            # residue is left where an operator can find it.
            if published:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass

        # --- the published object, re-verified ------------------------------
        problem = _existing_staged(final, expected_digest, coordinator_uid)
        if problem is not None:
            return _refused(problem)
        return _supported(manifest, evidence, expected_digest, final)
    finally:
        os.close(source)


def _supported(manifest, evidence, digest: str, final: Path) -> StagedArtifact:
    return StagedArtifact(
        True, None,
        capability_package_id=evidence.capability_package_id,
        contract_id=evidence.contract_id,
        capability_id=evidence.capability_id,
        artifact_sha256=digest,
        staged_path=str(final),
        manifest_version=manifest["schema_version"],
    )
