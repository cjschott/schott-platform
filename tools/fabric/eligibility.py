"""Derived eligibility for one admitted binding, at one supplied instant.

This is C5. It answers a question and nothing else: *may this binding serve
this request, now?* It stores no answer, because eligibility is derived, and a
derived answer written back becomes a decision nobody made.

**Every enumerated condition is checked individually.** The accepted schema
lists twelve that belong here, and the prose that calls them "eight" is exactly
how an enumerated check quietly disappears. Each one is evaluated, each one is
reported by name, and **every** unmet condition is returned rather than the
first — an operator holding one reason during an incident will fix it and find
the next.

**Quarantine and drain stay distinct.** One is a trust judgement that something
is suspect; the other is an operator deliberately withdrawing a working
machine. Reporting either as the other destroys a difference an operator needs.

**It is pure and total.** No clock of its own, no chance, no environment, no
network, no child process, no filesystem mutation, and no identifier
allocation. The instant arrives from the caller, and every defect — a malformed
request, an unreadable store, an absent host — resolves to *ineligible with the
reason named* rather than to an exception. Anything unmet, unreadable, or
indeterminate is ineligible: a caller who has to catch to learn the verdict has
no verdict, and a condition nobody could read is not a condition that passed.

**It composes nothing and chooses nothing.** Ordering candidates, honouring
declared candidate lists, and effect-class constraints are C6's, in increment 9.
The two conditions the schema assigns to C6 are absent here on purpose.

Conditions, vocabulary, and identifier widths come from the accepted
`platform-model/schemas/capability-instance.schema.yaml` and from
docs/decisions/ADR-0012-distributed-capability-fabric.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from ..trust.models import TrustState
from .identifiers import ID_FIELDS, PATTERNS
from .models import WORKLOAD_DATA_CLASSIFICATIONS
from .trust_adapter import REASON_NOT_USABLE, REASON_UNREADABLE, verify_trust_record

# The two domains a binding composes. Trusting a package trusts no machine and
# trusting a machine trusts no package, so each is asked about separately, in
# its own domain, through C3 and nowhere else.
PACKAGE_TRUST_DOMAIN = "capability-package"
HOST_TRUST_DOMAIN = "fabric-node"

# A condition holds, fails, or could not be read. The third is not a softer
# second: it is refused exactly as hard, and it exists so a verdict can say
# which of the two happened.
MET = "met"
UNMET = "unmet"
INDETERMINATE = "indeterminate"

# Exactly the conditions the accepted schema assigns to C5, in schema order.
# The two it assigns to C6 are that component's, at increment 9, and pulling
# them forward would put a selection constraint inside a per-candidate verdict.
CONDITION_IDS = tuple(f"ELIG-{number}" for number in range(1, 13))

# What a request classification is, taken from the fields the accepted policy
# declaration binds a request class by. `locality` is deliberately not among
# them: it constrains which eligible candidate may be chosen, which is a
# selection question and not a property of one candidate.
REQUEST_FIELDS = ("accepted_contract_versions", "capability_id", "contract_id",
                  "data_classification")

# The released Trust Plane scope vocabulary, as the effective intersection
# carries it. Dimensions only.
SCOPE_DIMENSIONS = ("permitted_capabilities", "permitted_operations",
                    "permitted_data_classifications", "permitted_targets")
SCOPE_CLASSIFICATIONS = "permitted_data_classifications"

IN_SERVICE = "in-service"
ADMITTED = "admitted"

# Controlled refusal vocabulary. Deterministic by construction: nothing here is
# derived from an exception, a path, or a rejected value, because a reason a
# caller can depend on cannot be a message somebody wrote for a log.
REASON_MALFORMED_IDENTITY = "malformed-instance-identity"
REASON_MALFORMED_REQUEST = "malformed-request-classification"
REASON_NAIVE_INSTANT = "evaluation-instant-carries-no-offset"
REASON_STORE_UNREADABLE = "store-unreadable"
REASON_INSTANCE_NOT_FOUND = "instance-not-found"
REASON_INSTANCE_CHAIN = "instance-chain-unreadable"
REASON_NOT_ADMITTED = "instance-not-admitted"

REASON_HOST_UNRESOLVED = "host-not-resolvable"
REASON_HOST_CHAIN = "host-chain-unreadable"
REASON_PACKAGE_UNRESOLVED = "package-not-resolvable"
REASON_CONTRACT_UNRESOLVED = "contract-not-resolvable"

REASON_PACKAGE_SUBJECT = "package-trust-subject-mismatch"
REASON_HOST_SUBJECT = "host-trust-subject-mismatch"
REASON_CONTRACT_NOT_REQUESTED = "contract-not-of-request"
REASON_CONTRACT_VERSIONS = "contract-version-not-accepted"
REASON_PACKAGE_VERSIONS = "package-version-not-accepted"
REASON_RESOURCES = "resource-profile-does-not-satisfy-requirements"
REASON_ADVERT_ABSENT = "advertisement-absent"
REASON_ADVERT_UNRESOLVED = "advertisement-not-resolvable"
REASON_ADVERT_STALE = "advertisement-not-fresh"
REASON_ADMISSION_ABSENT = "admission-decision-absent"
REASON_ADMISSION_UNAPPROVED = "admission-not-human-approved"
REASON_ADMISSION_NOT_OPEN = "admission-window-not-open"
REASON_ADMISSION_EXPIRED = "admission-window-expired"
REASON_EMPTY_SCOPE = "empty-effective-scope"
REASON_SCOPE_REFUSES = "effective-scope-does-not-permit-request"
REASON_CLASSIFICATION = "data-classification-not-declared-by-host"
REASON_HOST_QUARANTINED = "host-quarantined"
REASON_PACKAGE_QUARANTINED = "package-quarantined"
REASON_DRAINED = "candidate-manually-drained"

# Which defect a chain traversal reports, per record class it may walk.
_ABSENT = {"capability-instance": REASON_INSTANCE_NOT_FOUND,
           "capability-host": REASON_HOST_UNRESOLVED}
_CHAIN_DEFECT = {"capability-instance": REASON_INSTANCE_CHAIN,
                 "capability-host": REASON_HOST_CHAIN}

# Which successors continue the binding they name. A withdrawal or a
# retirement is another lifecycle version of the same binding; a declared
# supersession destroys one binding and declares another, so it begins a chain
# rather than extending one. The accepted `capability-instance` schema reads
# that difference from the evidence category each record already carries.
LIFECYCLE_CATEGORIES = ("withdrawal", "retirement")


@dataclass(frozen=True)
class ConditionResult:
    """One enumerated condition, and why it did not hold."""

    condition_id: str
    status: str
    reason: str | None = None


@dataclass(frozen=True)
class EligibilityVerdict:
    """One derived answer about one binding at one instant.

    Frozen, because a verdict a caller already holds must not change
    underneath them, and because a mutable verdict is one edit away from being
    treated as the state it is explicitly not.
    """

    instance_id: str | None
    eligible: bool
    evaluated_at: str | None
    conditions: tuple[ConditionResult, ...]
    reasons: tuple[str, ...]

    @property
    def unmet(self) -> tuple[str, ...]:
        """Every condition that did not hold, in schema order."""
        return tuple(result.condition_id for result in self.conditions
                     if result.status != MET)

    def to_dict(self) -> dict[str, Any]:
        return {
            "instance_id": self.instance_id,
            "eligible": self.eligible,
            "evaluated_at": self.evaluated_at,
            "conditions": [{"condition_id": result.condition_id,
                            "status": result.status,
                            "reason": result.reason}
                           for result in self.conditions],
            "unmet": list(self.unmet),
            "reasons": list(self.reasons),
        }


def _verdict(instance_id: str | None, stamp: str | None,
             conditions: tuple[ConditionResult, ...],
             disqualifications: tuple[str, ...] = ()) -> EligibilityVerdict:
    """Assemble the answer. Eligible means nothing had anything to say."""
    reasons: list[str] = []
    for reason in (*disqualifications,
                   *(result.reason for result in conditions if result.reason)):
        if reason not in reasons:
            reasons.append(reason)
    return EligibilityVerdict(instance_id=instance_id, eligible=not reasons,
                              evaluated_at=stamp, conditions=conditions,
                              reasons=tuple(reasons))


def _ungrounded(instance_id: str | None, stamp: str | None,
                reason: str) -> EligibilityVerdict:
    """Nothing could be judged, so nothing is met.

    Every condition is reported indeterminate rather than omitted: a verdict
    that simply left them out would read as a shorter list of things that
    passed.
    """
    return _verdict(instance_id, stamp,
                    tuple(ConditionResult(condition, INDETERMINATE, reason)
                          for condition in CONDITION_IDS))


def _identity(value: Any, kind: str) -> str | None:
    """A record identity exactly as the accepted schema writes it, or nothing."""
    if not isinstance(value, str) or not PATTERNS[kind].fullmatch(value):
        return None
    return value


def _instant(value: Any) -> datetime | None:
    """A stored timestamp, placed. A time without a zone is not a point in time."""
    if isinstance(value, datetime):
        moment = value
    elif isinstance(value, str):
        try:
            moment = datetime.fromisoformat(value)
        except ValueError:
            return None
    else:
        return None
    if moment.tzinfo is None or moment.tzinfo.utcoffset(moment) is None:
        return None
    return moment


def _members(value: Any) -> tuple[str, ...] | None:
    """A non-empty sequence of exact text, or nothing at all."""
    if isinstance(value, str) or not isinstance(value, (list, tuple)) or not value:
        return None
    for member in value:
        if type(member) is not str or not member.strip():
            return None
    return tuple(value)


def _contained(required: Any, verified: Any) -> bool:
    """Containment, not interpretation.

    Every required dimension must be one the operator verified, at the value
    the operator verified. Ordering a memory size here would be the
    interpretation the accepted vocabulary rules out.
    """
    if not isinstance(required, Mapping) or not isinstance(verified, Mapping):
        return False
    for name, value in required.items():
        if name not in verified or verified[name] != value:
            return False
    return True


def _request(value: Any) -> dict[str, Any] | None:
    """The request classification, in exactly the fields a class is made of.

    Exact field set, exact types, nothing inferred. An unknown field is
    refused rather than ignored: a request carrying something nobody reviewed
    is not a narrower request, it is an unreviewed one.
    """
    if not isinstance(value, Mapping) or set(value) != set(REQUEST_FIELDS):
        return None
    capability_id = _identity(value["capability_id"], "capability-definition")
    contract_id = _identity(value["contract_id"], "capability-contract")
    versions = _members(value["accepted_contract_versions"])
    classification = value["data_classification"]
    if capability_id is None or contract_id is None or versions is None:
        return None
    if classification not in WORKLOAD_DATA_CLASSIFICATIONS:
        return None
    return {"capability_id": capability_id, "contract_id": contract_id,
            "accepted": frozenset(versions), "data_classification": classification}


def _continues(kind: str, record: Mapping[str, Any]) -> bool:
    """Whether this successor is another version of the same thing.

    A machine chain is one machine re-declared, so every host successor
    continues it. A binding chain is not: reading across a declared
    supersession would answer about a different binding than the one asked
    about, and during a declared overlap the superseded binding is still
    serving — so the answer would be wrong exactly when it matters.
    """
    if kind != "capability-instance":
        return True
    evidence = record.get("evidence")
    category = (evidence.get("reason_category")
                if isinstance(evidence, Mapping) else None)
    return category in LIFECYCLE_CATEGORIES


def _chain_head(store, kind: str, identifier: str):
    """The unsuperseded record ending this chain, or a named defect.

    Immutability means nothing points forward, so the chain is read from what
    points back. A binding a caller names may have been continued by a
    lifecycle decision, and a machine may have been withdrawn by a superseding
    declaration; reading the record that was named rather than the record that
    is current would answer with history.

    **A chain that cannot be read is not a chain that was read.** A payload
    that is not the kind it was filed as, an identity nothing could have
    allocated, a successor whose declared predecessor is absent, two records
    claiming one predecessor, and a cycle are each refused. None is repaired,
    skipped, or guessed at: a record at the end of a broken chain is evidence
    that something is missing, not evidence that it is current, and choosing a
    winner nobody chose would be a repair.
    """
    try:
        records = list(store.list_records(kind))
    except Exception:  # noqa: BLE001
        return None, REASON_STORE_UNREADABLE

    field = ID_FIELDS[kind]
    filed: list[tuple[str, Mapping[str, Any]]] = []
    present: set[str] = set()
    for record in records:
        if not isinstance(record, Mapping) or record.get("kind") != kind:
            return None, _CHAIN_DEFECT[kind]
        identity = _identity(record.get(field), kind)
        if identity is None:
            return None, _CHAIN_DEFECT[kind]
        filed.append((identity, record))
        present.add(identity)

    claimed: set[str] = set()
    links: dict[str, str] = {}
    for identity, record in filed:
        prior = record.get("supersedes")
        if not isinstance(prior, str):
            continue
        if prior not in present or prior in claimed:
            return None, _CHAIN_DEFECT[kind]
        claimed.add(prior)
        # Claimed either way: a second claimant is a fork whatever it declares
        # itself to be. Only a continuation extends the chain being walked.
        if _continues(kind, record):
            links[prior] = identity

    if identifier not in present:
        return None, _ABSENT[kind]

    walked = {identifier}
    current = identifier
    while current in links:
        current = links[current]
        if current in walked:
            return None, _CHAIN_DEFECT[kind]
        walked.add(current)

    try:
        stored = store.read_record(kind, current)
    except Exception:  # noqa: BLE001
        return None, REASON_STORE_UNREADABLE
    if (not isinstance(stored, Mapping) or stored.get("kind") != kind
            or stored.get(field) != current):
        return None, _CHAIN_DEFECT[kind]
    return stored, None


def _referenced(store, kind: str, identifier: Any, absent: str):
    """A record a binding names, read once, or the reason it is not there.

    Packages, contracts, and advertisements are read as named. A supersession
    of one of those declares a *different* binding, so following it here would
    answer about something this binding was never bound to.
    """
    if _identity(identifier, kind) is None:
        return None, absent
    try:
        stored = store.read_record(kind, identifier)
    except Exception:  # noqa: BLE001
        return None, absent
    if not isinstance(stored, Mapping):
        return None, absent
    return stored, None


def _standing(trust_store, record_id: Any, domain: str, instant: datetime):
    """What C3 says about one subject, in one domain, at this instant.

    Asked through the adapter and nowhere else, once per domain, every time.
    Nothing is remembered between evaluations: a cached verdict is how an
    unavailable Trust Plane becomes a trusted one.
    """
    try:
        return verify_trust_record(trust_store, record_id, evaluated_at=instant,
                                   expected_subject_type=domain), None
    except Exception:  # noqa: BLE001
        return None, REASON_UNREADABLE


def _trusted(verification, defect: str | None, subject: Any,
             mismatch: str) -> ConditionResult | None:
    """The shared shape of ELIG-1 and ELIG-2: usable standing, right subject."""
    if verification is None:
        return ConditionResult("", UNMET, defect)
    if not verification.verified:
        reason = verification.reasons[0] if verification.reasons else REASON_NOT_USABLE
        return ConditionResult("", UNMET, reason)
    if subject is None:
        return None
    if verification.subject_id != subject:
        return ConditionResult("", UNMET, mismatch)
    return None


def _quarantined(verification, defect: str | None, reason: str) -> ConditionResult:
    """Quarantine, in its own right, separate from every other standing."""
    if verification is None:
        return ConditionResult("", INDETERMINATE, defect)
    if verification.standing == TrustState.QUARANTINED.value:
        return ConditionResult("", UNMET, reason)
    return ConditionResult("", MET, None)


def _named(condition_id: str, outcome: ConditionResult | None) -> ConditionResult:
    """The outcome under its schema identity, or a met condition."""
    if outcome is None:
        return ConditionResult(condition_id, MET, None)
    return ConditionResult(condition_id, outcome.status, outcome.reason)


def evaluate_eligibility(store, trust_store, *, instance_id: Any, request: Any,
                         evaluated_at: Any) -> EligibilityVerdict:
    """Whether one binding is eligible for one request at one instant.

    Reads records, asks C3 once per trust domain, and returns. It writes
    nothing, allocates nothing, and remembers nothing, and it never raises:
    every defect is an ineligible verdict naming its reason.
    """
    identifier = _identity(instance_id, "capability-instance")
    if identifier is None:
        return _ungrounded(None, None, REASON_MALFORMED_IDENTITY)

    instant = _instant(evaluated_at) if isinstance(evaluated_at, datetime) else None
    if instant is None:
        return _ungrounded(identifier, None, REASON_NAIVE_INSTANT)
    stamp = instant.isoformat()

    asked = _request(request)
    if asked is None:
        return _ungrounded(identifier, stamp, REASON_MALFORMED_REQUEST)

    instance, defect = _chain_head(store, "capability-instance", identifier)
    if instance is None:
        return _ungrounded(identifier, stamp, defect)

    host_id = _identity(instance.get("capability_host_id"), "capability-host")
    if host_id is None:
        host, host_defect = None, REASON_HOST_UNRESOLVED
    else:
        host, host_defect = _chain_head(store, "capability-host", host_id)
    package, package_defect = _referenced(
        store, "capability-package", instance.get("capability_package_id"),
        REASON_PACKAGE_UNRESOLVED)
    contract, contract_defect = _referenced(
        store, "capability-contract", instance.get("contract_id"),
        REASON_CONTRACT_UNRESOLVED)

    package_trust, package_trust_defect = _standing(
        trust_store, instance.get("package_trust_record_id"),
        PACKAGE_TRUST_DOMAIN, instant)
    host_trust, host_trust_defect = _standing(
        trust_store, instance.get("host_trust_record_id"),
        HOST_TRUST_DOMAIN, instant)

    conditions = (
        _named("ELIG-1", _trusted(package_trust, package_trust_defect,
                                  instance.get("capability_package_id"),
                                  REASON_PACKAGE_SUBJECT)),
        _named("ELIG-2", _host_trust(host_trust, host_trust_defect,
                                     host, host_defect)),
        _named("ELIG-3", _contract_offers(contract, contract_defect, instance, asked)),
        _named("ELIG-4", _package_satisfies(package, package_defect, asked)),
        _named("ELIG-5", _resources(host, host_defect, package, package_defect)),
        _named("ELIG-6", _advertised(store, instance, instant)),
        _named("ELIG-7", _admitted(instance, instant)),
        _named("ELIG-8", _scope_permits(instance, asked)),
        _named("ELIG-9", _host_handles(instance, host, host_defect)),
        _named("ELIG-10", _quarantined(host_trust, host_trust_defect,
                                       REASON_HOST_QUARANTINED)),
        _named("ELIG-11", _quarantined(package_trust, package_trust_defect,
                                       REASON_PACKAGE_QUARANTINED)),
        _named("ELIG-12", _in_service(host, host_defect)),
    )

    # Authoritative lifecycle, which is decided rather than derived. A binding
    # an operator ended is ineligible however well every condition reads: the
    # decision is the answer, and the conditions are reported beside it so the
    # operator can see what ending it actually cost.
    disqualifications = ()
    if instance.get("lifecycle_state") != ADMITTED:
        disqualifications = (REASON_NOT_ADMITTED,)

    return _verdict(identifier, stamp, conditions, disqualifications)


def _host_trust(verification, defect: str | None, host, host_defect: str | None):
    """ELIG-2. The machine's standing, against the identity it was decided under."""
    if host is None:
        return ConditionResult("", INDETERMINATE, host_defect)
    return _trusted(verification, defect, host.get("node_identity_reference"),
                    REASON_HOST_SUBJECT)


def _contract_offers(contract, defect: str | None, instance, asked):
    """ELIG-3. Declared compatibility only, intersected with what was accepted.

    Compatibility is declared and never inferred. No meaning is read from a
    version number, because semantic-versioning arithmetic is a convention
    followed imperfectly and treating it as a guarantee lets a string
    comparison make an upgrade decision.
    """
    if contract is None:
        return ConditionResult("", INDETERMINATE, defect)
    if (instance.get("contract_id") != asked["contract_id"]
            or instance.get("capability_id") != asked["capability_id"]):
        return ConditionResult("", UNMET, REASON_CONTRACT_NOT_REQUESTED)
    offered = set()
    version = contract.get("contract_version")
    if isinstance(version, str) and version.strip():
        offered.add(version)
    declared = contract.get("compatible_with")
    if isinstance(declared, (list, tuple)):
        offered.update(entry for entry in declared if isinstance(entry, str))
    if not offered & asked["accepted"]:
        return ConditionResult("", UNMET, REASON_CONTRACT_VERSIONS)
    return None


def _package_satisfies(package, defect: str | None, asked):
    """ELIG-4. Exact intersection. Empty refuses, and never substitutes."""
    if package is None:
        return ConditionResult("", INDETERMINATE, defect)
    satisfied = package.get("satisfied_contract_versions")
    members = set(satisfied) if isinstance(satisfied, (list, tuple)) else set()
    if not members & asked["accepted"]:
        return ConditionResult("", UNMET, REASON_PACKAGE_VERSIONS)
    return None


def _resources(host, host_defect: str | None, package, package_defect: str | None):
    """ELIG-5. What the operator verified must cover what the package requires."""
    if host is None:
        return ConditionResult("", INDETERMINATE, host_defect)
    if package is None:
        return ConditionResult("", INDETERMINATE, package_defect)
    if not _contained(package.get("resource_requirements"),
                      host.get("verified_resource_profile")):
        return ConditionResult("", UNMET, REASON_RESOURCES)
    return None


def _advertised(store, instance, instant: datetime):
    """ELIG-6. A claim that exists, is registered, and is inside its window.

    A lapsed claim is stale, not absent, and the two are reported differently:
    one machine never said anything, the other said it too long ago.
    """
    advertisement_id = instance.get("advertisement_id")
    if not isinstance(advertisement_id, str) or not advertisement_id.strip():
        return ConditionResult("", UNMET, REASON_ADVERT_ABSENT)
    advertisement, defect = _referenced(store, "capability-advertisement",
                                        advertisement_id, REASON_ADVERT_UNRESOLVED)
    if advertisement is None:
        return ConditionResult("", UNMET, defect)
    observed = _instant(advertisement.get("observed_at"))
    expires = _instant(advertisement.get("valid_until"))
    if observed is None or expires is None:
        return ConditionResult("", UNMET, REASON_ADVERT_UNRESOLVED)
    if not observed <= instant < expires:
        return ConditionResult("", UNMET, REASON_ADVERT_STALE)
    return None


def _admitted(instance, instant: datetime):
    """ELIG-7. A human decided this, and the decision has not lapsed.

    Trust alone never admits. An absent admission is named as the absent
    admission rather than reported as weak trust, and an expired one asserts
    nothing at all about trust — that standing is whatever C3 reports.
    """
    decision = instance.get("admission_decision_id")
    if not isinstance(decision, str) or not decision.strip():
        return ConditionResult("", UNMET, REASON_ADMISSION_ABSENT)
    evidence = instance.get("evidence")
    authority = evidence.get("approving_authority") if isinstance(evidence, Mapping) else None
    if not isinstance(authority, str) or not authority.strip():
        return ConditionResult("", UNMET, REASON_ADMISSION_UNAPPROVED)
    opened = _instant(instance.get("admitted_at"))
    expires = _instant(instance.get("admitted_until"))
    if opened is None or expires is None or instant < opened:
        return ConditionResult("", UNMET, REASON_ADMISSION_NOT_OPEN)
    if instant >= expires:
        return ConditionResult("", UNMET, REASON_ADMISSION_EXPIRED)
    return None


def _scope_permits(instance, asked):
    """ELIG-8. A non-empty intersection that actually permits this request.

    An empty intersection is a valid outcome and it means nothing is eligible,
    so it is reported as the empty intersection rather than as a generic
    refusal. A dimension a record leaves out bounds nothing and permits
    nothing: absence is not permission.
    """
    scope = instance.get("effective_scope")
    if not isinstance(scope, Mapping):
        return ConditionResult("", UNMET, REASON_EMPTY_SCOPE)
    for dimension in SCOPE_DIMENSIONS:
        if _members(scope.get(dimension)) is None:
            return ConditionResult("", UNMET, REASON_EMPTY_SCOPE)
    if asked["data_classification"] not in scope[SCOPE_CLASSIFICATIONS]:
        return ConditionResult("", UNMET, REASON_SCOPE_REFUSES)
    return None


def _host_handles(instance, host, host_defect: str | None):
    """ELIG-9. Membership, not rank.

    Every classification the intersection permits must be exactly the one the
    machine is declared to handle. No accepted source declares an ordering of
    classifications, so none is inferred and nothing here is "higher".
    """
    if host is None:
        return ConditionResult("", INDETERMINATE, host_defect)
    scope = instance.get("effective_scope")
    permitted = _members(scope.get(SCOPE_CLASSIFICATIONS)) if isinstance(scope, Mapping) else None
    if permitted is None:
        return ConditionResult("", INDETERMINATE, REASON_EMPTY_SCOPE)
    declared = host.get("data_classification")
    for classification in permitted:
        if classification != declared:
            return ConditionResult("", UNMET, REASON_CLASSIFICATION)
    return None


def _in_service(host, host_defect: str | None):
    """ELIG-12. An operator withdrawing a working machine, said plainly."""
    if host is None:
        return ConditionResult("", INDETERMINATE, host_defect)
    if host.get("availability_intent") != IN_SERVICE:
        return ConditionResult("", UNMET, REASON_DRAINED)
    return None
