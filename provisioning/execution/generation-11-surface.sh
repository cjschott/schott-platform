#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-11 installation surface: the Fabric dependency closure the
# installed Capability Runtime has always needed and never had.
#
# THIS IS A DECLARATION, NOT A CEREMONY. Sourcing it defines the matrix and
# nothing else; running it prints the matrix and exits. It installs nothing,
# opens no transaction, touches no authority namespace, and reads no production
# path. The transactional installer that consumes this -- journal, prepared
# copies, recovery, generation pinning -- is a separate object written against
# the reviewed commit, and installing is a separately authorised act.
#
# WHAT DEFECT THIS CLOSES. Generation 10 installs
# `tools/capability/fabric_evidence.py`, which does:
#
#     from ..fabric.inspection import (STATUS_REPORTED, inspect_records)
#
# `tools/fabric` was never installed, so that import -- and therefore
# `tools.capability.coordinator` and `tools.capability.cli`, which reach it --
# resolves only when /opt/schott-platform happens to be on `sys.path`. The
# installed runtime was not self-contained; it borrowed a checkout.
#
# WHAT IS INSTALLED, AND WHY EXACTLY THIS SET. The transitive closure of
# `tools.fabric.inspection`, computed from the source rather than assumed, is
# eight modules plus the package initialiser. It does NOT include
# `tools/fabric/admission.py`, `cli.py`, `selection.py`, `eligibility.py` or
# `trust_adapter.py`, and reaches nothing in `tools.trust`. The Capability
# Runtime consumes read-only inspection (C8) and the record models it reports
# with; it does not consume the governed write path, so the write path is not
# installed.
#
# `tools/common/immutable_store.py` is the only `tools.common` dependency in the
# closure and Generation 10 already installs it. Nothing outside the standard
# library and PyYAML is reached, and PyYAML is already present.
#
# IMPORTING IS NOT AUTHORITY. Installing these modules lets the runtime resolve
# an import. It grants no filesystem access, no Trust standing, no operator
# input, and no permission to mutate anything -- see the accompanying report.
# Every one of the nine files is a declaration-only module: no top-level
# statement in any of them does anything but define a constant, a class, or a
# function, so importing has no side effect at all.
#
# Every row is a CREATE. Generation 11 adds a package that is not there and
# replaces nothing, so no Generation-10 object is altered, and the installed
# object count rises from 48 to 57.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-26-g11-b-runtime-dependency-closure.md
#   docs/decisions/ADR-0012-distributed-capability-fabric.md

LIBRARY_ROOT="${LIBRARY_ROOT:-/usr/lib/kyri/python}"

# source | target | mode | operation | sha256
#
# Publication order is dependency order: the package initialiser, then the
# leaves, then the modules that import them. Nothing here is a REPLACE, so no
# window exists in which an installed caller sees a mixture -- an absent module
# stays absent until it is complete, and `fabric_evidence` cannot reach a
# half-installed package because it cannot reach the package at all until the
# initialiser lands.
GENERATION_11_MATRIX=(
"tools/fabric/__init__.py|${LIBRARY_ROOT}/tools/fabric/__init__.py|0444|CREATE|e761edea8dfe6df49080d58441f41b48558c335d82a309ca12e7cd271bdf6230"
"tools/fabric/errors.py|${LIBRARY_ROOT}/tools/fabric/errors.py|0444|CREATE|ddc6a7654ca5e38aa828070bd5400a7bc93bee48db231494e235ff8d9c1e954a"
"tools/fabric/identifiers.py|${LIBRARY_ROOT}/tools/fabric/identifiers.py|0444|CREATE|e523096cb23864d0970ccd038c8ad1532ca0a245b268a51838195c6328b63226"
"tools/fabric/models.py|${LIBRARY_ROOT}/tools/fabric/models.py|0444|CREATE|c6e0ce6d4b70a077072794ffd2cde548ea3b031c061e108eb37769dccd5d657b"
"tools/fabric/request_identity.py|${LIBRARY_ROOT}/tools/fabric/request_identity.py|0444|CREATE|b0ff8b1dde147d186b0675b55ecdc9999d603dede9e4f459b1cd3d8bccfc1267"
"tools/fabric/evidence.py|${LIBRARY_ROOT}/tools/fabric/evidence.py|0444|CREATE|48abf37c7a8c4bb4a16398aa2f4c32c98ecf8af72dfbb85df96f2f9dcf5e1be1"
"tools/fabric/store.py|${LIBRARY_ROOT}/tools/fabric/store.py|0444|CREATE|beda03b71cbdc5568afe0c54d682afbdce94b508b4d18beefa0c78704aa3a13a"
"tools/fabric/validator.py|${LIBRARY_ROOT}/tools/fabric/validator.py|0444|CREATE|dfdc02ffe0f6040751250216de7fad135e59b174c9084287e039eb0d02c1acda"
"tools/fabric/inspection.py|${LIBRARY_ROOT}/tools/fabric/inspection.py|0444|CREATE|a59d36b1900fcd3b25bdd649c3e4cb37c1de8fd2e9700234d4355833c250ca4a"
)

# The modules the closure deliberately excludes. Named, so a later reader can
# see that the omission was decided rather than overlooked, and so a test can
# assert none of them is ever added without that decision being revisited.
GENERATION_11_EXCLUDED=(
"tools/fabric/admission.py"
"tools/fabric/cli.py"
"tools/fabric/eligibility.py"
"tools/fabric/selection.py"
"tools/fabric/trust_adapter.py"
)

generation_11_field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf 'Generation-11 installation surface: %d CREATE object(s)\n\n' \
    "${#GENERATION_11_MATRIX[@]}"
  for row in "${GENERATION_11_MATRIX[@]}"; do
    printf '  %-8s %s\n' \
      "$(generation_11_field "${row}" 3)" "$(generation_11_field "${row}" 1)"
  done
  printf '\nDeliberately excluded (%d):\n' "${#GENERATION_11_EXCLUDED[@]}"
  for excluded in "${GENERATION_11_EXCLUDED[@]}"; do
    printf '  %s\n' "${excluded}"
  done
  printf '\nThis declaration installs nothing.\n'
fi
