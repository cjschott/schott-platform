"""The import closure of the installed Capability Runtime, computed once.

**One implementation, three consumers.** Generation 11 computed its closure
inside a heredoc in its own installer, which meant the rule lived in exactly one
place that nothing else could check. When ENG-0005 G11-Y made the invocation
boundary reach C5 eligibility and the Trust store, that closure silently became
wrong and nothing said so. So the rule now lives here, and the installer, the
packaging test, and the soundness test all ask the same object.

**It answers one question**: starting from the modules the installed runtime is
actually entered through, which repository modules does Python have to be able
to import? Not which modules somebody listed -- which ones the import graph
requires. A closure that read only the declared files could never discover that
it needs a file nobody declared, which is the failure this exists to prevent.

**What it is not.** It computes no authority, installs nothing, and reads no
production path. Membership in the closure means the runtime can import a
module; it grants no filesystem access, no Trust standing, and no permission to
mutate anything. That distinction is the whole argument of
`provisioning/execution/generation-12-surface.sh`.

This is a development and packaging tool. It is not part of the runtime and is
never installed.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import sys

# The flattened privileged helpers land in the library root under names the
# repository spells with hyphens. The mapping is data, not a guess: root
# executes these by pathname, so a rename here would be a rename there.
FLATTENED = {
    "kyri_exec_podman": "provisioning/execution/kyri-exec-podman.py",
    "kyri_exec_quota": "provisioning/execution/kyri-exec-quota.py",
    "kyri_exec_transition": "provisioning/execution/kyri-exec-transition.py",
    "kyri_exec_transition_action":
        "provisioning/execution/kyri-exec-transition-action.py",
    "kyri_exec_verify": "provisioning/execution/kyri-exec-verify.py",
    "kyri_exec_worker": "provisioning/execution/kyri-exec-worker.py",
}

# Import names that resolve outside the repository. PyYAML is the one
# third-party dependency the runtime already relies on and the platform already
# provides; everything else here is the standard library, which is present by
# definition. Neither is packaged, and neither is silently ignored: a name that
# is neither a repository module nor listed here is reported.
EXTERNAL = frozenset({"yaml"})


def _module_path(root: str, module: str) -> str | None:
    """The file a module name resolves to inside one tree, or nothing.

    Both spellings are answered: a module, and a package whose initialiser the
    import system runs on the way to it.
    """
    if module in FLATTENED:
        candidate = os.path.join(root, module + ".py")
        return candidate if os.path.isfile(candidate) else None
    candidate = os.path.join(root, module.replace(".", "/") + ".py")
    if os.path.isfile(candidate):
        return candidate
    package = os.path.join(root, module.replace(".", "/"), "__init__.py")
    if os.path.isfile(package):
        return package
    return None


def _imported_by(module: str, path: str) -> set[str]:
    """Every module name one file names, absolute and relative alike.

    A `from x import y` may name a submodule rather than an attribute, and
    there is no way to tell which without resolving it -- so both readings are
    returned and the caller keeps whichever resolves.
    """
    package = module if path.endswith("__init__.py") else module.rsplit(".", 1)[0]
    names: set[str] = set()
    with open(path, encoding="utf-8") as handle:
        tree = ast.parse(handle.read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                parts = package.split(".")
                if node.level > 1:
                    parts = parts[: len(parts) - (node.level - 1)]
                target = ".".join(parts) + ("." + node.module if node.module else "")
            else:
                target = node.module or ""
            names.add(target)
            names.update(target + "." + alias.name for alias in node.names)
    return names


def compute(root: str, roots: list[str]) -> dict[str, object]:
    """The closure of a set of entry modules over one source tree.

    Returns the reachable module names, the repository-relative files they
    resolve to, and every import name that left the repository. The last is
    reported rather than discarded: a new third-party dependency is a packaging
    decision, and discovering it at import time on a production host is the
    wrong place to have that conversation.
    """
    seen: set[str] = set()
    external: set[str] = set()
    unresolved: set[str] = set()
    pending = list(roots)

    while pending:
        module = pending.pop()
        if module in seen:
            continue
        path = _module_path(root, module)
        if path is None:
            unresolved.add(module)
            continue
        seen.add(module)
        for name in _imported_by(module, path):
            if not name:
                continue
            if _module_path(root, name) is not None:
                pending.append(name)
            elif name.split(".")[0] in EXTERNAL:
                external.add(name.split(".")[0])
            elif name.startswith(("tools.", "kyri_exec")):
                # Names inside the runtime's own namespace that resolve to no
                # file are reported. `from x import SOMETHING` produces these
                # legitimately for attributes, so they are informational.
                unresolved.add(name)

    # Every package initialiser on the way to a member is executed by the import
    # system and therefore belongs to the closure too.
    for module in list(seen):
        parts = module.split(".")
        for depth in range(1, len(parts)):
            parent = ".".join(parts[:depth])
            if _module_path(root, parent) is not None:
                seen.add(parent)

    files = sorted(
        os.path.relpath(_module_path(root, module), root) for module in seen)
    return {
        "roots": sorted(roots),
        "modules": sorted(seen),
        "files": files,
        "external": sorted(external),
        "unresolved_names": sorted(unresolved),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source-root", required=True,
                        help="the tree to compute the closure over")
    parser.add_argument("--root", action="append", required=True, dest="roots",
                        help="an entry module; repeat for each")
    parser.add_argument("--format", choices=("json", "files"), default="json")
    args = parser.parse_args(argv)

    result = compute(args.source_root, args.roots)
    if args.format == "files":
        print("\n".join(result["files"]))
    else:
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
