"""The one question the execution identity may ask its rootless image store.

``worker.ImageStore`` is a protocol with a single method, and this is its first
real implementation. The narrowness is the design: `require_image_present`
already holds the identity — a bare 64-character lowercase hex local image ID
that `CIMP` resolution produced against a namespace the coordinator cannot
write — and needs one boolean back. Presence is not authority, and a store that
could *choose* an image would be making the decision `CIMP` already made.

**It runs no process, and Podman is not invoked.** `kyri-exec-quota` sets an
XFS project through `FS_IOC_FSSETXATTR` rather than by driving `xfs_quota`, for
the reason stated there: a subprocess is a second program with its own argument
parsing, its own environment, and its own failure modes, none of which this
boundary can constrain. The same reasoning applies here, and the whole
`tools/capability` package is asserted to import no `subprocess` at all. So
presence is answered by **reading** the store the execution identity owns —
which is also what lets the success record say ``podman_invoked: false`` and
mean it literally.

**It reads one file, in one place, chosen by nobody.** With ``XDG_DATA_HOME``
unset — and the transition's environment is exactly ``HOME`` and
``XDG_RUNTIME_DIR`` — containers/storage resolves its graphroot to
``$HOME/.local/share/containers/storage``, the tree Track B provisioned, and
records local images in ``overlay-images/images.json``. The driver is
compiled in rather than discovered: searching for whichever driver directory
happens to exist would let the layout answer a question about authority.

**Every uncertainty is a refusal, never an absence.** A missing store, an
unreadable index, a store owned by somebody else, malformed JSON, an oversized
file — each raises, and `require_image_present` turns any exception into a
refusal to execute. "I could not tell" and "it is not there" are different
facts, and only one of them is safe to act on.

**This is not a container-runtime binding.** Driving a container needs
``create_argv`` and the terminal actions behind it, and none of that is here or
reachable from here. The G6.1 verification worker imports this module; it must
remain true after that import that no container can be created.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §9 and
§27, and the G6.1 milestone.
"""

from __future__ import annotations

import json
import os
import stat as stat_module

# The rootless graphroot, relative to HOME, and the driver whose image index is
# read. Both compiled in: a store location taken from the environment is a
# store an attacker can aim.
GRAPHROOT_RELATIVE = (".local", "share", "containers", "storage")
IMAGE_INDEX = ("overlay-images", "images.json")

# The one environment variable this needs, and the one the transition sets.
HOME_VARIABLE = "HOME"

# Generous for an index of a handful of admitted images, and small enough that
# a store which has grown pathological is refused rather than read.
MAXIMUM_INDEX_BYTES = 4 * 1024 * 1024

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

_HEX = frozenset("0123456789abcdef")


class ImageStoreUnreadable(RuntimeError):
    """The store could not be consulted.

    Raised rather than answered ``False``. ``require_image_present`` treats any
    exception as a refusal, which is the correct outcome: an unreadable store
    is not an absent image and must not be allowed to become one.
    """


class RootlessImageStore:
    """The execution identity's own store, asked one question.

    Holds no state and caches nothing. A cached presence answer is a claim
    about a moment that has passed, and the only moment that matters is this
    one.

    ``home`` and ``owner`` exist so a test can point this at a fixture tree
    belonging to the identity running the test. They are not a widening: the
    production caller supplies neither, the defaults come from the process the
    transition created, and no value here reaches a second program.
    """

    __slots__ = ("_home", "_owner")

    def __init__(self, *, home: str | None = None, owner: int | None = None) -> None:
        self._home = home
        self._owner = owner

    def _graphroot(self) -> str:
        home = self._home
        if home is None:
            home = os.environ.get(HOME_VARIABLE)
        if not home or not home.startswith("/"):
            raise ImageStoreUnreadable(
                f"{HOME_VARIABLE} is unset or not absolute, so the store this "
                f"identity owns cannot be identified")
        return os.path.join(home, *GRAPHROOT_RELATIVE)

    def _index_bytes(self) -> bytes:
        """The image index, read no-follow and descriptor-relatively, or refuse.

        Each component is opened from the one above with ``O_NOFOLLOW``, so a
        replaced directory or a symlinked index is refused rather than
        followed — the same rule the handoff verification uses, and for the
        same reason.
        """
        owner = self._owner if self._owner is not None else os.geteuid()
        try:
            handle = os.open(self._graphroot(), _DIR_FLAGS)
        except OSError as error:
            raise ImageStoreUnreadable(
                f"the rootless store is unusable: {error}") from None
        try:
            directory, name = IMAGE_INDEX
            try:
                nested = os.open(directory, _DIR_FLAGS, dir_fd=handle)
            except OSError as error:
                raise ImageStoreUnreadable(
                    f"the store has no {directory} index: {error}") from None
            try:
                try:
                    index = os.open(name, _READ_FLAGS, dir_fd=nested)
                except OSError as error:
                    raise ImageStoreUnreadable(
                        f"the image index is unusable: {error}") from None
                try:
                    info = os.fstat(index)
                    if not stat_module.S_ISREG(info.st_mode):
                        raise ImageStoreUnreadable(
                            "the image index is not a regular file")
                    if info.st_uid != owner:
                        raise ImageStoreUnreadable(
                            f"the image index is owned by {info.st_uid}, and this "
                            f"identity is {owner}; it is not this identity's store")
                    if info.st_size > MAXIMUM_INDEX_BYTES:
                        raise ImageStoreUnreadable(
                            "the image index exceeds the governed bound")
                    body = os.read(index, MAXIMUM_INDEX_BYTES + 1)
                except OSError as error:
                    raise ImageStoreUnreadable(
                        f"the image index could not be read: {error}") from None
                finally:
                    os.close(index)
            finally:
                os.close(nested)
        finally:
            os.close(handle)
        if len(body) > MAXIMUM_INDEX_BYTES:
            raise ImageStoreUnreadable("the image index exceeds the governed bound")
        return body

    def _identities(self) -> frozenset[str]:
        """Every local image ID the store records, or refuse.

        Only the ``id`` field is read. Names, tags, digests and history are
        deliberately ignored: the identity was decided by `CIMP` resolution,
        and anything here that could be matched against a *name* would be a
        route by which the store chose what runs.
        """
        try:
            document = json.loads(self._index_bytes().decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            raise ImageStoreUnreadable(
                f"the image index is not readable JSON: {error}") from None
        if not isinstance(document, list):
            raise ImageStoreUnreadable("the image index is not a list of images")
        found = set()
        for entry in document:
            if not isinstance(entry, dict):
                raise ImageStoreUnreadable("the image index holds a non-image entry")
            identity = entry.get("id")
            # A record without a usable ID is skipped rather than refused: it
            # cannot be the image being asked about, and refusing the whole
            # store because of an unrelated record would be a denial of service
            # dressed as caution.
            if isinstance(identity, str) and len(identity) == 64 \
                    and not (set(identity) - _HEX):
                found.add(identity)
        return frozenset(found)

    def present(self, oci_image_id: str) -> bool:
        """True if exactly this local image ID exists in this identity's store.

        The identity is revalidated here even though `require_image_present`
        already validated it. This is the boundary at which a value becomes a
        lookup key against material outside this process, and a validator that
        only runs on the other side of a call is one refactor away from not
        running.
        """
        if not isinstance(oci_image_id, str) or len(oci_image_id) != 64 \
                or set(oci_image_id) - _HEX:
            raise ImageStoreUnreadable(
                "the store may only be asked about a bare 64-hex image ID")
        return oci_image_id in self._identities()


__all__ = ["GRAPHROOT_RELATIVE", "IMAGE_INDEX", "ImageStoreUnreadable",
           "RootlessImageStore"]
