"""Collector plugin namespace.

Plugins are registered explicitly through tools.collectors.registry. There is
no dynamic filesystem scanning and no entry-point discovery: a plugin that can
appear by being dropped on disk is a plugin nobody reviewed.
"""
