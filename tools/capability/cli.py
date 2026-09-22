"""Command line interface for the Capability Runtime.

Three operations, and nothing more. `invoke` carries one governed selection
through preparation and stops; `inspect` and `validate` read. **There is no
execution verb and no flag that could become one** — the commands that would
run a capability do not exist, and neither does the mechanism they would call.

**Nothing authority-bearing is inferred.** Every root, every expected owner,
the actor, the identity, the instant: supplied explicitly, or refused. No
default store root, no environment value, no home directory, no current user,
no clock, and no generated identity. A default is a decision nobody recorded
making.

**The payload arrives as a file inside an approved payload directory**, opened
through the reviewed descriptor-safe primitive and read from that descriptor.
That directory bounds and safely reads caller input; it establishes nothing
about the payload's meaning. Authority comes from canonicalising the logical
value and binding its digest to the invocation — not from where the file sat.

**Duplicate object keys refuse.** A permissive parser silently keeps the last
one, so `{"a":1,"a":2}` would quietly become a different payload than it looks
like and then receive a perfectly valid digest. Two exit codes separate the
kinds of failure: 2 means the request was unusable, 1 means it was understood
and the answer is no.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from ..common.trusted_source import (TrustedSourceError,
                                     open_trusted_regular_file)
from . import fabric_evidence
from .fabric_evidence import verify_selected_evidence
from .execution import image_store, implementation_authority
from .rehearsal import rehearsing
from .coordinator import execute_supervised, prepare_invocation
from .errors import CapabilityError
from .execution.backing_store import (BackingStoreError, ObservedFilesystem,
                                      verify_backing_store)
from .execution.launch import (HANDOFF_ROOT, LaunchError, authorise_launch,
                               supervised_binding)
from .inspection import STATUS_NOT_FOUND, STATUS_REPORTED, inspect_records, validate_store
from .store import CapabilityStore

EXIT_SUCCESS = 0
EXIT_DENIED = 1
EXIT_USAGE = 2

# The normative host layout, compiled in rather than offered as arguments.
#
# This is not the "no default store root" rule being bent. A default is a value
# the caller could have supplied and did not, so the code picked one; these are
# values the caller *cannot* supply at all, which is the stronger statement and
# the one the rest of the execution plane already makes. The privileged
# transition compiles in the same two roots on its side, so the ceremony and the
# boundary that consumes it agree by construction rather than by an operator
# keeping two flags consistent.
#
# `invoke`, `inspect` and `validate` still take an explicit `--store-root`:
# those verbs legitimately run against a store an operator chose. This one
# produces material root will later read from one fixed place, so choosing
# another place could only produce a ceremony nothing consumes.
#
# The two `prod-path-reference` markers below are the repository's own
# mechanism for a line that legitimately names a production path. These are not
# defaults -- nothing here creates either path, and no argument can override
# them; both are read-only inputs this verb refuses to run without.
#
# G11-BC-Y drew the line the other way for the administrative verbs. `abandon`
# had been given the compiled-in root by analogy with `authorise-launch`, and
# the analogy was false: nothing downstream of it compiles in a matching root,
# so the argument for agreement-by-construction did not apply -- while the
# hazard did. A rehearsal substituted the runtime path through every shell gate
# it ran, and the mutation resolved `CAPABILITY_RUNTIME_ROOT` anyway. The gates
# proved a fixture and the writer wrote production.
#
# So every administrative mutator below takes `--store-root` and has no
# default. Omission is a usage error before any store is opened. The production
# ceremony has to spell `/data/kyri/capability-runtime` out, and a rehearsal
# that means a fixture has to say so in the one place the writer reads.
# Which refusals belong to which gate, so a rehearsal can report the two apart
# rather than making an operator infer it from one combined verdict. Named from
# the boundary's own vocabulary rather than restated as strings here.
_SCOPE_REASONS = frozenset({
    fabric_evidence.REASON_OPERATION,
    fabric_evidence.REASON_OPERATION_ABSENT,
    fabric_evidence.REASON_CAPABILITY_SCOPE,
    fabric_evidence.REASON_CLASSIFICATION_SCOPE,
    fabric_evidence.REASON_TARGET_SCOPE,
    fabric_evidence.REASON_SCOPE,
})
_ELIGIBILITY_REASONS = frozenset({
    fabric_evidence.REASON_INELIGIBLE,
    fabric_evidence.REASON_WINDOW,
    fabric_evidence.REASON_NOT_ADMITTED,
    fabric_evidence.REASON_SUPERSEDED,
})

CAPABILITY_RUNTIME_ROOT = "/data/kyri/capability-runtime"
AUTHORITY_ROOT = "/var/lib/kyri/implementation-authority"   # prod-path-reference
BACKING_STORE_CONFIG = "/etc/kyri/backing-store.json"       # prod-path-reference


# Read from the bridge so the two can never disagree about what it spells.
from .execution.abandonment import REASONS as _ABANDONMENT_REASONS
from .execution.provenance import CORRECTABLE_FIELDS as _CORRECTABLE_FIELDS
from .execution.provenance import FINDINGS as _CORRECTION_FINDINGS
from .execution.provenance import INITIATORS as _CORRECTION_INITIATORS
from .execution.launch import LIFECYCLE_STATE as LAUNCH_AUTHORIZED_STATE

_MOUNTINFO = "/proc/self/mountinfo"
_BY_UUID = "/dev/disk/by-uuid"
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

# Invocation input is structured control content, not bulk artefact content.
# Anything large belongs behind a governed package reference.
PAYLOAD_MAXIMUM_BYTES = 1048576


class _Unusable(Exception):
    """The request could not be carried out as stated. Exit code 2."""


class _DuplicateKey(ValueError):
    """One JSON object carried the same key twice."""


def _no_duplicates(pairs):
    """A JSON object, refusing a repeated key at any depth.

    The hook fires for every object, so nesting is covered without walking the
    result afterwards.
    """
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise _DuplicateKey(f"duplicate object key '{key}'")
        seen[key] = value
    return seen


def _emit(payload: Any) -> None:
    """Deterministic JSON on stdout. Diagnostics never go here."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _instant(value: Any, name: str) -> datetime:
    if not isinstance(value, str):
        raise _Unusable(f"{name} must be supplied as a timestamp")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise _Unusable(f"{name} is not a readable timestamp") from None
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        raise _Unusable(f"{name} must carry a timezone offset")
    return parsed


def _payload(approved_payload_root: Any, name: Any, payload_source_uid: Any) -> Any:
    """One logical payload, from bytes read through one descriptor."""
    try:
        handle = open_trusted_regular_file(
            approved_payload_root, name, expected_uid=payload_source_uid,
            require_single_link=True, maximum_bytes=PAYLOAD_MAXIMUM_BYTES,
            refuse_oversize=True)
    except TrustedSourceError as error:
        raise _Unusable(f"the payload file could not be read ({error})") from None

    chunks: list[bytes] = []
    total = 0
    try:
        while True:
            chunk = os.read(handle, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > PAYLOAD_MAXIMUM_BYTES:
                raise _Unusable("the payload exceeds its bound")
            chunks.append(chunk)
    except OSError:
        raise _Unusable("the payload file could not be read") from None
    finally:
        os.close(handle)

    try:
        text = b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError:
        raise _Unusable("the payload is not valid UTF-8") from None

    decoder = json.JSONDecoder(object_pairs_hook=_no_duplicates)
    try:
        value, consumed = decoder.raw_decode(text.lstrip())
    except _DuplicateKey as error:
        raise _Unusable(f"the payload carries a {error}") from None
    except ValueError:
        raise _Unusable("the payload is not one valid JSON value") from None
    # Exactly one document: trailing content is a second payload nobody asked
    # about, and silently ignoring it hides which one was bound.
    if text.lstrip()[consumed:].strip():
        raise _Unusable("the payload carries more than one JSON value")
    return value


def _runtime_store(args) -> CapabilityStore:
    try:
        return CapabilityStore(args.store_root, expected_uid=args.expected_uid,
                               expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(f"the capability runtime store is unusable ({error})") from None


def command_invoke(args) -> int:
    """One governed invocation, prepared and then stopped."""
    if getattr(args, "preflight", False):
        return command_preflight(args)
    payload = _payload(args.approved_payload_root, args.payload_file,
                       args.payload_source_uid)
    requested_at = _instant(args.requested_at, "--requested-at")
    store = _runtime_store(args)
    decision = prepare_invocation(
        store, fabric_root=args.fabric_root,
        fabric_expected_uid=args.fabric_expected_uid,
        fabric_expected_gid=args.fabric_expected_gid,
        approved_artifact_root=args.approved_artifact_root,
        trusted_source_uid=args.trusted_source_uid,
        staging_root=args.staging_root, coordinator_uid=args.coordinator_uid,
        selection_id=args.selection_id, instance_id=args.instance_id,
        capability_package_id=args.package_id, operation=args.operation,
        trust_root=args.trust_store_root, invocation_id=args.invocation_id,
        payload=payload, actor=args.actor, request_id=args.request_id,
        requested_at=requested_at)
    _emit({
        "status": decision.status, "reason": decision.reason,
        "invocation_id": decision.invocation_id,
        "invocation_record_id": decision.invocation_record_id,
        "result_record_id": decision.result_record_id,
        "binding_digest": decision.binding_digest,
        "payload_digest": decision.payload_digest,
        "artifact_digest": decision.artifact_digest,
        "staged_path": decision.staged_path,
    })
    # Every outcome reachable here is a governed negative: a preparation that
    # cannot proceed, a refusal, a replay, or a conflict.
    return EXIT_DENIED


def _execution_outlook(evidence) -> dict:
    """What the execution plane would say, asked read-only.

    Reported as separate fields rather than folded into one verdict, because an
    operator preparing a first invocation needs to know *which* of these is
    missing. None of it is required for preparation to succeed -- preparation
    ends before the adapter -- so none of it makes a rehearsal refuse.
    """
    outlook = {
        "implementation_id": None,
        "execution_backend": None,
        "argv_contract": None,
        "execution_image_id": None,
        "execution_image_available": False,
        "adapter_authorised": False,
        "privileged_helper_required": True,
    }
    try:
        authority = os.open(AUTHORITY_ROOT, _DIR_FLAGS)
    except OSError:
        return outlook
    try:
        generation = implementation_authority.current_generation(authority)
        entries = list(generation.entries)
        if not entries:
            return outlook
        cimp = entries[0].cimp
        admission = implementation_authority.resolve_implementation(
            authority, cimp, generation=generation)
        outlook["implementation_id"] = cimp
        outlook["execution_backend"] = admission.adapter_identity
        outlook["argv_contract"] = admission.argv_contract_identity
        outlook["execution_image_id"] = admission.oci_image_id
    except Exception:  # noqa: BLE001
        # An unreadable authority is reported as an unknown outlook, not as a
        # refusal: the preparation this rehearses does not consult it.
        return outlook
    finally:
        os.close(authority)

    try:
        store = image_store.RootlessImageStore()
        outlook["execution_image_available"] = bool(
            store.present(outlook["execution_image_id"]))
    except Exception:  # noqa: BLE001
        outlook["execution_image_available"] = False

    # Whether the privilege grant is *installed* is deliberately not reported
    # here. This surface may not read the elevation namespace, let alone use
    # it, and an operator asking what an invocation would need does not need
    # this command to tell them what they themselves installed. The helper
    # enforces its own authority; a preflight opinion about it would be a
    # second one.
    outlook.update(_supervision_outlook())
    return outlook


def _supervision_outlook() -> dict:
    """What supervision would need, asked read-only and answered honestly.

    **It mutates nothing and could not.** No helper is invoked, no
    reconciliation is run, no CINV or CRES is created, no snapshot is
    materialised and no container is created. Every field below is a read of an
    object root already published, and a failure to read one is reported as a
    failure to read it rather than as an absence.

    **A field this surface cannot observe says so.** The two privilege grants
    live in a namespace the coordinator may not read -- correctly, and by the
    same rule that keeps this command out of the elevation namespace at all.
    Reporting them as unobservable is the truthful answer; reporting them as
    absent would be a claim about something nobody here looked at, and naming
    the mechanism would be this surface reaching for it.
    """
    from .execution import helpers, identity

    report = {
        "coordinator_identity_authority": False,
        "execution_identity_authority": False,
        "execution_identity_account": None,
        "helper_compatibility": None,
        "helpers_blocking": [],
        "launch_grant": "unobservable",
        "reconcile_grant": "unobservable",
        "supervision_ready": False,
    }
    report["coordinator_identity_authority"] = os.path.exists(
        "/etc/kyri/coordinator-identity.json")            # prod-path-reference
    try:
        who = identity.read_execution_identity()
    except identity.ExecutionIdentityError:
        who = None
    if who is not None:
        report["execution_identity_authority"] = True
        report["execution_identity_account"] = who.account

    verdict = helpers.compatibility()
    report["helper_compatibility"] = verdict.verdict
    report["helpers_blocking"] = [
        {"path": helper.path, "state": helper.state, "purpose": helper.purpose}
        for helper in verdict.blocking]

    # Ready means every observable precondition holds. It is deliberately NOT
    # weakened by the two unobservable ones: a host that satisfies everything
    # here still has to satisfy sudoers, and the helper will refuse if it does
    # not. What this cannot see, it does not vouch for.
    report["supervision_ready"] = bool(
        report["coordinator_identity_authority"]
        and report["execution_identity_authority"]
        and verdict.compatible)
    return report


def command_preflight(args) -> int:
    """Rehearse one invocation, mutating nothing.

    **The store is only ever read.** It is opened through `open_for_read`, so an
    absent store is reported as absent rather than built and then described --
    which matters here, because the writing constructor creates the record
    directories and the sequence directory before any evidence is looked at.

    **The real preparation runs.** `prepare_invocation` is called under
    `rehearsing()`, so selected-evidence verification, current Fabric
    eligibility, the operation and scope gates, manifest validation and the full
    source-tree traversal all happen against the real stores. A rehearsal with
    its own copy of those rules would agree with the write until it did not.

    **It stops at the two irreversible acts**: the staging directory and the
    identifier allocation. So it reserves nothing, and the identifier it reports
    is a prediction another caller may take in between -- which is why the write
    path allocates for itself and verifies everything again.
    """
    payload = _payload(args.approved_payload_root, args.payload_file,
                       args.payload_source_uid)
    requested_at = _instant(args.requested_at, "--requested-at")
    try:
        store = CapabilityStore.open_for_read(
            args.store_root, expected_uid=args.expected_uid,
            expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(
            f"the capability runtime store is unusable ({error})") from None

    with rehearsing():
        decision = prepare_invocation(
            store, fabric_root=args.fabric_root,
            fabric_expected_uid=args.fabric_expected_uid,
            fabric_expected_gid=args.fabric_expected_gid,
            approved_artifact_root=args.approved_artifact_root,
            trusted_source_uid=args.trusted_source_uid,
            staging_root=args.staging_root,
            coordinator_uid=args.coordinator_uid,
            selection_id=args.selection_id, instance_id=args.instance_id,
            capability_package_id=args.package_id, operation=args.operation,
            trust_root=args.trust_store_root, invocation_id=args.invocation_id,
            payload=payload, actor=args.actor, request_id=args.request_id,
            requested_at=requested_at)

    would_accept = decision.reason is None
    evidence = verify_selected_evidence(
        args.fabric_root, expected_uid=args.fabric_expected_uid,
        expected_gid=args.fabric_expected_gid, selection_id=args.selection_id,
        instance_id=args.instance_id,
        capability_package_id=args.package_id, operation=args.operation,
        trust_root=args.trust_store_root, evaluated_at=requested_at)
    outlook = _execution_outlook(evidence)

    _emit({
        "outcome": "preflight",
        "would_accept": would_accept,
        "would_refuse_reason": decision.reason,
        "predicted_invocation_record_id": decision.invocation_record_id,
        "invocation_id": decision.invocation_id,
        "selection_id": args.selection_id,
        "instance_id": args.instance_id,
        "capability_package_id": args.package_id,
        "operation": args.operation,
        "actor": args.actor,
        "request_id": args.request_id,
        "requested_at": requested_at.isoformat(),
        "binding_digest": decision.binding_digest,
        "payload_digest": decision.payload_digest,
        "package_tree_sha256": decision.artifact_digest,
        "would_stage_at": decision.staged_path,
        # The two gates named separately, because "would it be accepted" does
        # not tell an operator which one moved.
        "current_eligibility": evidence.supported or (
            evidence.reason not in _ELIGIBILITY_REASONS),
        "scope_permits_operation": evidence.reason not in _SCOPE_REASONS,
        "eligibility_reasons": list(evidence.eligibility_reasons),
        **outlook,
    })
    return EXIT_SUCCESS if would_accept else EXIT_DENIED


def _observed_filesystem(path: str) -> ObservedFilesystem:
    """The host facts about the filesystem under ``path``, observed here.

    `verify_backing_store` cannot obtain a filesystem UUID from a descriptor —
    the kernel offers no such call — so the caller observes and it compares.
    Observation is this layer's authority and nothing more: every value below is
    read from the kernel, and any disagreement with the provisioned
    configuration is that module's refusal to make, not this one's.
    """
    target = os.path.realpath(path)
    best = ("", "", "")
    try:
        with open(_MOUNTINFO, "r", encoding="utf-8") as handle:
            for line in handle:
                fields = line.split()
                if "-" not in fields:
                    continue
                separator = fields.index("-")
                mount_point = fields[4]
                # The longest mount point that is a prefix of the target is the
                # filesystem the target actually sits on.
                if target == mount_point or target.startswith(
                        mount_point.rstrip("/") + "/"):
                    if len(mount_point) >= len(best[0]):
                        best = (mount_point, fields[separator + 1],
                                fields[separator + 2])
    except OSError:
        raise _Unusable("the mount table could not be read") from None
    if not best[0]:
        raise _Unusable(f"no mounted filesystem carries {path}")

    mount_point, filesystem_type, device_name = best
    uuid = ""
    try:
        for entry in os.listdir(_BY_UUID):
            if os.path.realpath(os.path.join(_BY_UUID, entry)) == \
                    os.path.realpath(device_name):
                uuid = entry
                break
    except OSError:
        uuid = ""
    return ObservedFilesystem(filesystem_uuid=uuid,
                              filesystem_type=filesystem_type,
                              mount_point=mount_point,
                              device_name=device_name)


def _explicit_root(value: Any, what: str = "--store-root") -> str:
    """The root a mutating verb was told to use, or a usage refusal.

    There is no default and no fallback: the whole point is that omitting it
    cannot quietly resolve to production. Checked before anything is opened, so
    a malformed root never reaches a store constructor at all.
    """
    if not isinstance(value, str) or not value.strip():
        raise _Unusable(f"{what} must be given explicitly; there is no default")
    if not value.startswith("/"):
        raise _Unusable(f"{what} must be an absolute path, not {value!r}")
    if value != os.path.normpath(value):
        raise _Unusable(
            f"{what} must be given in normal form, not {value!r}")
    return value


def _anchored(root: str):
    """A verified root descriptor over ``root``, or refuse.

    The provisioned backing-store configuration is the authority; this opens it
    and the root no-follow and hands both to the governed verifier.
    """
    try:
        config = os.open(BACKING_STORE_CONFIG,
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise _Unusable(
            f"the backing-store configuration is unusable ({error.strerror})") from None
    try:
        try:
            handle = os.open(root, _DIR_FLAGS)
        except OSError as error:
            raise _Unusable(f"{root} is unusable ({error.strerror})") from None
        try:
            return verify_backing_store(
                config, handle, observed=_observed_filesystem(root))
        except BackingStoreError as error:
            raise _Unusable(f"the backing store does not verify ({error})") from None
        finally:
            os.close(handle)
    finally:
        os.close(config)


def command_authorise_launch(args) -> int:
    """Carry one prepared invocation to a verifiable handoff, and stop.

    Every judgement belongs to the Generation-8 bridge: eligibility, the
    profile, the commitment, the lifecycle transition, the journalled
    projection, the handoff, and what a repeat means. This opens the ruled
    roots, hands them over, and reports what came back.

    The package tree is taken from the prepared invocation's own durable
    record rather than from an argument. An operator able to name it would be
    an operator able to name a different one, and the invocation already says
    which tree it staged.
    """
    try:
        store = CapabilityStore(CAPABILITY_RUNTIME_ROOT,
                                expected_uid=args.expected_uid,
                                expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(
            f"the capability runtime store is unusable ({error})") from None
    try:
        record = store.read_record("capability-invocation", args.cinv)
    except CapabilityError as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_DENIED
    staged = record.get("staged_path")
    if not isinstance(staged, str) or not staged:
        print(f"capability: {args.cinv} carries no staged package",
              file=sys.stderr)
        return EXIT_DENIED

    try:
        payload = open_trusted_regular_file(
            args.approved_payload_root, args.payload_file,
            expected_uid=args.expected_uid, require_single_link=True,
            maximum_bytes=PAYLOAD_MAXIMUM_BYTES, refuse_oversize=True)
    except TrustedSourceError as error:
        raise _Unusable(f"the payload file could not be read ({error})") from None

    execution_root = handoff_root = None
    artefact = -1
    try:
        try:
            artefact = os.open(staged, _DIR_FLAGS)
        except OSError as error:
            raise _Unusable(
                f"the staged package is unusable ({error.strerror})") from None
        execution_root = _anchored(os.path.join(CAPABILITY_RUNTIME_ROOT,
                                                "execution"))
        handoff_root = _anchored(HANDOFF_ROOT)
        try:
            authority = os.open(AUTHORITY_ROOT, _DIR_FLAGS)
        except OSError as error:
            raise _Unusable(
                f"the authority namespace is unusable ({error.strerror})") from None
        try:
            ready = authorise_launch(
                store=store, execution_root=execution_root,
                handoff_root=handoff_root, authority_fd=authority,
                cinv=args.cinv, cimp=args.cimp, payload_fd=payload,
                package_entrypoint=args.package_entrypoint,
                artefact_fd=artefact)
        finally:
            os.close(authority)
    except ValueError as error:
        # Every governed refusal in the execution plane subclasses ValueError:
        # LaunchError, PackageError, PayloadError, ProfileError,
        # ImplementationAuthorityError, ExecutionStateError, CapabilityError.
        # Rendering the base rather than a list of them means a refusal added
        # later arrives here as a clean denial instead of a traceback, which is
        # the failure direction an operator surface should prefer. The cost is
        # that a genuine ValueError bug would also read as a denial; the
        # message is printed verbatim so it is still identifiable.
        print(f"capability: {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_DENIED
    finally:
        os.close(payload)
        if artefact != -1:
            os.close(artefact)
        for anchor in (execution_root, handoff_root):
            if anchor is not None:
                anchor.close()

    # Identifiers and digests only. What the invocation carries is not this
    # command's to publish.
    _emit({
        "cinv": ready.cinv,
        "cimp": ready.cimp,
        "lifecycle_state": LAUNCH_AUTHORIZED_STATE,
        "profile_digest": ready.profile_digest,
        "commitment_digest": ready.commitment_digest,
        "package_digest": ready.handoff.package_digest,
        "payload_digest": ready.handoff.payload_digest,
        "handoff_published": True,
        "resumed": ready.resumed,
    })
    return EXIT_SUCCESS


def command_execute(args) -> int:
    """Supervise one authorised invocation and record its terminal result.

    **It decides nothing about whether execution is permitted.** That was
    decided twice already: `invoke` verified eligibility and spent the identity,
    and `authorise-launch` published the handoff and wrote the authorisation.
    This step drives what those two authorised, and writes the one record they
    deliberately left unwritten.

    **The caller supplies one CINV.** No adapter, no backend, no binding, no
    image and no argv -- there is no flag for any of them, which is what makes
    "the caller does not choose what runs" a property of the surface rather
    than a rule about it.

    **A refusal writes nothing.** A supervised execution that could not be
    concluded leaves the invocation unresolved on purpose, so the recovery
    enumeration and the execution-safety gate can still find it. An
    `adapter-error` record would close the question without answering it.
    """
    from .execution import supervision

    launcher = _helper_launcher()
    try:
        store = CapabilityStore(CAPABILITY_RUNTIME_ROOT,
                                expected_uid=args.expected_uid,
                                expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(
            f"the capability runtime store is unusable ({error})") from None
    try:
        record = store.read_record("capability-invocation", args.cinv)
    except CapabilityError as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_DENIED

    binding = supervised_binding(args.cinv)
    supervisor = supervision.ExecutionSupervisor(
        launcher=launcher, reconciler=launcher.reconcile)
    try:
        terminal = execute_supervised(
            store, invocation_record_id=record.get("invocation_record_id"),
            invocation_id=args.cinv, supervisor=supervisor, binding=binding,
            actor=args.actor,
            recorded_at=_instant(args.recorded_at, "--recorded-at"))
    except supervision.SupervisionRefused as refusal:
        # Reported in full and recorded not at all. The trace says how far the
        # conversation got and what reconciliation proved, which is what an
        # operator needs to decide whether this host is still safe to execute
        # on -- and the execution-safety gate answers that mechanically.
        trace = supervisor.trace
        _emit({
            "cinv": args.cinv,
            "status": "unresolved",
            "reason": str(refusal),
            "protocol_states": list(trace.states) if trace else [],
            "worker_reaped": trace.worker_reaped if trace else None,
            "disposal_proven": trace.disposal_proven if trace else False,
            "reconciled": trace.reconciled if trace else None,
            "result_recorded": False,
        })
        return EXIT_DENIED
    except CapabilityError as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_DENIED

    # THE CLOSURE, AFTER THE RESULT IS DURABLE, AND NEVER BEFORE.
    #
    # ADR-0017. The supervised path journals nothing past `launch_authorized`,
    # so without this every successful execution holds a slot for ever. The
    # ordering is deliberate: the result is written first and stands whatever
    # happens here. A recorded execution must never be lost because the closure
    # that follows it failed -- an invocation left at `launch_authorized` with a
    # durable result is exactly what `capability conclude` resumes, and it is
    # the state this whole ADR exists to close.
    #
    # `observed`, not `reconstructed`: this process supervised the execution it
    # is closing.
    from .execution import conclusion

    concluded: Any = None
    conclusion_refused: Any = None
    execution_root = _anchored(os.path.join(CAPABILITY_RUNTIME_ROOT, "execution"))
    try:
        concluded = conclusion.conclude(
            store=store, execution_root=execution_root, cinv=args.cinv,
            actor=args.actor,
            request_id=f"supervised-execute:{args.cinv}",
            recorded_at=_instant(args.recorded_at, "--recorded-at"),
            derivation=conclusion.DERIVATION_OBSERVED)
    except Exception as error:                                   # noqa: BLE001
        # Deliberately broad, and only here. The result is already durable, and
        # the contract is that it stands whatever the closure does. A narrow
        # `except ValueError` would let anything else -- an ImportError from a
        # half-published generation, an OSError from the journal -- turn a
        # recorded execution into a traceback, which is precisely the loss this
        # ordering exists to prevent. The reason is reported, and the
        # invocation is left where `capability conclude` resumes it.
        conclusion_refused = f"{type(error).__name__}: {error}"
    finally:
        execution_root.close()

    _emit({
        "cinv": args.cinv,
        "status": terminal.status,
        "reason": terminal.reason,
        "invocation_record_id": terminal.invocation_record_id,
        "result_record_id": terminal.result_record_id,
        "succeeded": terminal.succeeded,
        "result_digest": terminal.result_digest,
        "result_artifact_reference": terminal.result_artifact_reference,
        "disposal_proven": True,
        "lifecycle_state": (concluded.state if concluded is not None
                            else "launch_authorized"),
        "slot_released": bool(concluded is not None and concluded.slot_released),
        "conclusion_cadm": concluded.cadm if concluded is not None else None,
        "conclusion_refused": conclusion_refused,
    })
    return EXIT_SUCCESS if terminal.succeeded else EXIT_DENIED


def _helper_launcher():
    """The one seam that starts a privileged process, resolved from the tree.

    Loaded the way the worker resolves its backend, and for the same reason:
    everything under `tools/capability/` is asserted to reach no subprocess, so
    the module that does lives outside it and is named here rather than
    imported at the top of a package that must stay clean.
    """
    root = "/usr/lib/kyri/python"          # prod-path-reference
    expected = os.path.join(root, "kyri_exec_launcher.py")
    if not os.path.isfile(expected):
        raise _Unusable(
            f"the governed helper launcher is not installed at {expected}")
    if root not in sys.path:
        sys.path.insert(0, root)
    try:
        # A literal import, not a name resolved at runtime. The generation's
        # closure is computed from the import graph, so a module reached only
        # through `importlib` would have to be whitelisted into the installed
        # surface by hand -- and a surface somebody listed is not one the graph
        # requires.
        import kyri_exec_launcher as module
    except ImportError as error:
        raise _Unusable(
            f"the governed helper launcher is not importable ({error})") from None
    resolved = getattr(module, "__file__", None)
    if not resolved or not os.path.realpath(resolved).startswith(
            os.path.realpath(root) + os.sep):
        raise _Unusable(
            f"the helper launcher resolved outside {root} ({resolved})")
    return module.HelperLauncher()


def command_abandon(args) -> int:
    """Permanently close one stuck invocation administratively, and stop.

    **It is not a force-transition and it is not a repair.** It closes exactly
    one invocation, only from the two states the coordinator wrote before
    handing anything over, only under a controlled reason that must agree with
    what the store already holds, and it deletes nothing. The `CINV`, any
    `CRES`, the launch authorisation and the published handoff are all left
    exactly as they are.

    **Every judgement belongs to `abandonment.abandon`.** This opens the ruled
    roots, hands them over, and reports what came back.
    """
    from .execution import abandonment

    root = _explicit_root(args.store_root)
    try:
        store = CapabilityStore(root,
                                expected_uid=args.expected_uid,
                                expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(
            f"the capability runtime store is unusable ({error})") from None

    execution_root = _anchored(os.path.join(root, "execution"))
    try:
        outcome = abandonment.abandon(
            store=store, execution_root=execution_root, cinv=args.cinv,
            actor=args.actor, request_id=args.request_id,
            recorded_at=args.recorded_at, reason=args.reason)
    except ValueError as error:
        # Every governed refusal in the execution plane subclasses ValueError,
        # so a refusal added later arrives here as a clean denial instead of a
        # traceback.
        print(f"capability: {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_DENIED
    finally:
        execution_root.close()

    _emit({
        "cinv": outcome.cinv,
        "cadm": outcome.cadm,
        "previous_state": outcome.previous_state,
        "lifecycle_state": outcome.state,
        "reason": outcome.reason,
        "result_record_id": outcome.result_record_id,
        "slot_released": outcome.slot_released,
        "resumed": outcome.resumed,
        # The root as typed, and the object the writer actually held. A test
        # asserts the second one: text naming a store is not evidence about
        # which store was written.
        "store_root": root,
        "target": outcome.target,
    })
    return EXIT_SUCCESS


def command_conclude(args) -> int:
    """Close one executed invocation and return its slot, and stop.

    **It is not a force-transition and it is not a repair.** It closes exactly
    one invocation, only from `launch_authorized`, only when the store already
    holds a terminal result for it, and there is no way to name a target state.
    It deletes nothing and reaches no container: the container it concerns was
    proven gone before the result it rests on could be written at all.

    **It does not claim the cleanup progression ran.** `concluded` says the
    execution ran and concluded and that cleanup did not; the per-`CINV` handoff
    subtree is still on disk, and the evidence records that.

    **Every judgement belongs to `conclusion.conclude`.** This opens the ruled
    root, hands it over, and reports what came back.
    """
    from .execution import conclusion

    root = _explicit_root(args.store_root)
    try:
        store = CapabilityStore(root,
                                expected_uid=args.expected_uid,
                                expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(
            f"the capability runtime store is unusable ({error})") from None

    execution_root = _anchored(os.path.join(root, "execution"))
    try:
        outcome = conclusion.conclude(
            store=store, execution_root=execution_root, cinv=args.cinv,
            actor=args.actor, request_id=args.request_id,
            recorded_at=args.recorded_at,
            derivation=conclusion.DERIVATION_RECONSTRUCTED)
    except ValueError as error:
        # Every governed refusal in the execution plane subclasses ValueError,
        # so a refusal added later arrives here as a clean denial instead of a
        # traceback.
        print(f"capability: {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_DENIED
    finally:
        execution_root.close()

    _emit({
        "cinv": outcome.cinv,
        "cadm": outcome.cadm,
        "previous_state": outcome.previous_state,
        "lifecycle_state": outcome.state,
        "result_record_id": outcome.result_record_id,
        "derivation": outcome.derivation,
        "handoff_retained": outcome.handoff_retained,
        "slot_released": outcome.slot_released,
        "resumed": outcome.resumed,
        # The root as typed. A test asserts the object the writer actually
        # held: text naming a store is not evidence about which store moved.
        "store_root": root,
    })
    return EXIT_SUCCESS


def command_correct_provenance(args) -> int:
    """Record that one claim in an earlier `CADM` is not truthful provenance.

    **It corrects a record, not a lifecycle.** Nothing here transitions an
    invocation, releases or takes a slot, writes a result, or edits the record
    it is about. The subject `CADM` is read and digested and left exactly as it
    is, and the finding is written as a separate append-only record beside it.

    **It is not ratification.** Accepting that an action's effect stands is a
    different statement from accepting who is recorded as having taken it, and
    this verb makes only the second one, in the negative.

    **Every judgement belongs to `provenance.correct_provenance`.** This opens
    the ruled root, hands it over, and reports what came back.
    """
    from .execution import provenance

    root = _explicit_root(args.store_root)
    execution_root = _anchored(os.path.join(root, "execution"))
    try:
        outcome = provenance.correct_provenance(
            execution_root=execution_root, subject_cadm=args.subject_cadm,
            cinv=args.cinv, disputed_field=args.disputed_field,
            disputed_value=args.disputed_value, finding=args.finding,
            actual_initiator=args.actual_initiator, actor=args.actor,
            request_id=args.request_id, recorded_at=args.recorded_at,
            evidence_references=args.evidence_reference or None)
    except ValueError as error:
        print(f"capability: {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_DENIED
    finally:
        execution_root.close()

    _emit({
        "cadm": outcome.cadm,
        "subject_cadm": outcome.subject_cadm,
        "subject_member": outcome.subject_member,
        "subject_digest": outcome.subject_digest,
        "cinv": outcome.cinv,
        "disputed_field": outcome.disputed_field,
        "disputed_value": outcome.disputed_value,
        "finding": outcome.finding,
        "actual_initiator": outcome.actual_initiator,
        "effect": outcome.effect,
        "lifecycle_state": outcome.lifecycle_state,
        "resumed": outcome.resumed,
        "store_root": root,
        "target": outcome.target,
    })
    return EXIT_SUCCESS


def command_recover(args) -> int:
    """Resolve every interrupted invocation's container, and report the verdict.

    **The records decide what to look at.** An invocation carrying an adapter
    identity with no terminal result is one where execution was authorised and
    its outcome was never established -- which is exactly what a killed worker
    or a killed coordinator leaves behind. Podman is never enumerated: the
    coordinator has no authority to ask what containers exist and must not gain
    any.

    **It writes nothing.** No result is synthesised for an interrupted
    invocation and the invocation record is never touched. What this resolves is
    the container, which is a different question with a different answer, and
    leaving the invocation interrupted is the honest reading of an execution
    whose supervision was lost.

    **Running it twice is harmless.** Reconciliation treats absence as success,
    so a second pass proves the same thing and changes nothing.
    """
    from .execution import recovery

    launcher = _helper_launcher()
    try:
        store = CapabilityStore(CAPABILITY_RUNTIME_ROOT,
                                expected_uid=args.expected_uid,
                                expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(
            f"the capability runtime store is unusable ({error})") from None

    # The lifecycle journal, so a supervised invocation is discoverable at all.
    # `CINV` never carries an adapter identity on that path, so without this the
    # enumeration would skip exactly the invocations this command exists for.
    execution_root = _anchored(os.path.join(CAPABILITY_RUNTIME_ROOT, "execution"))
    try:
        safety = recovery.execution_safety(store, reconciler=launcher.reconcile,
                                           execution_root=execution_root)
    finally:
        execution_root.close()
    _emit({
        "execution_safety": safety.state,
        "invocations_checked": safety.checked,
        "unresolved": [
            {"invocation_id": finding.invocation_id,
             "invocation_record_id": finding.invocation_record_id,
             "disposition": finding.disposition,
             "interrupted": finding.interrupted,
             "reason": finding.reason}
            for finding in safety.unresolved],
        "results_written": 0,
    })
    return EXIT_SUCCESS if safety.ready else EXIT_DENIED


def command_inspect(args) -> int:
    """Records as stored, in a canonical order."""
    store = _runtime_store(args)
    try:
        report = inspect_records(store, kind=args.kind, identifier=args.identifier)
    except CapabilityError as error:
        raise _Unusable(str(error)) from None
    _emit({"status": report.status, "records": list(report.records),
           "findings": list(report.findings)})
    return EXIT_SUCCESS if report.status == STATUS_REPORTED else EXIT_DENIED


def command_validate(args) -> int:
    """Findings, and nothing repaired."""
    store = _runtime_store(args)
    report = validate_store(store)
    _emit({"status": report.status, "findings": list(report.findings)})
    sound = report.status == STATUS_REPORTED and not report.findings
    return EXIT_SUCCESS if sound else EXIT_DENIED


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="capability",
        description="Prepare and inspect governed capability invocations. "
                    "Nothing here executes a capability.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def with_store(sub):
        sub.add_argument("--store-root", required=True)
        sub.add_argument("--expected-uid", required=True, type=int)
        sub.add_argument("--expected-gid", required=True, type=int)
        return sub

    invoke = with_store(subparsers.add_parser("invoke"))
    invoke.add_argument("--fabric-root", required=True)
    invoke.add_argument("--fabric-expected-uid", required=True, type=int)
    invoke.add_argument("--fabric-expected-gid", required=True, type=int)
    invoke.add_argument("--approved-artifact-root", required=True)
    invoke.add_argument("--trusted-source-uid", required=True, type=int)
    invoke.add_argument("--staging-root", required=True)
    invoke.add_argument("--coordinator-uid", required=True, type=int)
    invoke.add_argument("--approved-payload-root", required=True)
    invoke.add_argument("--payload-source-uid", required=True, type=int)
    invoke.add_argument("--payload-file", required=True,
                        help="file name inside the approved payload directory")
    invoke.add_argument("--invocation-id", required=True)
    invoke.add_argument("--selection-id", required=True)
    invoke.add_argument("--instance-id", required=True)
    invoke.add_argument("--package-id", required=True)
    # Required, and never defaulted. A selection names a binding; it does not
    # name an action, so the action is named here or the invocation is refused.
    invoke.add_argument("--operation", required=True)
    # Current eligibility is a question for C5, and C5 asks C3. The store is
    # named explicitly for the same reason every other root is.
    invoke.add_argument("--trust-store-root", required=True)
    invoke.add_argument("--actor", required=True)
    invoke.add_argument("--request-id", required=True)
    invoke.add_argument("--requested-at", required=True)
    # The rehearsal. Same arguments, same governed path, nothing written -- so
    # an operator learns whether an invocation would be accepted without
    # spending the identity that finding out used to cost.
    invoke.add_argument("--preflight", action="store_true",
                        help="rehearse this invocation and mutate nothing")
    invoke.set_defaults(handler=command_invoke)

    look = with_store(subparsers.add_parser("inspect"))
    look.add_argument("--kind", default=None)
    look.add_argument("--identifier", default=None)
    look.set_defaults(handler=command_inspect)

    sound = with_store(subparsers.add_parser("validate"))
    sound.set_defaults(handler=command_validate)

    # The S5 operator surface. No root is an argument: every one is compiled in
    # above, and the staged package comes from the invocation's own record.
    launch = subparsers.add_parser("authorise-launch")
    launch.add_argument("--expected-uid", required=True, type=int)
    launch.add_argument("--expected-gid", required=True, type=int)
    launch.add_argument("--cinv", required=True)
    launch.add_argument("--cimp", required=True)
    launch.add_argument("--approved-payload-root", required=True)
    launch.add_argument("--payload-file", required=True,
                        help="file name inside the approved payload directory")
    launch.add_argument("--package-entrypoint", required=True)
    launch.set_defaults(handler=command_authorise_launch)

    # The third step, and the last one before a result exists. It takes one
    # CINV: everything else -- the implementation, the profile, the identity,
    # the image, the argv -- was decided by the two steps before it and is read
    # from what they made durable. There is deliberately no --adapter,
    # --backend or --execution-binding: a caller able to name any of those
    # would be a caller choosing what runs.
    execute = subparsers.add_parser("execute")
    execute.add_argument("--expected-uid", required=True, type=int)
    execute.add_argument("--expected-gid", required=True, type=int)
    execute.add_argument("--cinv", required=True)
    execute.add_argument("--actor", required=True)
    execute.add_argument("--recorded-at", required=True)
    execute.set_defaults(handler=command_execute)

    # Administrative abandonment (ADR-0015). Narrow on purpose: one CINV, one
    # controlled reason, and no way to name a target state. It exists because
    # an invocation stuck before the privilege boundary otherwise holds an
    # execution slot for ever, and raising the ceiling would have removed the
    # control rather than the defect.
    abandon = subparsers.add_parser("abandon")
    abandon.add_argument("--store-root", required=True,
                         help="the capability runtime root to mutate, absolute "
                              "and explicit; production is "
                              "/data/kyri/capability-runtime and there is NO "
                              "default -- a rehearsal must name its own fixture")
    abandon.add_argument("--expected-uid", required=True, type=int)
    abandon.add_argument("--expected-gid", required=True, type=int)
    abandon.add_argument("--cinv", required=True)
    abandon.add_argument("--actor", required=True)
    abandon.add_argument("--request-id", required=True)
    abandon.add_argument("--recorded-at", required=True)
    abandon.add_argument("--reason", required=True,
                         choices=sorted(_ABANDONMENT_REASONS),
                         help="the controlled abandonment reason category")
    abandon.set_defaults(handler=command_abandon)

    # Post-execution conclusion (ADR-0017). Narrower than abandonment: no
    # reason category, because there is only one situation it closes -- an
    # execution that ran, concluded, and whose terminal result is durable. It
    # exists because the supervised path never journals past
    # `launch_authorized`, so every successful execution otherwise holds a slot
    # for ever, and `released` is unreachable: §13 gives the output leaf to the
    # execution identity and nothing released can remove it, so `cleaned`
    # cannot be truthfully recorded.
    conclude = subparsers.add_parser("conclude")
    conclude.add_argument("--store-root", required=True,
                          help="the capability runtime root to mutate, absolute "
                               "and explicit; production is "
                               "/data/kyri/capability-runtime and there is NO "
                               "default -- a rehearsal must name its own fixture")
    conclude.add_argument("--expected-uid", required=True, type=int)
    conclude.add_argument("--expected-gid", required=True, type=int)
    conclude.add_argument("--cinv", required=True)
    conclude.add_argument("--actor", required=True)
    conclude.add_argument("--request-id", required=True)
    conclude.add_argument("--recorded-at", required=True)
    conclude.set_defaults(handler=command_conclude)

    # Provenance correction (ADR-0016). Narrower than abandonment: it takes a
    # subject record and one disputed claim, writes a finding beside it, and
    # has no way to name a lifecycle state, a slot, or a result. The disputed
    # value must match what the store already holds, so an operator cannot
    # correct a claim that is not there.
    correct = subparsers.add_parser("correct-provenance")
    correct.add_argument("--store-root", required=True,
                         help="the capability runtime root to mutate, absolute "
                              "and explicit; production is "
                              "/data/kyri/capability-runtime and there is NO "
                              "default -- a rehearsal must name its own fixture")
    correct.add_argument("--subject-cadm", required=True,
                         help="the administrative record whose claim is disputed")
    correct.add_argument("--cinv", required=True)
    correct.add_argument("--disputed-field", required=True,
                         choices=sorted(_CORRECTABLE_FIELDS),
                         help="the provenance claim being disputed; no "
                              "lifecycle claim is correctable here")
    correct.add_argument("--disputed-value", required=True,
                         help="what that claim currently says, which must "
                              "match the record")
    correct.add_argument("--finding", required=True,
                         choices=sorted(_CORRECTION_FINDINGS))
    correct.add_argument("--actual-initiator", required=True,
                         choices=sorted(_CORRECTION_INITIATORS))
    correct.add_argument("--actor", required=True,
                         help="who is recording this correction")
    correct.add_argument("--request-id", required=True)
    correct.add_argument("--recorded-at", required=True)
    correct.add_argument("--evidence-reference", action="append", default=[],
                         help="repeatable; where the incident evidence lives")
    correct.set_defaults(handler=command_correct_provenance)

    # Recovery, and the execution-safety verdict it decides. It takes no
    # invocation: the ones to resolve are the ones the runtime records say were
    # never resolved, and an operator able to name one would be an operator
    # able to name one that was fine.
    recover = subparsers.add_parser("recover")
    recover.add_argument("--expected-uid", required=True, type=int)
    recover.add_argument("--expected-gid", required=True, type=int)
    recover.set_defaults(handler=command_recover)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        # argparse exits 2 for a usage problem and 0 for --help; both are
        # interface outcomes rather than governed ones.
        return EXIT_USAGE if error.code not in (0, None) else EXIT_SUCCESS
    try:
        return args.handler(args)
    except _Unusable as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_USAGE
    except CapabilityError as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
