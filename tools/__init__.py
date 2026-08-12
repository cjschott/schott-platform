"""Platform tooling root.

**This file carries no code, and adding some would be a mistake.** It exists so
that ``tools`` is a *regular* package rather than a namespace package, and that
distinction is a security property rather than a packaging preference.

A namespace portion does not terminate the import search. Python keeps scanning
``sys.path`` past it, so a *regular* package named ``tools`` found anywhere
later wins outright — even when the canonical runtime root was inserted at
position 0, which is exactly what the installed entrypoints do. Before this
file existed, a hostile ``PYTHONPATH`` could therefore land its own
``tools.capability.execution.worker`` ahead of the installed one, and its
module-level code ran before the entrypoints' post-import resolution check
could object. A check that fires after arbitrary code has executed is a report,
not a boundary.

With this file present the canonical root resolves as a regular package and
terminates the search where it is found, so the first match is the only match.
The pre-import existence check and the post-import ``realpath`` check both
remain: this closes the gap between them rather than replacing either.

Anything importable placed here would run inside that boundary on every
import, so this module stays empty by design.
"""
