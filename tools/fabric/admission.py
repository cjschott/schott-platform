"""The first governed acceptances: declaration, subject admission, advertisement.

Five operation classes, one shape. Each validates what the caller supplied,
derives its request digest, enters `request_critical_section` **once**, resolves
replay inside it, and holds it through allocation and the accepted write. The
replay helper never enters it, so nesting is impossible by construction.

**A refusal writes nothing.** Not a queued record, not a pending one, not a
partial one. An advertisement from an unadmitted subject is *"not a pending
record -- it is not a record at all"*, and the same is true of every other
refusal here: prerequisites are resolved before an identity is allocated, so
there is nothing to undo.

**Authority differs by operation, and the difference is the point.** Declaring
and admitting are human decisions and record an approving operator. Publishing
an advertisement is not: the admitted subject acts as itself, and an approving
operator is *refused* rather than ignored, because recording one would turn a
self-report into an approval.

**Trust is reached only through C3.** No trust record is read here, no trust
verdict is formed here, and nothing here writes trust state in either
direction. A refusal keeps C3's own reason rather than restating it.

**Comparison is containment, never interpretation.** The accepted package
schema says resources are *"declared in the same controlled vocabulary a host
uses to describe itself, so that matching is containment rather than
interpretation"*. So an advertised claim must be contained by what the operator
verified; nothing here orders a memory size or ranks an accelerator class.

This increment declares, admits, and records claims. It admits no instance,
creates no route, computes no eligibility, and chooses nothing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from ..trust.identifiers import RECORD_ID as TRUST_RECORD_ID
from .errors import FabricError
from .evidence import assemble_evidence, validate_record_evidence
from .identifiers import ID_FIELDS as ID_FIELD_FOR, PATTERNS, PREFIXES
from .models import (
    EFFECT_CLASSES, INSTANCE_LIFECYCLE_STATES, RECORD_MODELS,
    WORKLOAD_DATA_CLASSIFICATIONS,
)
from .request_identity import (
    REPLAY_CONFLICT, REPLAY_EXACT, compute_request_digest,
    prepare_and_compute_request_digest, replay_lookup, validate_request_id,
)
from .store import ID_WIDTHS
from .trust_adapter import UNVERIFIED, verify_trust_record

# Outcomes. `accepted` and `exact-replay` are the only two that leave a record.
ACCEPTED = "accepted"
EXACT_REPLAY = "exact-replay"
REFUSED = "refused"
INVALID = "invalid"
NOT_FOUND = "not-found"
CONFLICT = "conflict"
UNAVAILABLE = "unavailable"

# Controlled refusal categories. A caller acts on these; none is derived from
# an exception, a path, or a rejected value.
REASON_CONFLICT = "request_identity_conflict"
REASON_ACTOR = "missing-actor"
REASON_AUTHORITY = "missing-approving-authority"
REASON_UNEXPECTED_AUTHORITY = "unexpected-approving-authority"
REASON_NOT_SUBJECT = "actor-is-not-the-subject"
REASON_SELF_ADMISSION = "self-admission"
REASON_EFFECT_CLASS = "unknown-effect-class"
REASON_TRUST_DOMAIN = "unknown-trust-domain"
REASON_UNRESOLVED = "unresolved-reference"
REASON_CONTRACT_OWNER = "contract-not-of-capability"
REASON_PACKAGE_CONTRACT = "contract-not-of-package"
REASON_VERSIONS = "versions-not-declared"
REASON_RESOURCE_CLAIM = "resource-claim-not-verified"
REASON_WINDOW = "invalid-validity-window"
REASON_NAIVE_INSTANT = "timestamp-carries-no-offset"
REASON_SUBJECT_MISMATCH = "trust-subject-mismatch"
REASON_UNVERIFIED_PROFILE = "resource-profile-not-verified-out-of-band"
REASON_CONTENT = "malformed-operation-content"

# Categories the part-2 operations add. Each names a condition that did not
# exist before instances and routes did; none replaces or widens one above.
REASON_PACKAGE_OWNER = "package-not-of-capability"
REASON_ADVERT_SUBJECT = "advertisement-not-of-subject"
REASON_ADVERT_CONTRACT = "advertisement-not-of-contract"
REASON_ADVERT_PACKAGE = "advertisement-not-of-package"
REASON_ADVERT_STALE = "advertisement-not-fresh"
REASON_ADMISSION_EXPIRED = "admission-window-expired"
REASON_EMPTY_SCOPE = "empty-effective-scope"
# "Exceeds" would assert a ranking of classifications that no accepted source
# declares. Membership is the whole of the comparison.
REASON_CLASSIFICATION = "data-classification-not-permitted-by-host"
REASON_UNKNOWN_CLASSIFICATION = "unknown-data-classification"
REASON_NO_SCOPE = "trust-grant-carries-no-scope"
REASON_MALFORMED_SCOPE = "malformed-admission-scope"
# Distinct from `self-admission`, which means a subject admitting itself into
# the fabric. This one means a subject governing a decision about itself.
REASON_ACTOR_IS_SUBJECT = "actor-is-the-subject"
REASON_HOST_NOT_IN_SERVICE = "host-not-in-service"
REASON_HOST_SUPERSEDED = "host-record-superseded"
REASON_PREDECESSOR_NOT_CURRENT = "host-predecessor-not-current"
REASON_CHAIN_FORKED = "host-chain-forked"
REASON_CHAIN_CYCLIC = "host-chain-cyclic"
REASON_CHAIN_INCOHERENT = "host-chain-incoherent"
REASON_INTENT_UNCHANGED = "availability-intent-unchanged"
REASON_RETURN_NEEDS_REFRESH = "return-to-service-requires-refresh"
REASON_REFRESH_NOTHING = "refresh-changes-nothing"
REASON_UNKNOWN_INTENT = "unknown-availability-intent"
REASON_UNKNOWN_LOCALITY = "unknown-locality"
REASON_SUPERSEDES_CAPABILITY = "supersedes-different-capability"
REASON_SUPERSEDES_CONTRACT = "supersedes-different-contract"
REASON_SUPERSEDES_PACKAGE = "supersedes-different-package"
REASON_SUPERSEDES_SUPERSEDED = "supersedes-already-superseded"
REASON_SUPERSEDES_NOT_ADMITTED = "supersedes-not-admitted"
REASON_INSTANCE_NOT_HEAD = "instance-not-current-head"
REASON_LIFECYCLE_ILLEGAL = "instance-lifecycle-transition-illegal"
REASON_INSTANCE_FORKED = "instance-chain-forked"
REASON_INSTANCE_CYCLIC = "instance-chain-cyclic"
REASON_NOT_BINDING_ROOT = "candidate-not-a-binding-root"
REASON_OVERLAP_MALFORMED = "malformed-overlap-window"
REASON_OVERLAP_NO_SUPERSESSION = "overlap-window-without-supersession"
REASON_OVERLAP_NO_CUTOVER = "overlap-window-without-cutover"
REASON_OVERLAP_NO_COEXISTENCE = "overlap-window-without-coexistence"
REASON_NO_CANDIDATE = "no-declared-candidate"
REASON_DUPLICATE_CANDIDATE = "duplicate-candidate"
REASON_CANDIDATE_OWNER = "candidate-not-of-route"
REASON_ROUTE_VERSION = "invalid-route-version"
REASON_SUPERSEDES_SUBJECT = "supersedes-different-subject"

# The trust domain every capability package is decided in, per the accepted
# package schema. It is a constant of the contract, not a caller's choice.
PACKAGE_TRUST_DOMAIN = "capability-package"

# The domain a fabric host is a trust subject in, per the accepted host schema.
HOST_TRUST_DOMAIN = "fabric-node"

# The released Trust Plane scope vocabulary, read rather than restated. The
# Fabric composes these dimensions; it defines none of them.
SCOPE_CLASSIFICATIONS = "permitted_data_classifications"
SCOPE_DIMENSIONS = ("permitted_capabilities", "permitted_operations",
                    SCOPE_CLASSIFICATIONS, "permitted_targets")

# Operator-set vocabularies, from the accepted host and route schemas.
AVAILABILITY_INTENTS = ("in-service", "draining", "withheld")
LOCATION_CLASSES = ("on-premises", "operator-controlled-remote",
                    "third-party-hosted")
LOCALITIES = ("local-only", "operator-controlled-only", "any-trusted")

# What makes one host declaration authoritatively different from another.
# Everything else -- provenance, notes, evidence, the allocated identity, the
# request that carried it -- describes the decision rather than the machine,
# and a successor differing only in those declares nothing new.
AUTHORITATIVE_HOST_FIELDS = (
    "fabric_node_trust_record_id", "verified_resource_profile",
    "verification_reference", "location_class", "data_classification",
    "availability_intent",
)

# Categories that continue a binding rather than starting one. A record that
# arrived under either is a lifecycle version of what it supersedes; anything
# else is a new binding that happens to name a predecessor.
LIFECYCLE_CATEGORIES = ("withdrawal", "retirement")

# Which digest route an operation takes. Increments 1 to 6 keep the accepted
# helper exactly; the operations added here take the narrower prepare-once
# route, which accepts less and is not a drop-in replacement for it.
LEGACY_DIGEST = "legacy-canonical"
PREPARED_DIGEST = "prepared-canonical"

# A C3 refusal that means the Trust Plane could not answer at all, rather than
# that it answered no.
TRUST_UNAVAILABLE = "trust-unavailable"

# A schema-valid identity of the right kind and width that C1 never allocates,
# because every sequence starts at 1. It exists only to prove that the exact
# evidence and record content are constructible *before* an identity is
# allocated. It is never returned, never written, and never persisted.
PROBE_IDS = {kind: f"{prefix}-{0:0{ID_WIDTHS[kind]}d}"
             for kind, prefix in PREFIXES.items()}


@dataclass(frozen=True)
class OperationResult:
    """What one governed operation did. Immutable, and never persisted."""

    outcome: str
    request_id: str
    request_digest: str | None = None
    record_kind: str | None = None
    record_id: str | None = None
    reason: str | None = None

    @property
    def accepted(self) -> bool:
        return self.outcome == ACCEPTED

    def to_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome,
            "request_id": self.request_id,
            "request_digest": self.request_digest,
            "record_kind": self.record_kind,
            "record_id": self.record_id,
            "reason": self.reason,
        }


class _Refusal(Exception):
    """Internal: a governed refusal, carrying its outcome and category."""

    def __init__(self, outcome: str, reason: str) -> None:
        super().__init__(reason)
        self.outcome = outcome
        self.reason = reason


def _refuse(outcome: str, reason: str) -> None:
    raise _Refusal(outcome, reason)


def _text(value: Any, reason: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _refuse(INVALID, reason)
    return value


def _aware(value: Any, reason: str = REASON_NAIVE_INSTANT) -> datetime:
    if not isinstance(value, datetime):
        _refuse(INVALID, reason)
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        _refuse(INVALID, reason)
    return value


def _mapping(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        _refuse(INVALID, REASON_CONTENT)
    return value


def _sequence(value: Any) -> tuple:
    if isinstance(value, str) or not isinstance(value, (list, tuple)):
        _refuse(INVALID, REASON_CONTENT)
    return tuple(value)


def _human_authority(actor: Any, approving_authority: Any) -> tuple[str, str]:
    """A human-authorised operation names who acted and who approved."""
    _text(actor, REASON_ACTOR)
    _text(approving_authority, REASON_AUTHORITY)
    return actor, approving_authority


def _effect_class(value: Any) -> str:
    # Exactly one released class. Not trimmed, not recased: an effect class
    # that had to be corrected to be recognised was not declared.
    if value not in EFFECT_CLASSES:
        _refuse(REFUSED, REASON_EFFECT_CLASS)
    return value


def _resolve(store, kind: str, identifier: Any) -> Mapping[str, Any]:
    """The referenced record, or a deterministic not-found refusal."""
    if not isinstance(identifier, str) or not identifier.strip():
        _refuse(NOT_FOUND, REASON_UNRESOLVED)
    try:
        return store.read_record(kind, identifier)
    except FabricError:
        _refuse(NOT_FOUND, REASON_UNRESOLVED)
    except Exception:  # noqa: BLE001
        # A reference that cannot be read is a reference that did not resolve.
        _refuse(NOT_FOUND, REASON_UNRESOLVED)


def _stored_instant(value: Any) -> datetime | None:
    """An instant read back off a stored record, or nothing at all.

    A stored timestamp arrives either already parsed or as its offset-carrying
    text. One without an offset is not a point in time, so it is reported as
    absent rather than placed in a zone nobody wrote down.
    """
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value)
        except ValueError:
            return None
    else:
        return None
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        return None
    return parsed


def _verified_standing(trust_store, record_id: Any, evaluated_at: datetime,
                       domain: str):
    """One C3 answer about one subject, or C3's own refusal reported unchanged.

    The Fabric asks; it never reads a trust record and never forms a verdict.
    A refusal keeps the reason C3 gave it, so a caller can explain what
    happened without the Fabric restating a judgement it does not own.
    """
    verification = verify_trust_record(trust_store, record_id,
                                       evaluated_at=evaluated_at,
                                       expected_subject_type=domain)
    if verification.status == UNVERIFIED:
        reason = verification.reasons[0] if verification.reasons else REASON_UNRESOLVED
        _refuse(UNAVAILABLE if reason == TRUST_UNAVAILABLE else REFUSED, reason)
    return verification


def _no_self_governance(actor: Any, approving_authority: Any,
                        *identities: Any) -> None:
    """A machine does not admit itself into the fabric, under any identity."""
    for identity in identities:
        if identity is not None and identity in (actor, approving_authority):
            _refuse(REFUSED, REASON_SELF_ADMISSION)


def _no_self_governance_of(actor: Any, approving_authority: Any,
                           *identities: Any) -> None:
    """A machine does not decide the fate of its own records.

    Named apart from self-admission on purpose: one is a subject letting itself
    in, the other is a subject settling a question about itself. Reporting
    either as the other loses the distinction an operator reads back.
    """
    for identity in identities:
        if identity is not None and identity in (actor, approving_authority):
            _refuse(REFUSED, REASON_ACTOR_IS_SUBJECT)


def _identifier(value: Any, kind: str, reason: str = REASON_CONTENT) -> str:
    """A released identifier for `kind`, judged on its syntax alone.

    Syntax is structure, so it is settled before the request is identified.
    Whether the record exists is a different question, asked later.
    """
    if not isinstance(value, str) or not PATTERNS[kind].fullmatch(value):
        _refuse(INVALID, reason)
    return value


def _optional_identifier(value: Any, kind: str) -> str | None:
    """Absent, or a released identifier. Never something in between."""
    return None if value is None else _identifier(value, kind)


def _trust_identifier(value: Any) -> str:
    """A released trust record identity, matched against the released pattern."""
    if not isinstance(value, str) or not TRUST_RECORD_ID.fullmatch(value):
        _refuse(INVALID, REASON_CONTENT)
    return value


def _member_of(value: Any, vocabulary: tuple[str, ...], reason: str) -> str:
    """A value from a declared vocabulary. Not trimmed, not recased."""
    if value not in vocabulary:
        _refuse(INVALID, reason)
    return value


def _exact_strings(value: Any, repeated: str = REASON_CONTENT) -> tuple[str, ...]:
    """An ordered sequence of exact text, with nothing repeated.

    Exact `str`: a subclass may carry a `__str__` disagreeing with the value
    it encodes, and an unordered dimension ordered by one and hashed by the
    other would be identified as something nobody submitted.
    """
    members = _sequence(value)
    seen: list = []
    for member in members:
        if type(member) is not str or not member.strip():
            _refuse(INVALID, REASON_CONTENT)
        if member in seen:
            _refuse(REFUSED, repeated)
        seen.append(member)
    return tuple(seen)


def _admission_scope(value: Any) -> dict[str, tuple[str, ...]]:
    """The operator's own bound, in exactly the released scope vocabulary.

    Every dimension, every one non-empty. The released scope rules deny a
    request that cannot name all four, so a bound leaving one open bounds
    nothing that could ever be authorised.
    """
    if not isinstance(value, Mapping):
        _refuse(INVALID, REASON_MALFORMED_SCOPE)
    if set(value) != set(SCOPE_DIMENSIONS):
        _refuse(INVALID, REASON_MALFORMED_SCOPE)
    bounded: dict[str, tuple[str, ...]] = {}
    for dimension in SCOPE_DIMENSIONS:
        members = value[dimension]
        if isinstance(members, str) or not isinstance(members, (list, tuple)):
            _refuse(INVALID, REASON_MALFORMED_SCOPE)
        seen: list = []
        for member in members:
            if type(member) is not str or not member.strip():
                _refuse(INVALID, REASON_MALFORMED_SCOPE)
            # A scope matching everything is not a scope. The released model
            # refuses these at the Trust Plane; an admission bound is held to
            # the same rule rather than a laxer one.
            if "*" in member or "?" in member or member in seen:
                _refuse(INVALID, REASON_MALFORMED_SCOPE)
            seen.append(member)
        if not seen:
            _refuse(INVALID, REASON_MALFORMED_SCOPE)
        bounded[dimension] = tuple(seen)
    for classification in bounded[SCOPE_CLASSIFICATIONS]:
        if classification not in WORKLOAD_DATA_CLASSIFICATIONS:
            _refuse(INVALID, REASON_UNKNOWN_CLASSIFICATION)
    return bounded


def _effective_scope(package_scope: Any, host_scope: Any,
                     admission_scope: Mapping[str, tuple[str, ...]]) -> dict[str, Any]:
    """The intersection of three grants, in every dimension.

    Trust is composed by intersection and never inherited. An absent grant
    bounds nothing and therefore permits nothing: absence is not permission,
    and widening it here would grant what nobody approved.
    """
    if package_scope is None or host_scope is None:
        _refuse(REFUSED, REASON_NO_SCOPE)
    effective: dict[str, Any] = {}
    for dimension in SCOPE_DIMENSIONS:
        shared = (set(package_scope.get(dimension) or ())
                  & set(host_scope.get(dimension) or ())
                  & set(admission_scope[dimension]))
        # An empty intersection is a valid outcome, and it means nothing is
        # eligible -- so nothing is admitted either.
        if not shared:
            _refuse(REFUSED, REASON_EMPTY_SCOPE)
        effective[dimension] = tuple(sorted(shared))
    return effective


def _within_window(scope: Mapping[str, Any], evaluated_at: datetime) -> None:
    """The grant must be live at the instant the operator evaluated it."""
    start = scope.get("validity_start")
    end = scope.get("validity_end")
    if isinstance(start, datetime) and evaluated_at < start:
        _refuse(REFUSED, REASON_NO_SCOPE)
    if isinstance(end, datetime) and evaluated_at >= end:
        _refuse(REFUSED, REASON_NO_SCOPE)


def _successors(store, kind: str, field: str, forked: str) -> dict[str, str]:
    """Who supersedes whom, for one record class.

    Immutability means nothing points forward, so the chain is read from what
    points back. Two records claiming one predecessor is a fork, reported
    rather than resolved: repairing it would pick a winner nobody chose.
    """
    links: dict[str, str] = {}
    for record in store.list_records(kind):
        prior = record.get("supersedes")
        if not isinstance(prior, str):
            continue
        if prior in links:
            _refuse(REFUSED, forked)
        links[prior] = record.get(ID_FIELD_FOR[kind])
    return links


def _head_of(links: Mapping[str, str], identifier: str, cyclic: str) -> str:
    """The end of a supersession chain, or a controlled refusal."""
    walked = [identifier]
    while identifier in links:
        identifier = links[identifier]
        if identifier in walked:
            _refuse(REFUSED, cyclic)
        walked.append(identifier)
    return identifier


def _binding_root(records: Mapping[str, Any], identifier: str) -> str:
    """The record that began this binding.

    A lifecycle decision continues a binding; a declared supersession starts a
    new one. Which happened is read from the evidence category the record
    already carries, so nothing is added to say it a second time.
    """
    walked = [identifier]
    while True:
        record = records.get(identifier)
        if record is None:
            return identifier
        evidence = record.get("evidence") or {}
        if evidence.get("reason_category") not in LIFECYCLE_CATEGORIES:
            return identifier
        prior = record.get("supersedes")
        if not isinstance(prior, str) or prior in walked:
            return identifier
        identifier = prior
        walked.append(identifier)


def _contained(claim: Mapping[str, Any], verified: Mapping[str, Any]) -> bool:
    """Containment, not interpretation.

    Every claimed dimension must be one the operator verified, with the value
    the operator verified. Ordering a memory size here would be the
    interpretation the accepted vocabulary rules out, and a dimension nobody
    verified is a claim about something nobody looked at.
    """
    for name, value in claim.items():
        if name not in verified or verified[name] != value:
            return False
    return True


def _human_preflight(actor: Any, approving_authority: Any, *instants: Any) -> None:
    """The structure a human-authorised request must have to be a request.

    Named authority and real instants only. Everything checked here is checked
    before the request is identified, because a value of the wrong form does
    not describe a *different* request -- it describes none.
    """
    _human_authority(actor, approving_authority)
    for instant in instants:
        _aware(instant)


def _digestible(payload: Mapping[str, Any],
                instants: tuple[str, ...]) -> dict[str, Any]:
    """The authoritative payload in the form the released canonicaliser reads.

    Only the named timestamp fields become text, and only because the preflight
    has already proved each of them is a timezone-aware `datetime`. Converting
    by *type* instead would erase the difference between an instant and its own
    ISO rendering: the two would canonicalise identically, and a malformed
    request could borrow an accepted one's identity and be answered with its
    record. A `datetime` anywhere else is left alone, so the released
    canonicaliser refuses it as the unrepresentable value it is.
    """
    return {name: value.isoformat() if name in instants and value is not None
            else value for name, value in payload.items()}


def _governed(store, *, operation: str, request_id: Any,
              payload: Mapping[str, Any], instants: tuple[str, ...], preflight,
              accept, digest_route: str) -> OperationResult:
    """The operation boundary every governed acceptance shares.

    **The digest covers the whole operation.** Every caller-supplied
    authoritative input participates, including the optional ones supplied as
    nothing, so a reused request identity carrying any changed input is a
    conflict rather than a replay of an operation nobody submitted. Nothing
    else participates: not the request identity, not an allocated record
    identity, not a store, and not a resolved prerequisite, because none of
    those is what the caller asked for.

    **Structure is judged before identity.** The preflight runs first, so a
    request identity that cannot be validated, authority that is missing or
    prohibited, an instant that is not an instant, a window that closes before
    it opens, or a payload the released canonicaliser cannot represent is
    refused before the critical section is entered and before replay is
    classified at all. Answering a malformed request with a replay or a
    conflict would report on an operation nobody submitted, and there is
    nothing yet to serialise against either way.

    One acquisition of the critical section, taken before replay lookup and
    held through allocation and the accepted write.
    """
    supplied = request_id if isinstance(request_id, str) else ""
    try:
        identifier = validate_request_id(request_id)
        preflight()
        digestible = _digestible(payload, instants)
        # Declared per operation, with no default, so a new operation has to
        # say which contract it is written against rather than inherit one.
        if digest_route == PREPARED_DIGEST:
            digest = prepare_and_compute_request_digest(operation, digestible)
        else:
            digest = compute_request_digest(operation, digestible)
    except _Refusal as refusal:
        return OperationResult(refusal.outcome, supplied, reason=refusal.reason)
    except Exception:  # noqa: BLE001
        # Including whatever a hostile timestamp raises while being examined or
        # rendered. It is named as malformed content and never echoed.
        return OperationResult(INVALID, supplied, reason=REASON_CONTENT)

    with store.request_critical_section(identifier):
        replay = replay_lookup(store, identifier, digest)
        if replay.status == REPLAY_EXACT:
            return OperationResult(EXACT_REPLAY, identifier, digest,
                                   replay.record_kind, replay.record_id)
        if replay.status == REPLAY_CONFLICT:
            return OperationResult(CONFLICT, identifier, digest,
                                   reason=REASON_CONFLICT)
        try:
            kind, record_id = accept(identifier, digest)
        except _Refusal as refusal:
            return OperationResult(refusal.outcome, identifier, digest,
                                   reason=refusal.reason)
        return OperationResult(ACCEPTED, identifier, digest, kind, record_id)


def _constructed(kind: str, identifier: str, evidence: Mapping[str, Any], build):
    """The complete record, or a controlled refusal naming malformed content.

    Freezing, conversion, evidence validation, and the model's own rules all
    run here, so a caller value that fails any of them is named as malformed
    content rather than raised. A raw exception would carry the rejected value,
    its type, a path, or an address out of the governed boundary.
    """
    try:
        record = build(identifier, evidence)
        validate_record_evidence(kind, record)
        record.to_dict()
    except _Refusal:
        raise
    except Exception:  # noqa: BLE001
        _refuse(INVALID, REASON_CONTENT)
    return record


def _commit(store, kind: str, evidence: Mapping[str, Any],
            build) -> tuple[str, str]:
    """Prove the record is constructible, then allocate through C1 and write.

    Allocation advances a persistent sequence, so nothing is allocated until
    the exact evidence and record content are known to be constructible.
    The proof is a construction against a probe identity of this kind and
    width -- the model's own rules applied to the real content, not a
    restatement of them -- which allocates nothing, writes nothing, and leaves
    nothing behind. Only then does C1 mint the identity the record will carry.
    """
    _constructed(kind, PROBE_IDS[kind], evidence, build)
    identifier = store.allocate_id(kind)
    record = _constructed(kind, identifier, evidence, build)
    store.write(kind, record)
    return kind, identifier


def _evidence(kind: str, *, actor: str, approving_authority: str | None,
              reason_category: str, recorded_at: datetime, request_id: str,
              request_digest: str, causal_references=(),
              trust_evidence_references=()) -> Mapping[str, Any]:
    try:
        return assemble_evidence(
            kind, actor=actor, approving_authority=approving_authority,
            reason_category=reason_category, recorded_at=recorded_at,
            request_id=request_id, request_digest=request_digest,
            causal_references=tuple(causal_references),
            trust_evidence_references=tuple(trust_evidence_references))
    except FabricError:
        _refuse(INVALID, REASON_CONTENT)


# --- 6.1 Declare capability, contract, or package ---------------------------

def declare_capability(store, *, request_id: Any, actor: Any,
                       approving_authority: Any, recorded_at: Any, name: Any,
                       description: Any, effect_class: Any, contract_ids: Any,
                       provenance: Any, notes: Any = None) -> OperationResult:
    """Record an abstract ability. Declaration confers nothing."""
    def accept(identifier, digest):
        _text(name, REASON_CONTENT)
        _text(description, REASON_CONTENT)
        _effect_class(effect_class)
        _mapping(provenance)
        references = _sequence(contract_ids)
        for reference in references:
            _resolve(store, "capability-contract", reference)
        evidence = _evidence(
            "capability-definition", actor=actor,
            approving_authority=approving_authority, reason_category="declaration",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=references)
        return _commit(store, "capability-definition", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-definition"](
                           capability_id=allocated, name=name,
                           description=description, effect_class=effect_class,
                           contract_ids=references, provenance=provenance,
                           notes=notes, evidence=carried))

    return _governed(store, operation="declare-capability", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at, "name": name,
                              "description": description,
                              "effect_class": effect_class,
                              "contract_ids": contract_ids,
                              "provenance": provenance, "notes": notes},
                     instants=("recorded_at",),
                     digest_route=LEGACY_DIGEST,
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at),
                     accept=accept)


def declare_contract(store, *, request_id: Any, actor: Any,
                     approving_authority: Any, recorded_at: Any,
                     capability_id: Any, contract_version: Any, effect_class: Any,
                     determinism_class: Any, request_shape: Any,
                     response_shape: Any, failure_modes: Any,
                     resource_requirements: Any, compatible_with: Any,
                     provenance: Any, description: Any = None) -> OperationResult:
    """Record a versioned interface against a declared capability."""
    def accept(identifier, digest):
        _text(contract_version, REASON_CONTENT)
        _effect_class(effect_class)
        _text(determinism_class, REASON_CONTENT)
        modes = _sequence(failure_modes)
        compatible = _sequence(compatible_with)
        _resolve(store, "capability-definition", capability_id)
        evidence = _evidence(
            "capability-contract", actor=actor,
            approving_authority=approving_authority, reason_category="declaration",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=(capability_id,))
        return _commit(store, "capability-contract", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-contract"](
                           contract_id=allocated, capability_id=capability_id,
                           contract_version=contract_version,
                           effect_class=effect_class,
                           determinism_class=determinism_class,
                           request_shape=request_shape,
                           response_shape=response_shape,
                           failure_modes=modes,
                           resource_requirements=resource_requirements,
                           compatible_with=compatible,
                           provenance=provenance, description=description,
                           evidence=carried))

    return _governed(store, operation="declare-contract", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_id": capability_id,
                              "contract_version": contract_version,
                              "effect_class": effect_class,
                              "determinism_class": determinism_class,
                              "request_shape": request_shape,
                              "response_shape": response_shape,
                              "failure_modes": failure_modes,
                              "resource_requirements": resource_requirements,
                              "compatible_with": compatible_with,
                              "provenance": provenance,
                              "description": description},
                     instants=("recorded_at",),
                     digest_route=LEGACY_DIGEST,
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at),
                     accept=accept)


def declare_package(store, *, request_id: Any, actor: Any,
                    approving_authority: Any, recorded_at: Any, capability_id: Any,
                    contract_id: Any, satisfied_contract_versions: Any,
                    package_version: Any, artifact_reference: Any,
                    resource_requirements: Any, trust_domain: Any, provenance: Any,
                    description: Any = None) -> OperationResult:
    """Record a package claiming contract versions. Nothing is read or run."""
    def accept(identifier, digest):
        _text(package_version, REASON_CONTENT)
        _text(artifact_reference, REASON_CONTENT)
        if trust_domain != PACKAGE_TRUST_DOMAIN:
            _refuse(REFUSED, REASON_TRUST_DOMAIN)
        versions = _sequence(satisfied_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)
        _resolve(store, "capability-definition", capability_id)
        contract = _resolve(store, "capability-contract", contract_id)
        # One package implements one definition against one contract.
        if contract.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_CONTRACT_OWNER)
        # Explicit, never inferred from a version string.
        if contract.get("contract_version") not in versions:
            _refuse(REFUSED, REASON_VERSIONS)
        evidence = _evidence(
            "capability-package", actor=actor,
            approving_authority=approving_authority, reason_category="declaration",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=(capability_id, contract_id))
        return _commit(store, "capability-package", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-package"](
                           capability_package_id=allocated,
                           capability_id=capability_id, contract_id=contract_id,
                           satisfied_contract_versions=versions,
                           package_version=package_version,
                           artifact_reference=artifact_reference,
                           resource_requirements=resource_requirements,
                           trust_domain=trust_domain, provenance=provenance,
                           description=description, evidence=carried))

    return _governed(store, operation="declare-package", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_id": capability_id,
                              "contract_id": contract_id,
                              "satisfied_contract_versions":
                                  satisfied_contract_versions,
                              "package_version": package_version,
                              "artifact_reference": artifact_reference,
                              "resource_requirements": resource_requirements,
                              "trust_domain": trust_domain,
                              "provenance": provenance,
                              "description": description},
                     instants=("recorded_at",),
                     digest_route=LEGACY_DIGEST,
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at),
                     accept=accept)


# --- 6.2 Admit a subject (host) to the fabric -------------------------------

def admit_subject(store, trust_store, *, request_id: Any, actor: Any,
                  approving_authority: Any, recorded_at: Any, evaluated_at: Any,
                  node_identity_reference: Any, fabric_node_trust_record_id: Any,
                  verified_resource_profile: Any, verification_reference: Any,
                  location_class: Any, data_classification: Any,
                  availability_intent: Any, provenance: Any,
                  name: Any = None, description: Any = None) -> OperationResult:
    """Make a machine a fabric participant. There is no automatic path."""
    def accept(identifier, digest):
        _text(node_identity_reference, REASON_CONTENT)
        _text(location_class, REASON_CONTENT)
        _text(data_classification, REASON_CONTENT)
        _text(availability_intent, REASON_CONTENT)
        profile = _mapping(verified_resource_profile)
        # Verified out of band, and provably so. A profile with nothing
        # recording how it was obtained cannot be distinguished from one copied
        # off an advertisement, which §6.2 rejects.
        _text(verification_reference, REASON_UNVERIFIED_PROFILE)
        # A subject cannot approve its own admission.
        if (actor == node_identity_reference
                or approving_authority == node_identity_reference):
            _refuse(REFUSED, REASON_SELF_ADMISSION)

        verification = verify_trust_record(
            trust_store, fabric_node_trust_record_id, evaluated_at=evaluated_at,
            expected_subject_type=HOST_TRUST_DOMAIN)
        if verification.status == UNVERIFIED:
            reason = verification.reasons[0] if verification.reasons else REASON_UNRESOLVED
            _refuse(UNAVAILABLE if reason == TRUST_UNAVAILABLE else REFUSED, reason)
        # The verified subject must be the machine being admitted.
        if verification.subject_id != node_identity_reference:
            _refuse(REFUSED, REASON_SUBJECT_MISMATCH)

        evidence = _evidence(
            "capability-host", actor=actor,
            approving_authority=approving_authority,
            reason_category="subject-admission", recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            trust_evidence_references=(fabric_node_trust_record_id,))
        return _commit(store, "capability-host", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-host"](
                           capability_host_id=allocated,
                           node_identity_reference=node_identity_reference,
                           fabric_node_trust_record_id=fabric_node_trust_record_id,
                           verified_resource_profile=profile,
                           location_class=location_class,
                           data_classification=data_classification,
                           availability_intent=availability_intent,
                           provenance=provenance, name=name,
                           description=description,
                           verification_reference=verification_reference,
                           evidence=carried))

    return _governed(store, operation="admit-subject", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "evaluated_at": evaluated_at,
                              "node_identity_reference": node_identity_reference,
                              "fabric_node_trust_record_id":
                                  fabric_node_trust_record_id,
                              "verified_resource_profile":
                                  verified_resource_profile,
                              "verification_reference": verification_reference,
                              "location_class": location_class,
                              "data_classification":
                                  data_classification,
                              "availability_intent": availability_intent,
                              "provenance": provenance, "name": name,
                              "description": description},
                     instants=("recorded_at", "evaluated_at"),
                     digest_route=LEGACY_DIGEST,
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at, evaluated_at),
                     accept=accept)


# --- 6.3 Register an advertisement ------------------------------------------

def register_advertisement(store, *, request_id: Any, actor: Any, recorded_at: Any,
                           capability_host_id: Any, capability_package_id: Any,
                           contract_id: Any, satisfied_contract_versions: Any,
                           advertised_resource_profile: Any, observed_at: Any,
                           valid_until: Any, provenance: Any,
                           approving_authority: Any = None) -> OperationResult:
    """The subject's own claim. It grants nothing, including to itself.

    **A claim is published by a subject as it is now.** The declaration it
    cites has to be the current one: publishing under a record the operator has
    already replaced attaches a live claim to a stale identity, and a reader
    would have to guess which of the two the host meant. Retaining the claim is
    not the same as authority to admit -- a draining or withheld machine may
    still say what it holds, and nothing may be admitted onto it.
    """
    def preflight():
        # Syntax is structure, so it is judged before the request is
        # identified. Whether the record exists, and whether it is current,
        # are different questions asked after replay has been classified.
        _identifier(capability_host_id, "capability-host")
        _text(actor, REASON_ACTOR)
        # No fresh human approval, and none accepted: recording one would make
        # a self-report into an approval. Refused on structure, so naming an
        # approver can never be mistaken for a differently-identified request.
        if approving_authority is not None:
            _refuse(REFUSED, REASON_UNEXPECTED_AUTHORITY)
        _aware(recorded_at)
        _aware(observed_at)
        _aware(valid_until)
        if valid_until <= observed_at:
            _refuse(REFUSED, REASON_WINDOW)

    def accept(identifier, digest):
        claim = _mapping(advertised_resource_profile)
        versions = _sequence(satisfied_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)

        host = _resolve(store, "capability-host", capability_host_id)
        # A host may advertise only itself.
        if actor != capability_host_id:
            _refuse(REFUSED, REASON_NOT_SUBJECT)
        # Nothing points forward, so the current declaration is the one no
        # other record supersedes. A fork or a loop is reported, never
        # resolved: choosing a head nobody wrote would be the guess this
        # refuses to make.
        links = _successors(store, "capability-host", "capability_host_id",
                            REASON_CHAIN_FORKED)
        if _head_of(links, capability_host_id, REASON_CHAIN_CYCLIC) != capability_host_id:
            _refuse(REFUSED, REASON_HOST_SUPERSEDED)

        package = _resolve(store, "capability-package", capability_package_id)
        _resolve(store, "capability-contract", contract_id)
        if package.get("contract_id") != contract_id:
            _refuse(REFUSED, REASON_PACKAGE_CONTRACT)
        # Explicit declarations only: no range, no upgrade, no inference.
        declared = tuple(package.get("satisfied_contract_versions") or ())
        if any(version not in declared for version in versions):
            _refuse(REFUSED, REASON_VERSIONS)
        # Containment against what the operator verified.
        if not _contained(claim, host.get("verified_resource_profile") or {}):
            _refuse(REFUSED, REASON_RESOURCE_CLAIM)

        evidence = _evidence(
            "capability-advertisement", actor=actor, approving_authority=None,
            reason_category="advertisement-registration", recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            causal_references=(capability_host_id, capability_package_id,
                               contract_id))
        return _commit(store, "capability-advertisement", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-advertisement"](
                           advertisement_id=allocated,
                           capability_host_id=capability_host_id,
                           capability_package_id=capability_package_id,
                           contract_id=contract_id,
                           satisfied_contract_versions=versions,
                           advertised_resource_profile=claim,
                           observed_at=observed_at, valid_until=valid_until,
                           provenance=provenance, evidence=carried))

    # `approving_authority` is part of what was asked for even though the only
    # acceptable value is none: supplying one is a different request, refused
    # as `unexpected-approving-authority` rather than quietly identical.
    return _governed(store, operation="register-advertisement",
                     request_id=request_id,
                     payload={"actor": actor, "recorded_at": recorded_at,
                              "capability_host_id": capability_host_id,
                              "capability_package_id": capability_package_id,
                              "contract_id": contract_id,
                              "satisfied_contract_versions":
                                  satisfied_contract_versions,
                              "advertised_resource_profile":
                                  advertised_resource_profile,
                              "observed_at": observed_at,
                              "valid_until": valid_until,
                              "provenance": provenance,
                              "approving_authority": approving_authority},
                     instants=("recorded_at", "observed_at", "valid_until"),
                     digest_route=LEGACY_DIGEST,
                     preflight=preflight, accept=accept)

# --- 6.4 Admit an instance ---------------------------------------------------

def admit_instance(store, trust_store, *, request_id: Any, actor: Any,
                   approving_authority: Any, recorded_at: Any, evaluated_at: Any,
                   capability_id: Any, capability_package_id: Any,
                   capability_host_id: Any, contract_id: Any,
                   satisfied_contract_versions: Any,
                   verified_resource_profile: Any, admission_decision_id: Any,
                   package_trust_record_id: Any, host_trust_record_id: Any,
                   admission_scope: Any, admitted_at: Any, admitted_until: Any,
                   provenance: Any, advertisement_id: Any = None,
                   endpoint_reference: Any = None, supersedes: Any = None,
                   notes: Any = None) -> OperationResult:
    """Bind one package to one host for one contract. A human decides this.

    **A trust verdict alone never creates an instance**, and neither does an
    advertisement. Both are consulted; the decision is the operator's, and the
    approving authority on this record is what makes the binding exist.

    **Trust is composed by intersection and never inherited.** The package is
    verified in `capability-package`, the host in `fabric-node`, separately,
    through C3 and nowhere else, once each. The effective scope is the
    intersection of both grants with the operator's own bound -- computed here,
    never asserted by the caller -- and an empty dimension admits nothing.

    **Comparison is containment, and versions are declared.** The operator's
    verified profile is authoritative, never the advertised one; no number is
    ordered, no version string is interpreted, and no classification is ranked.

    Nothing about eligibility is computed or stored. These are the
    admission-time preconditions §6.4 requires; the derived verdict is C5's.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at, evaluated_at,
                         admitted_at, admitted_until)
        if admitted_until <= admitted_at:
            _refuse(REFUSED, REASON_WINDOW)
        # Ordering the operator is judged against, at the operator's own
        # instant. Nothing here reads a clock.
        if not admitted_at <= evaluated_at:
            _refuse(REFUSED, REASON_WINDOW)
        _identifier(capability_id, "capability-definition")
        _identifier(contract_id, "capability-contract")
        _identifier(capability_package_id, "capability-package")
        _identifier(capability_host_id, "capability-host")
        _identifier(advertisement_id, "capability-advertisement")
        _optional_identifier(supersedes, "capability-instance")
        _trust_identifier(package_trust_record_id)
        _trust_identifier(host_trust_record_id)
        _text(admission_decision_id, REASON_CONTENT)
        versions = _exact_strings(satisfied_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)
        _mapping(verified_resource_profile)
        _mapping(provenance)
        _admission_scope(admission_scope)

    def accept(identifier, digest):
        versions = _exact_strings(satisfied_contract_versions)
        profile = _mapping(verified_resource_profile)
        bound = _admission_scope(admission_scope)

        # 1. Every reference resolves before any relationship is read from it.
        _resolve(store, "capability-definition", capability_id)
        contract = _resolve(store, "capability-contract", contract_id)
        package = _resolve(store, "capability-package", capability_package_id)
        host = _resolve(store, "capability-host", capability_host_id)
        advertisement = _resolve(store, "capability-advertisement", advertisement_id)
        node = host.get("node_identity_reference")

        # 2. No machine admits its own binding, under either identity it has.
        _no_self_governance(actor, approving_authority, node, capability_host_id)

        # 3. The host declaration must be the current one, and in service.
        #    A superseded declaration is history; a withdrawn machine is one
        #    an operator deliberately removed, and admitting onto it would
        #    contradict the decision rather than observe it.
        links = _successors(store, "capability-host", "capability_host_id",
                            REASON_CHAIN_FORKED)
        if _head_of(links, capability_host_id, REASON_CHAIN_CYCLIC) != capability_host_id:
            _refuse(REFUSED, REASON_HOST_SUPERSEDED)
        if host.get("availability_intent") != "in-service":
            _refuse(REFUSED, REASON_HOST_NOT_IN_SERVICE)

        # 4. The records must describe one binding, not four opinions.
        if package.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_PACKAGE_OWNER)
        if contract.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_CONTRACT_OWNER)
        if package.get("contract_id") != contract_id:
            _refuse(REFUSED, REASON_PACKAGE_CONTRACT)
        if advertisement.get("capability_host_id") != capability_host_id:
            _refuse(REFUSED, REASON_ADVERT_SUBJECT)
        if advertisement.get("contract_id") != contract_id:
            _refuse(REFUSED, REASON_ADVERT_CONTRACT)
        if advertisement.get("capability_package_id") != capability_package_id:
            _refuse(REFUSED, REASON_ADVERT_PACKAGE)

        # 5. Declared versions only: set membership, twice, with no arithmetic.
        declared = tuple(package.get("satisfied_contract_versions") or ())
        advertised = tuple(advertisement.get("satisfied_contract_versions") or ())
        if any(version not in declared for version in versions):
            _refuse(REFUSED, REASON_VERSIONS)
        if any(version not in advertised for version in versions):
            _refuse(REFUSED, REASON_VERSIONS)

        # 6. Both clocks, at the caller's own evaluation instant.
        observed = _stored_instant(advertisement.get("observed_at"))
        expires = _stored_instant(advertisement.get("valid_until"))
        if observed is None or expires is None:
            _refuse(REFUSED, REASON_ADVERT_STALE)
        if not observed <= evaluated_at < expires:
            _refuse(REFUSED, REASON_ADVERT_STALE)
        if not observed <= admitted_at:
            # A binding cannot have begun before the claim justifying it.
            _refuse(REFUSED, REASON_WINDOW)
        if evaluated_at >= admitted_until:
            _refuse(REFUSED, REASON_ADMISSION_EXPIRED)

        # 7. Supersession compatibility, before Trust is troubled.
        prior_root = None
        if supersedes is not None:
            records = {record.get("instance_id"): record
                       for record in store.list_records("capability-instance")}
            prior = _resolve(store, "capability-instance", supersedes)
            instance_links = _successors(store, "capability-instance",
                                         "instance_id", REASON_INSTANCE_FORKED)
            if supersedes in instance_links:
                _refuse(REFUSED, REASON_SUPERSEDES_SUPERSEDED)
            if prior.get("lifecycle_state") != "admitted":
                _refuse(REFUSED, REASON_SUPERSEDES_NOT_ADMITTED)
            # Migration destroys one binding and declares another against the
            # same capability and package identities. A package change is not
            # a supersession of the binding; it is a new binding and a route.
            if prior.get("capability_id") != capability_id:
                _refuse(REFUSED, REASON_SUPERSEDES_CAPABILITY)
            if prior.get("contract_id") != contract_id:
                _refuse(REFUSED, REASON_SUPERSEDES_CONTRACT)
            if prior.get("capability_package_id") != capability_package_id:
                _refuse(REFUSED, REASON_SUPERSEDES_PACKAGE)
            prior_root = _binding_root(records, supersedes)

        # 8. Trust, twice, in two domains, through C3 and nowhere else.
        package_standing = _verified_standing(
            trust_store, package_trust_record_id, evaluated_at,
            PACKAGE_TRUST_DOMAIN)
        host_standing = _verified_standing(
            trust_store, host_trust_record_id, evaluated_at, HOST_TRUST_DOMAIN)
        # Each verified subject must be the fabric subject it authorises. A
        # package's is its own record identity: trust is granted per contract,
        # and only the package record knows which contract it implements.
        if package_standing.subject_id != capability_package_id:
            _refuse(REFUSED, REASON_SUBJECT_MISMATCH)
        if host_standing.subject_id != node:
            _refuse(REFUSED, REASON_SUBJECT_MISMATCH)
        if package_standing.scope is None or host_standing.scope is None:
            _refuse(REFUSED, REASON_NO_SCOPE)
        _within_window(package_standing.scope, evaluated_at)
        _within_window(host_standing.scope, evaluated_at)

        # 9. Containment against what the operator verified, never what the
        #    host claimed, and never an ordering of two numbers.
        verified = host.get("verified_resource_profile")
        if not isinstance(verified, Mapping) or dict(profile) != dict(verified):
            _refuse(REFUSED, REASON_RESOURCE_CLAIM)
        requirements = package.get("resource_requirements")
        if not isinstance(requirements, Mapping) or not _contained(requirements, verified):
            _refuse(REFUSED, REASON_RESOURCE_CLAIM)

        # 10. The intersection, computed here. Then the classification the
        #     machine is declared to handle, compared by membership only.
        effective = _effective_scope(package_standing.scope, host_standing.scope, bound)
        declared_class = host.get("data_classification")
        for classification in effective[SCOPE_CLASSIFICATIONS]:
            if classification != declared_class:
                _refuse(REFUSED, REASON_CLASSIFICATION)

        references = [capability_id, contract_id, capability_package_id,
                      capability_host_id, advertisement_id]
        if supersedes is not None:
            references.append(supersedes)
        evidence = _evidence(
            "capability-instance", actor=actor,
            approving_authority=approving_authority,
            reason_category="supersession" if supersedes is not None
            else "instance-admission",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=tuple(references),
            trust_evidence_references=(package_trust_record_id,
                                       host_trust_record_id))
        kind, allocated = _commit(store, "capability-instance", evidence,
                                  lambda given, carried: RECORD_MODELS[
                                      "capability-instance"](
                                      instance_id=given, capability_id=capability_id,
                                      capability_package_id=capability_package_id,
                                      capability_host_id=capability_host_id,
                                      contract_id=contract_id,
                                      satisfied_contract_versions=versions,
                                      verified_resource_profile=profile,
                                      admission_decision_id=admission_decision_id,
                                      package_trust_record_id=package_trust_record_id,
                                      host_trust_record_id=host_trust_record_id,
                                      effective_scope=effective,
                                      admitted_at=admitted_at,
                                      admitted_until=admitted_until,
                                      lifecycle_state="admitted",
                                      advertisement_id=advertisement_id,
                                      endpoint_reference=endpoint_reference,
                                      supersedes=supersedes, provenance=provenance,
                                      notes=notes, evidence=carried))
        # C1 allocates from a sequence that never reuses a value, so a fresh
        # identity cannot be the identity it supersedes.
        if allocated == supersedes or (prior_root is not None and allocated == prior_root):
            _refuse(REFUSED, REASON_SUPERSEDES_CAPABILITY)
        return kind, allocated

    return _governed(store, operation="admit-instance", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "evaluated_at": evaluated_at,
                              "capability_id": capability_id,
                              "capability_package_id": capability_package_id,
                              "capability_host_id": capability_host_id,
                              "contract_id": contract_id,
                              "satisfied_contract_versions":
                                  satisfied_contract_versions,
                              "verified_resource_profile":
                                  verified_resource_profile,
                              "admission_decision_id": admission_decision_id,
                              "package_trust_record_id": package_trust_record_id,
                              "host_trust_record_id": host_trust_record_id,
                              "admission_scope": admission_scope,
                              "admitted_at": admitted_at,
                              "admitted_until": admitted_until,
                              "advertisement_id": advertisement_id,
                              "endpoint_reference": endpoint_reference,
                              "provenance": provenance,
                              "supersedes": supersedes, "notes": notes},
                     instants=("recorded_at", "evaluated_at", "admitted_at",
                               "admitted_until"),
                     digest_route=PREPARED_DIGEST,
                     preflight=preflight, accept=accept)


# --- 6.5 Create or supersede a route -----------------------------------------

def create_route(store, *, request_id: Any, actor: Any, approving_authority: Any,
                 recorded_at: Any, capability_id: Any, contract_id: Any,
                 accepted_contract_versions: Any, locality: Any,
                 candidate_instances: Any, data_classification: Any,
                 route_version: Any, provenance: Any, description: Any = None,
                 overlap_starts_at: Any = None, overlap_ends_at: Any = None,
                 supersedes: Any = None, notes: Any = None) -> OperationResult:
    """Declare which admitted bindings may serve a request class, in order.

    **The order is written by a human and stored.** Nothing here derives it,
    and nothing here consults load, latency, success rate, health, or any other
    measurement -- a router that orders candidates by observed behaviour is
    deriving placement from reasoning.

    A route targets admitted bindings only: targeting an advertisement would
    mean routing to a self-report, and targeting a withdrawn binding would mean
    routing to a decision somebody already reversed. **Cutover is a route
    change**, so a new version is a new record naming the one it supersedes,
    and the prior route is left exactly as written.

    A declared overlap window asserts that old and new coexist, so it is
    permitted only where the candidate lists actually show both. It is
    evidence: nothing here schedules, activates, or reroutes anything.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at)
        _identifier(capability_id, "capability-definition")
        _identifier(contract_id, "capability-contract")
        _optional_identifier(supersedes, "capability-route")
        _member_of(locality, LOCALITIES, REASON_UNKNOWN_LOCALITY)
        _member_of(data_classification, WORKLOAD_DATA_CLASSIFICATIONS,
                   REASON_UNKNOWN_CLASSIFICATION)
        if isinstance(route_version, bool) or not isinstance(route_version, int):
            _refuse(INVALID, REASON_ROUTE_VERSION)
        if route_version < 1:
            _refuse(REFUSED, REASON_ROUTE_VERSION)
        versions = _exact_strings(accepted_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)
        candidates = _exact_strings(candidate_instances, REASON_DUPLICATE_CANDIDATE)
        if not candidates:
            _refuse(REFUSED, REASON_NO_CANDIDATE)
        for candidate in candidates:
            _identifier(candidate, "capability-instance")
        _mapping(provenance)
        if (overlap_starts_at is None) != (overlap_ends_at is None):
            _refuse(INVALID, REASON_OVERLAP_MALFORMED)
        if overlap_starts_at is not None:
            _aware(overlap_starts_at)
            _aware(overlap_ends_at)
            if overlap_ends_at <= overlap_starts_at:
                _refuse(REFUSED, REASON_WINDOW)
            if supersedes is None:
                _refuse(REFUSED, REASON_OVERLAP_NO_SUPERSESSION)

    def accept(identifier, digest):
        versions = _exact_strings(accepted_contract_versions)
        candidates = _exact_strings(candidate_instances, REASON_DUPLICATE_CANDIDATE)

        _resolve(store, "capability-definition", capability_id)
        contract = _resolve(store, "capability-contract", contract_id)
        if contract.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_CONTRACT_OWNER)

        prior_candidates: tuple = ()
        if supersedes is not None:
            prior = _resolve(store, "capability-route", supersedes)
            if (prior.get("capability_id") != capability_id
                    or prior.get("contract_id") != contract_id):
                _refuse(REFUSED, REASON_SUPERSEDES_SUBJECT)
            previous = prior.get("route_version")
            if (isinstance(previous, bool) or not isinstance(previous, int)
                    or route_version <= previous):
                _refuse(REFUSED, REASON_ROUTE_VERSION)
            prior_candidates = tuple(prior.get("candidate_instances") or ())

        records = {record.get("instance_id"): record
                   for record in store.list_records("capability-instance")}
        for candidate in candidates:
            instance = _resolve(store, "capability-instance", candidate)
            if (instance.get("capability_id") != capability_id
                    or instance.get("contract_id") != contract_id):
                _refuse(REFUSED, REASON_CANDIDATE_OWNER)
            # A route names a binding, and a binding is named by the record
            # that began it. A lifecycle version is a statement about that
            # binding, not another thing to route to.
            if _binding_root(records, candidate) != candidate:
                _refuse(REFUSED, REASON_NOT_BINDING_ROOT)
            if instance.get("lifecycle_state") != "admitted":
                _refuse(REFUSED, REASON_NOT_BINDING_ROOT)

        if overlap_starts_at is not None:
            carried = set(candidates) & set(prior_candidates)
            arrived = set(candidates) - set(prior_candidates)
            if not arrived:
                _refuse(REFUSED, REASON_OVERLAP_NO_CUTOVER)
            if not carried:
                _refuse(REFUSED, REASON_OVERLAP_NO_COEXISTENCE)

        window = None
        if overlap_starts_at is not None:
            window = {"starts_at": overlap_starts_at.isoformat(),
                      "ends_at": overlap_ends_at.isoformat()}

        references = [capability_id, contract_id, *candidates]
        if supersedes is not None:
            references.append(supersedes)
        evidence = _evidence(
            "capability-route", actor=actor,
            approving_authority=approving_authority,
            reason_category="supersession" if supersedes is not None
            else "route-change",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=tuple(references))
        return _commit(store, "capability-route", evidence,
                       lambda given, carried: RECORD_MODELS[
                           "capability-route"](
                           route_id=given, route_version=route_version,
                           capability_id=capability_id, contract_id=contract_id,
                           accepted_contract_versions=versions,
                           locality=locality, candidate_instances=candidates,
                           data_classification=data_classification,
                           provenance=provenance, description=description,
                           overlap_window=window, supersedes=supersedes,
                           notes=notes, evidence=carried))

    # `candidate_instances` is authoritative in order, so it is digested in
    # order. `accepted_contract_versions` is a set by the released contract.
    return _governed(store, operation="create-route", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_id": capability_id,
                              "contract_id": contract_id,
                              "accepted_contract_versions":
                                  accepted_contract_versions,
                              "locality": locality,
                              "candidate_instances": candidate_instances,
                              "data_classification": data_classification,
                              "route_version": route_version,
                              "provenance": provenance,
                              "description": description,
                              "overlap_starts_at": overlap_starts_at,
                              "overlap_ends_at": overlap_ends_at,
                              "supersedes": supersedes, "notes": notes},
                     instants=("recorded_at", "overlap_starts_at",
                               "overlap_ends_at"),
                     digest_route=PREPARED_DIGEST,
                     preflight=preflight, accept=accept)


# --- 6.6 Withdraw, refresh, or retire by decision ----------------------------

def _host_predecessor(store, capability_host_id: str) -> Mapping[str, Any]:
    """The named host declaration, proved to be the current one."""
    prior = _resolve(store, "capability-host", capability_host_id)
    links = _successors(store, "capability-host", "capability_host_id",
                        REASON_CHAIN_FORKED)
    if _head_of(links, capability_host_id, REASON_CHAIN_CYCLIC) != capability_host_id:
        _refuse(REFUSED, REASON_PREDECESSOR_NOT_CURRENT)
    return prior


def _host_successor(allocated: str, prior: Mapping[str, Any], *,
                    availability_intent: Any, provenance: Any, notes: Any,
                    capability_host_id: str, carried: Mapping[str, Any],
                    trust_record: Any = None, verified_resource_profile: Any = None,
                    verification_reference: Any = None, location_class: Any = None,
                    data_classification: Any = None):
    """The next declaration for the same machine.

    Everything the operator did not decide is carried across unchanged, and
    `name` and `description` are carried always: a new authoritative record to
    change a display label would declare nothing about the machine.
    """
    def kept(supplied, field):
        return prior.get(field) if supplied is None else supplied

    return RECORD_MODELS["capability-host"](
        capability_host_id=allocated,
        node_identity_reference=prior.get("node_identity_reference"),
        fabric_node_trust_record_id=kept(trust_record, "fabric_node_trust_record_id"),
        verified_resource_profile=kept(verified_resource_profile,
                                       "verified_resource_profile"),
        location_class=kept(location_class, "location_class"),
        data_classification=kept(data_classification,
                                         "data_classification"),
        availability_intent=availability_intent,
        provenance=provenance, name=prior.get("name"),
        description=prior.get("description"),
        verification_reference=kept(verification_reference, "verification_reference"),
        supersedes=capability_host_id, notes=notes, evidence=carried)


def withdraw_subject(store, *, request_id: Any, actor: Any,
                     approving_authority: Any, recorded_at: Any,
                     capability_host_id: Any, availability_intent: Any,
                     provenance: Any, notes: Any = None) -> OperationResult:
    """Take a subject out of service by decision. Nothing is edited or deleted.

    **Withdrawal is a decision, not an event.** A host that fails, disappears,
    or falls silent has changed no authoritative state; a machine leaves
    service because an operator said so, and `availability_intent` is where
    that is said.

    This operation only ever moves *away* from service, or deeper between
    non-serving states. Returning is a grant of authority and belongs to
    `refresh_subject`, which evaluates then-current trust. A transition to the
    intent already declared is refused rather than written: an immutable record
    that declares nothing new is duplication, and it would silently move the
    head an advertisement has to cite.

    **No trust is consulted and none is changed.** Withdrawing says nothing
    about whether a machine is trusted; the successor references the same trust
    record rather than restating what it says.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at)
        _identifier(capability_host_id, "capability-host")
        _member_of(availability_intent, AVAILABILITY_INTENTS, REASON_UNKNOWN_INTENT)
        _mapping(provenance)

    def accept(identifier, digest):
        prior = _host_predecessor(store, capability_host_id)
        node = prior.get("node_identity_reference")
        _no_self_governance_of(actor, approving_authority, node, capability_host_id)

        declared = prior.get("availability_intent")
        if availability_intent == declared:
            _refuse(REFUSED, REASON_INTENT_UNCHANGED)
        if availability_intent == "in-service":
            _refuse(REFUSED, REASON_RETURN_NEEDS_REFRESH)
        if declared == "withheld" and availability_intent == "draining":
            # Draining still lets what is already admitted be considered;
            # withheld does not. Moving that way grants more, so it takes the
            # path that re-evaluates standing.
            _refuse(REFUSED, REASON_RETURN_NEEDS_REFRESH)

        evidence = _evidence(
            "capability-host", actor=actor,
            approving_authority=approving_authority,
            reason_category="supersession", recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            causal_references=(capability_host_id,),
            trust_evidence_references=(prior.get("fabric_node_trust_record_id"),))
        return _commit(store, "capability-host", evidence,
                       lambda allocated, carried: _host_successor(
                           allocated, prior, availability_intent=availability_intent,
                           provenance=provenance, notes=notes,
                           capability_host_id=capability_host_id, carried=carried))

    return _governed(store, operation="withdraw-subject", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_host_id": capability_host_id,
                              "availability_intent": availability_intent,
                              "provenance": provenance, "notes": notes},
                     instants=("recorded_at",),
                     digest_route=PREPARED_DIGEST,
                     preflight=preflight, accept=accept)


def refresh_subject(store, trust_store, *, request_id: Any, actor: Any,
                    approving_authority: Any, recorded_at: Any, evaluated_at: Any,
                    capability_host_id: Any, fabric_node_trust_record_id: Any,
                    verified_resource_profile: Any, verification_reference: Any,
                    location_class: Any, data_classification: Any,
                    availability_intent: Any, provenance: Any,
                    notes: Any = None) -> OperationResult:
    """Re-declare what was verified about a machine, against current trust.

    The only way a subject returns to service, and the only way a declaration
    cites a renewed trust record. Both are grants of authority, so both are
    made against standing evaluated now rather than standing evaluated once.

    A refresh that changes no authoritative fact is refused before trust is
    consulted: it would be a new immutable record declaring nothing, and the
    comparison needs no verdict to reach. The prior record keeps its own trust
    reference forever -- history is not restated when it is superseded.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at, evaluated_at)
        _identifier(capability_host_id, "capability-host")
        _trust_identifier(fabric_node_trust_record_id)
        _text(verification_reference, REASON_UNVERIFIED_PROFILE)
        _member_of(location_class, LOCATION_CLASSES, REASON_CONTENT)
        _member_of(data_classification, WORKLOAD_DATA_CLASSIFICATIONS,
                   REASON_UNKNOWN_CLASSIFICATION)
        _member_of(availability_intent, AVAILABILITY_INTENTS, REASON_UNKNOWN_INTENT)
        _mapping(verified_resource_profile)
        _mapping(provenance)

    def accept(identifier, digest):
        prior = _host_predecessor(store, capability_host_id)
        node = prior.get("node_identity_reference")
        _no_self_governance_of(actor, approving_authority, node, capability_host_id)

        supplied = {
            "fabric_node_trust_record_id": fabric_node_trust_record_id,
            "verified_resource_profile": dict(_mapping(verified_resource_profile)),
            "verification_reference": verification_reference,
            "location_class": location_class,
            "data_classification": data_classification,
            "availability_intent": availability_intent,
        }
        unchanged = True
        for field in AUTHORITATIVE_HOST_FIELDS:
            stored = prior.get(field)
            if field == "verified_resource_profile":
                stored = dict(stored) if isinstance(stored, Mapping) else stored
            if supplied[field] != stored:
                unchanged = False
                break
        if unchanged:
            _refuse(REFUSED, REASON_REFRESH_NOTHING)

        standing = _verified_standing(trust_store, fabric_node_trust_record_id,
                                      evaluated_at, HOST_TRUST_DOMAIN)
        if standing.subject_id != node:
            _refuse(REFUSED, REASON_SUBJECT_MISMATCH)

        evidence = _evidence(
            "capability-host", actor=actor,
            approving_authority=approving_authority,
            reason_category="supersession", recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            causal_references=(capability_host_id,),
            trust_evidence_references=(fabric_node_trust_record_id,))
        return _commit(store, "capability-host", evidence,
                       lambda allocated, carried: _host_successor(
                           allocated, prior, availability_intent=availability_intent,
                           provenance=provenance, notes=notes,
                           capability_host_id=capability_host_id, carried=carried,
                           trust_record=fabric_node_trust_record_id,
                           verified_resource_profile=verified_resource_profile,
                           verification_reference=verification_reference,
                           location_class=location_class,
                           data_classification=data_classification))

    return _governed(store, operation="refresh-subject", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "evaluated_at": evaluated_at,
                              "capability_host_id": capability_host_id,
                              "fabric_node_trust_record_id":
                                  fabric_node_trust_record_id,
                              "verified_resource_profile":
                                  verified_resource_profile,
                              "verification_reference": verification_reference,
                              "location_class": location_class,
                              "data_classification":
                                  data_classification,
                              "availability_intent": availability_intent,
                              "provenance": provenance, "notes": notes},
                     instants=("recorded_at", "evaluated_at"),
                     digest_route=PREPARED_DIGEST,
                     preflight=preflight, accept=accept)


def _lifecycle_decision(store, *, operation: str, request_id: Any, actor: Any,
                        approving_authority: Any, recorded_at: Any,
                        instance_id: Any, provenance: Any, notes: Any,
                        target: str, category: str, allowed_from: tuple[str, ...]
                        ) -> OperationResult:
    """One lifecycle version of one binding. Shared by withdrawal and retirement.

    Every binding fact is carried across byte-identically; only the state, the
    link to what it continues, and the evidence differ. No trust is consulted,
    no advertisement is read, and no precondition is re-evaluated -- ending a
    binding is a decision about a record, not a fresh admission of one.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at)
        _identifier(instance_id, "capability-instance")
        _mapping(provenance)

    def accept(identifier, digest):
        prior = _resolve(store, "capability-instance", instance_id)
        links = _successors(store, "capability-instance", "instance_id",
                            REASON_INSTANCE_FORKED)
        if _head_of(links, instance_id, REASON_INSTANCE_CYCLIC) != instance_id:
            _refuse(REFUSED, REASON_INSTANCE_NOT_HEAD)
        if prior.get("lifecycle_state") not in allowed_from:
            _refuse(REFUSED, REASON_LIFECYCLE_ILLEGAL)

        host = _resolve(store, "capability-host", prior.get("capability_host_id"))
        _no_self_governance_of(actor, approving_authority,
                               host.get("node_identity_reference"),
                               prior.get("capability_host_id"))

        # A stored instant is text on disk. Read back as the instant it was
        # written from, so the window this binding was admitted for is carried
        # across rather than restated.
        opened = _stored_instant(prior.get("admitted_at"))
        closed = _stored_instant(prior.get("admitted_until"))
        if opened is None or closed is None:
            _refuse(INVALID, REASON_CONTENT)

        references = [prior.get("capability_id"), prior.get("contract_id"),
                      prior.get("capability_package_id"),
                      prior.get("capability_host_id"), instance_id]
        advertisement = prior.get("advertisement_id")
        if isinstance(advertisement, str):
            references.append(advertisement)
        package_trust = prior.get("package_trust_record_id")
        host_trust = prior.get("host_trust_record_id")
        evidence = _evidence(
            "capability-instance", actor=actor,
            approving_authority=approving_authority, reason_category=category,
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=tuple(references),
            trust_evidence_references=(package_trust, host_trust))
        return _commit(store, "capability-instance", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-instance"](
                           instance_id=allocated,
                           capability_id=prior.get("capability_id"),
                           capability_package_id=prior.get("capability_package_id"),
                           capability_host_id=prior.get("capability_host_id"),
                           contract_id=prior.get("contract_id"),
                           satisfied_contract_versions=tuple(
                               prior.get("satisfied_contract_versions") or ()),
                           verified_resource_profile=prior.get(
                               "verified_resource_profile"),
                           admission_decision_id=prior.get("admission_decision_id"),
                           package_trust_record_id=package_trust,
                           host_trust_record_id=host_trust,
                           effective_scope=prior.get("effective_scope"),
                           admitted_at=opened, admitted_until=closed,
                           lifecycle_state=target,
                           advertisement_id=advertisement,
                           endpoint_reference=prior.get("endpoint_reference"),
                           supersedes=instance_id, provenance=provenance,
                           notes=notes, evidence=carried))

    return _governed(store, operation=operation, request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "instance_id": instance_id,
                              "provenance": provenance, "notes": notes},
                     instants=("recorded_at",),
                     digest_route=PREPARED_DIGEST,
                     preflight=preflight, accept=accept)


def withdraw_instance(store, *, request_id: Any, actor: Any,
                      approving_authority: Any, recorded_at: Any,
                      instance_id: Any, provenance: Any,
                      notes: Any = None) -> OperationResult:
    """Take a binding out of service by decision. It never returns to admitted.

    Withdrawal ends what the binding did without declaring the question of it
    closed: a later decision may retire it. What it never does is come back --
    re-admission is a new binding, evaluated against then-current evidence,
    because a binding restored on evidence checked long ago would be trust on
    first use with a longer gap.
    """
    return _lifecycle_decision(
        store, operation="withdraw-instance", request_id=request_id, actor=actor,
        approving_authority=approving_authority, recorded_at=recorded_at,
        instance_id=instance_id, provenance=provenance, notes=notes,
        target="withdrawn", category="withdrawal", allowed_from=("admitted",))


def retire_instance(store, *, request_id: Any, actor: Any,
                    approving_authority: Any, recorded_at: Any,
                    instance_id: Any, provenance: Any,
                    notes: Any = None) -> OperationResult:
    """End a binding permanently. Retirement is terminal, and it deletes nothing.

    A retired binding stays retired. A host returning, an advertisement
    arriving, a route changing, or trust being granted again changes nothing
    about it: retirement is a decision, and only a new decision creating a new
    binding puts work anywhere. Every record stays exactly as written.
    """
    return _lifecycle_decision(
        store, operation="retire-instance", request_id=request_id, actor=actor,
        approving_authority=approving_authority, recorded_at=recorded_at,
        instance_id=instance_id, provenance=provenance, notes=notes,
        target="retired", category="retirement",
        allowed_from=("admitted", "withdrawn"))
