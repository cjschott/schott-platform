"""Deterministic selection over a declared route, and the record of it.

This is C6. It answers two questions and writes both down: which admitted
binding serves this request, and why not each of the others. A record naming
only the winner documents the outcome while hiding the decision, so every
candidate the route declared is recorded, and every exclusion carries its
reason.

**The rule is the whole rule.** The first eligible candidate in the order a
human wrote wins. Nothing here consults load, latency, success rate, or any
other measurement; nothing reorders; nothing weights. There is no tie-break,
because declared order is already total — two candidates alike in every other
respect are separated by which one the operator wrote first, which is the
answer the operator can predict during an incident.

**Eligibility is C5's.** No condition it owns is re-derived here. What C6 owns
is the route: whether a candidate is one (ELIG-13), whether the contract's
effect class may be routed at all (ELIG-14), and the locality the route
declares. `local-only` is answered from an operator-supplied node identity,
never from a location class -- several machines are legitimately on-premises,
so a location class is not an identity.

**It selects; it never runs anything.** Nothing is executed, scheduled, sited,
retried elsewhere, or put right. The result is a Fabric identity or a recorded
refusal, and `capability-selection` is the only record it writes.

Governed like every other accepted operation: the critical section is entered
once, before replay is classified, and held through allocation and the write.
The evaluation context participates in the request digest, so the same request
decided on a different node is a different governed operation rather than a
replay of the first.

See docs/decisions/ADR-0012-distributed-capability-fabric.md "How routing
occurs" and the accepted `capability-selection` and `capability-route` schemas.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from .eligibility import evaluate_eligibility
from .errors import FabricError
from .evidence import assemble_evidence
from .identifiers import PATTERNS
from .models import RECORD_MODELS, WORKLOAD_DATA_CLASSIFICATIONS
from .request_identity import (
    REPLAY_CONFLICT, REPLAY_EXACT, prepare_and_compute_request_digest,
    replay_lookup, validate_request_id,
)

OPERATION = "select-candidate"

# What one governed operation did, in the released vocabulary. Declared here
# rather than imported: C6 is not downstream of the admission controller, and
# a shared spelling is not a shared dependency.
ACCEPTED = "accepted"
EXACT_REPLAY = "exact-replay"
REFUSED = "refused"
INVALID = "invalid"
CONFLICT = "conflict"

# The three outcomes a recorded decision may be, named as §11 names them. The
# reason category the evidence carries is what makes each readable back.
OUTCOME_SELECTED = "selected"
OUTCOME_REFUSED = "refused"
OUTCOME_NO_CANDIDATE = "no-candidate"
OUTCOME_CATEGORIES = {
    OUTCOME_SELECTED: "selection",
    OUTCOME_REFUSED: "selection-refusal",
    OUTCOME_NO_CANDIDATE: "no-candidate",
}

# The two enumerated conditions the accepted schema assigns to this component.
# Locality is the route's own declared policy rather than one of the twelve, so
# it is named for what it is instead of borrowed into that numbering.
CONDITION_ROUTE = "ELIG-13"
CONDITION_EFFECT_CLASS = "ELIG-14"
CONDITION_LOCALITY = "route-locality"

# Which effect classes a route may select. The contract is the authority on
# which classes exist; this is the set that may be routed, and `side-effecting`
# is deliberately not in it. No route may lift the prohibition -- a restriction
# that can be lifted per-route is one that gets lifted during an incident.
ROUTABLE_EFFECT_CLASSES = ("read-only", "computational", "content-generating")

LOCALITIES = ("local-only", "operator-controlled-only", "any-trusted")
THIRD_PARTY_HOSTED = "third-party-hosted"

# Controlled vocabulary, deterministic by construction: nothing here is derived
# from an exception, a path, or a rejected value.
REASON_NO_ROUTE = "no-route-for-request-class"
REASON_ROUTE_AMBIGUOUS = "route-ambiguous-for-request-class"
REASON_ROUTE_UNREADABLE = "route-chain-unreadable"
REASON_NONE_ELIGIBLE = "no-eligible-candidate"
REASON_NOT_IN_ROUTE = "candidate-not-permitted-by-route"
REASON_NOT_ROUTABLE = "contract-effect-class-not-routable"
REASON_LOCALITY = "candidate-not-permitted-by-locality"
REASON_HEALTH_REMOVED = "candidate-removed-by-health-input"
# Eligible, and not first. Recorded because a record naming only the winner
# documents the outcome while hiding the decision -- an operator asking why
# the second candidate did not serve gets an answer rather than a silence.
REASON_NOT_FIRST = "not-first-eligible-in-declared-order"
REASON_CONTRACT_UNRESOLVED = "contract-not-resolvable"
REASON_HOST_UNRESOLVED = "host-not-resolvable"
REASON_CONTENT = "malformed-operation-content"
REASON_UNKNOWN_LOCALITY = "unknown-locality"
REASON_UNKNOWN_CLASSIFICATION = "unknown-data-classification"

SELECTED_REASON = "first eligible candidate in declared order"
REFUSED_REASON = "no candidate in declared order was eligible"
NO_ROUTE_REASON = "no route resolved for the request class"


@dataclass(frozen=True)
class SelectionResult:
    """What one governed selection did. Immutable, and never persisted."""

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
    """A controlled refusal, carrying its outcome and its reason."""

    def __init__(self, outcome: str, reason: str) -> None:
        super().__init__(reason)
        self.outcome = outcome
        self.reason = reason


def _refuse(outcome: str, reason: str) -> None:
    raise _Refusal(outcome, reason)


def _text(value: Any, reason: str = REASON_CONTENT) -> str:
    if not isinstance(value, str) or not value.strip():
        _refuse(INVALID, reason)
    return value


def _identifier(value: Any, kind: str) -> str:
    if not isinstance(value, str) or not PATTERNS[kind].fullmatch(value):
        _refuse(INVALID, REASON_CONTENT)
    return value


def _aware(value: Any) -> datetime:
    if not isinstance(value, datetime):
        _refuse(INVALID, REASON_CONTENT)
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        _refuse(INVALID, REASON_CONTENT)
    return value


def _mapping(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        _refuse(INVALID, REASON_CONTENT)
    return value


def _exact_strings(value: Any) -> tuple[str, ...]:
    """A sequence of exact, non-repeating text, in the order supplied."""
    if isinstance(value, str) or not isinstance(value, (list, tuple)):
        _refuse(INVALID, REASON_CONTENT)
    seen: list[str] = []
    for member in value:
        if type(member) is not str or not member.strip() or member in seen:
            _refuse(INVALID, REASON_CONTENT)
        seen.append(member)
    return tuple(seen)


def _usable_node_identity(value: Any) -> str | None:
    """The node performing the selection, or nothing at all.

    Absent and unusable are the same answer here: neither identifies a machine,
    and a `local-only` route cannot be satisfied by either. Nothing is trimmed
    or repaired -- an identity that had to be corrected to match is not the
    identity that was supplied.
    """
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        return None
    return value


def _chain_heads(store, kind: str):
    """Every record of a kind that nothing supersedes, by identity.

    Read from what points back, because immutability means nothing points
    forward. A chain that forks, loops, or names an absent predecessor is
    reported rather than resolved: choosing a winner nobody chose would be a
    repair, and this component repairs nothing.
    """
    try:
        records = list(store.list_records(kind))
    except Exception:  # noqa: BLE001
        _refuse(REFUSED, REASON_ROUTE_UNREADABLE)

    field = {"capability-route": "route_id",
             "capability-host": "capability_host_id"}[kind]
    present: dict[str, Mapping[str, Any]] = {}
    for record in records:
        if not isinstance(record, Mapping) or record.get("kind") != kind:
            _refuse(REFUSED, REASON_ROUTE_UNREADABLE)
        identity = record.get(field)
        if not isinstance(identity, str) or not PATTERNS[kind].fullmatch(identity):
            _refuse(REFUSED, REASON_ROUTE_UNREADABLE)
        present[identity] = record

    superseded: set[str] = set()
    for record in present.values():
        prior = record.get("supersedes")
        if not isinstance(prior, str):
            continue
        if prior not in present or prior in superseded:
            _refuse(REFUSED, REASON_ROUTE_UNREADABLE)
        superseded.add(prior)
    return {identity: record for identity, record in present.items()
            if identity not in superseded}


def _resolve_route(store, asked):
    """The one current route declaring this request class, or nothing.

    A route binds a request class, so the class is matched exactly: the same
    capability, the same contract, the same accepted version set, the same
    classification, and the same locality. Nothing is widened, and no route is
    preferred over another -- two current routes for one class is a policy
    question nobody answered, and answering it here would be the selection
    deriving its own authority.
    """
    matching = [record for record in _chain_heads(store, "capability-route").values()
                if record.get("capability_id") == asked["capability_id"]
                and record.get("contract_id") == asked["contract_id"]
                and record.get("data_classification") == asked["data_classification"]
                and record.get("locality") == asked["locality"]
                and tuple(record.get("accepted_contract_versions") or ())
                == asked["accepted_contract_versions"]]
    if not matching:
        return None
    if len(matching) > 1:
        _refuse(REFUSED, REASON_ROUTE_AMBIGUOUS)
    return matching[0]


def _referenced(store, kind: str, identifier: Any):
    """A record the decision names, read once, or nothing."""
    if not isinstance(identifier, str) or not PATTERNS[kind].fullmatch(identifier):
        return None
    try:
        stored = store.read_record(kind, identifier)
    except Exception:  # noqa: BLE001
        return None
    return stored if isinstance(stored, Mapping) else None


def _host_of(store, instance, heads):
    """The machine as it stands now, not as the binding first named it.

    A declaration is superseded rather than edited, so the record the binding
    cites may describe a machine that has since been re-declared somewhere
    else. Locality is a question about the machine now.
    """
    named = instance.get("capability_host_id")
    if not isinstance(named, str):
        return None
    for identity, record in heads.items():
        if identity == named:
            return record
    # Named record superseded: walk forward to the declaration that stands.
    current = named
    seen = {current}
    while True:
        successor = next((identity for identity, record in heads.items()
                          if record.get("supersedes") == current), None)
        if successor is not None:
            return heads[successor]
        moved = _referenced(store, "capability-host", current)
        if moved is None:
            return None
        following = moved.get("superseded_by")
        if not isinstance(following, str) or following in seen:
            return None
        seen.add(following)
        current = following


def _locality_permits(locality: str, host, local_node_identity: str | None) -> bool:
    """Whether the route's declared locality admits this machine.

    `local-only` is exact identity equality against the node performing the
    selection. Nothing is inferred from a location class, a hostname, an
    endpoint, or a resemblance between strings, and where no usable identity
    was supplied the answer is no -- refusing rather than quietly evaluating
    the request as though it had asked for somewhere else.
    """
    if locality == "any-trusted":
        return True
    if locality == "operator-controlled-only":
        return host.get("location_class") != THIRD_PARTY_HOSTED
    if local_node_identity is None:
        return False
    return host.get("node_identity_reference") == local_node_identity


def _exclusions(store, trust_store, candidate, *, instance, host_heads, contract,
                asked, instant, local_node_identity, removals) -> tuple[str, ...]:
    """Every reason this candidate cannot serve the request, in a fixed order.

    All of them, not the first: an operator holding one reason during an
    incident will clear it and find the next. Eligibility comes from C5
    unchanged -- its verdict is what gets recorded.
    """
    reasons: list[str] = []
    if instance is None:
        reasons.append(REASON_NOT_IN_ROUTE)
        return tuple(reasons)

    verdict = evaluate_eligibility(store, trust_store, instance_id=candidate,
                                   request={
                                       "capability_id": asked["capability_id"],
                                       "contract_id": asked["contract_id"],
                                       "accepted_contract_versions":
                                           asked["accepted_contract_versions"],
                                       "data_classification":
                                           asked["data_classification"]},
                                   evaluated_at=instant)
    reasons.extend(verdict.reasons)

    if contract is None:
        reasons.append(REASON_CONTRACT_UNRESOLVED)
    elif contract.get("effect_class") not in ROUTABLE_EFFECT_CLASSES:
        reasons.append(REASON_NOT_ROUTABLE)

    host = _host_of(store, instance, host_heads)
    if host is None:
        reasons.append(REASON_HOST_UNRESOLVED)
    elif not _locality_permits(asked["locality"], host, local_node_identity):
        reasons.append(REASON_LOCALITY)

    if candidate in removals:
        reasons.append(REASON_HEALTH_REMOVED)
    return tuple(reasons)


def _commit(store, kind, evidence, build) -> str:
    """Prove the record is constructible, then allocate through C1 and write.

    Allocation advances a persistent sequence, so nothing is allocated until
    the exact content is known to be constructible. The proof is a
    construction against a probe identity of this width, which allocates
    nothing and leaves nothing behind.
    """
    _constructed("CSEL-000000", evidence, build)
    identifier = store.allocate_id(kind)
    record = _constructed(identifier, evidence, build)
    store.write(kind, record)
    return identifier


def _constructed(identifier: str, evidence, build):
    """The complete record, or a controlled refusal naming malformed content.

    A raw exception would carry the rejected value, its type, a path, or an
    address out of the governed boundary.
    """
    try:
        record = build(identifier, evidence)
        record.to_dict()
    except Exception:  # noqa: BLE001
        _refuse(INVALID, REASON_CONTENT)
    return record


def select_candidate(store, trust_store, *, request_id: Any, actor: Any,
                     recorded_at: Any, evaluated_at: Any, capability_id: Any,
                     contract_id: Any, accepted_contract_versions: Any,
                     data_classification: Any, locality: Any, provenance: Any,
                     local_node_identity: Any = None, health_removals: Any = (),
                     notes: Any = None) -> SelectionResult:
    """Choose the first eligible candidate the route declares, and record it.

    Returns a Fabric identity or a recorded refusal. Both are written as a
    `capability-selection`, because "why did nothing run?" deserves the same
    quality of answer as "why did this run there?".
    """
    supplied = request_id if isinstance(request_id, str) else ""
    try:
        identifier = validate_request_id(request_id)
        _text(actor)
        _aware(recorded_at)
        instant = _aware(evaluated_at)
        _identifier(capability_id, "capability-definition")
        _identifier(contract_id, "capability-contract")
        versions = _exact_strings(accepted_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_CONTENT)
        if data_classification not in WORKLOAD_DATA_CLASSIFICATIONS:
            _refuse(REFUSED, REASON_UNKNOWN_CLASSIFICATION)
        if locality not in LOCALITIES:
            _refuse(REFUSED, REASON_UNKNOWN_LOCALITY)
        removals = _exact_strings(health_removals)
        for removed in removals:
            _identifier(removed, "capability-instance")
        _mapping(provenance)
        if notes is not None:
            _text(notes)
        # Supplied but unusable is not the same as not supplied: the first is
        # a malformed governed input and is refused as one.
        node_identity = _usable_node_identity(local_node_identity)
        if local_node_identity is not None and node_identity is None:
            _refuse(INVALID, REASON_CONTENT)
        digest = prepare_and_compute_request_digest(OPERATION, {
            "actor": actor,
            "recorded_at": recorded_at.isoformat(),
            "evaluated_at": instant.isoformat(),
            "capability_id": capability_id,
            "contract_id": contract_id,
            "accepted_contract_versions": list(versions),
            "data_classification": data_classification,
            "locality": locality,
            # An authoritative input like any other: the same request decided
            # on a different node is a different governed operation.
            "local_node_identity": local_node_identity,
            "health_removals": list(removals),
            "provenance": dict(provenance),
            "notes": notes,
        })
    except _Refusal as refusal:
        return SelectionResult(refusal.outcome, supplied, reason=refusal.reason)
    except Exception:  # noqa: BLE001
        return SelectionResult(INVALID, supplied, reason=REASON_CONTENT)

    asked = {"capability_id": capability_id, "contract_id": contract_id,
             "accepted_contract_versions": versions,
             "data_classification": data_classification, "locality": locality}

    with store.request_critical_section(identifier):
        replay = replay_lookup(store, identifier, digest)
        if replay.status == REPLAY_EXACT:
            return SelectionResult(EXACT_REPLAY, identifier, digest,
                                   replay.record_kind, replay.record_id)
        if replay.status == REPLAY_CONFLICT:
            return SelectionResult(CONFLICT, identifier, digest,
                                   reason="request_identity_conflict")
        try:
            record_id = _decide(store, trust_store, identifier, digest,
                                asked=asked, actor=actor, recorded_at=recorded_at,
                                instant=instant, provenance=provenance,
                                node_identity=node_identity, removals=removals,
                                notes=notes)
        except _Refusal as refusal:
            return SelectionResult(refusal.outcome, identifier, digest,
                                   reason=refusal.reason)
        return SelectionResult(ACCEPTED, identifier, digest,
                               "capability-selection", record_id)


def _decide(store, trust_store, identifier: str, digest: str, *, asked, actor,
            recorded_at, instant, provenance, node_identity, removals,
            notes) -> str:
    """Resolve the route, judge every candidate it declares, and record it."""
    route = _resolve_route(store, asked)

    if route is None:
        # No route to name, and none is invented. The decision is still
        # written: silence is not an outcome.
        return _write(store, OUTCOME_NO_CANDIDATE, route=None, considered=(),
                      excluded=(), selected=None, refusal=REASON_NO_ROUTE,
                      reason=NO_ROUTE_REASON, asked=asked, actor=actor,
                      recorded_at=recorded_at, provenance=provenance,
                      node_identity=None, notes=notes, identifier=identifier,
                      digest=digest)

    contract = _referenced(store, "capability-contract", asked["contract_id"])
    host_heads = _chain_heads(store, "capability-host")
    considered = tuple(route.get("candidate_instances") or ())

    selected = None
    excluded: list[dict[str, Any]] = []
    for candidate in considered:
        instance = _referenced(store, "capability-instance", candidate)
        reasons = _exclusions(store, trust_store, candidate, instance=instance,
                              host_heads=host_heads, contract=contract,
                              asked=asked, instant=instant,
                              local_node_identity=node_identity,
                              removals=removals)
        if reasons:
            excluded.append({"instance_id": candidate, "reasons": list(reasons)})
        elif selected is None:
            # First in declared order wins. Later candidates are still judged,
            # so the record explains the whole field rather than stopping at
            # the answer.
            selected = candidate
        else:
            excluded.append({"instance_id": candidate,
                             "reasons": [REASON_NOT_FIRST]})

    outcome = OUTCOME_SELECTED if selected is not None else OUTCOME_REFUSED
    return _write(store, outcome, route=route, considered=considered,
                  excluded=tuple(excluded), selected=selected,
                  refusal=None if selected is not None else REASON_NONE_ELIGIBLE,
                  reason=SELECTED_REASON if selected is not None else REFUSED_REASON,
                  asked=asked, actor=actor, recorded_at=recorded_at,
                  provenance=provenance,
                  node_identity=node_identity if asked["locality"] == "local-only"
                  else None,
                  notes=notes, identifier=identifier, digest=digest)


def _write(store, outcome: str, *, route, considered, excluded, selected,
           refusal, reason, asked, actor, recorded_at, provenance,
           node_identity, notes, identifier, digest) -> str:
    """Assemble the evidence, then let C1 allocate and commit the record."""
    references = list(considered)
    if route is not None:
        references.insert(0, route["route_id"])
    try:
        evidence = assemble_evidence(
            "capability-selection", actor=actor, approving_authority=None,
            reason_category=OUTCOME_CATEGORIES[outcome], recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            causal_references=tuple(references), trust_evidence_references=())
    except FabricError:
        _refuse(INVALID, REASON_CONTENT)

    model = RECORD_MODELS["capability-selection"]
    return _commit(store, "capability-selection",
                   evidence, lambda allocated, carried: model(
        selection_id=allocated,
        route_id=None if route is None else route["route_id"],
        route_version=None if route is None else route.get("route_version"),
        request_class=dict(asked, accepted_contract_versions=list(
            asked["accepted_contract_versions"])),
        considered_candidates=tuple(considered),
        excluded_candidates=tuple(excluded),
        selected_instance_id=selected, selection_reason=reason,
        selected_at=recorded_at, provenance=dict(provenance),
        refusal_reason=refusal, local_node_identity=node_identity,
        notes=notes, evidence=carried))
