"""Read pinned Hermes test subjects from an external checkout, only in memory.

No upstream source is stored or downloaded by this repository.
"""
import ast
import hashlib
import os
from pathlib import Path

SUBJECTS = {'approval.py': ('430d08bd6dd1a685d228f792377b946bcd97bcc710e74a40e86e8b9b8ac721fc', ['register_gateway_notify', 'unregister_gateway_notify', 'resolve_gateway_approval', 'list_gateway_approvals', 'register_gateway_settle', '_gateway_notify_cb', '_presence']), 'approval_context.py': ('91b086647fed3d5e23c2ef350d87f963530c0ec53d9373d5ef069dfbad022479', ['_get_session_platform', '_is_cron_approval_context', '_is_unattended_platform_approval_context', '_is_gateway_approval_context']), 'approval_gateway_wait.py': ('0ef46358d56b13395fbe2234db6b9a54323a45fba26a47ddf6741fe4964fb732', ['_ApprovalEntry', '_poll_event', '_finish', '_await_coalesced_leader', '_await_gateway_decision'])}


def external_source(filename):
    repository = Path(__file__).resolve().parents[2]
    checkout = Path(os.environ.get("CUATE_HERMES_TEST_SOURCE", "~/.hermes/hermes-agent")).expanduser().resolve()
    if checkout == repository or repository in checkout.parents:
        raise RuntimeError("CUATE_HERMES_TEST_SOURCE must be outside the Cuate repository")
    path = checkout / "tools" / filename
    if not path.is_file():
        raise RuntimeError("Set CUATE_HERMES_TEST_SOURCE to an external Hermes checkout at 1ab32b212b; missing " + str(path))
    raw = path.read_bytes()
    digest, names = SUBJECTS[filename]
    if hashlib.sha256(raw).hexdigest() != digest:
        raise RuntimeError("Hermes test source differs from pinned revision 1ab32b212b: " + str(path))
    source = raw.decode()
    definitions = {node.name: node for node in ast.parse(source).body
                   if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
    return "\n\n".join(ast.get_source_segment(source, definitions[name]) for name in names)
