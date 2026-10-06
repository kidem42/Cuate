"""Read pinned Hermes test subjects from an external checkout, only in memory.

No upstream source is stored or downloaded by this repository. The checkout must
be exactly one of the pinned revisions; every subject file is matched against the
same revision, so a half-updated tree is refused instead of mixed.
"""
import ast
import hashlib
import os
from pathlib import Path

# Required definitions are extracted on every revision; optional ones only where
# that revision defines them (0.21.5 split the wait's cancel cause out).
NAMES = {
    'tools/approval.py': (['register_gateway_notify', 'unregister_gateway_notify', 'resolve_gateway_approval',
                           'list_gateway_approvals', 'register_gateway_settle', '_gateway_notify_cb', '_presence'], []),
    'tools/approval_context.py': (['_get_session_platform', '_is_cron_approval_context',
                                   '_is_unattended_platform_approval_context', '_is_gateway_approval_context'], []),
    'tools/approval_gateway_wait.py': (['_ApprovalEntry', '_poll_event', '_finish', '_await_coalesced_leader',
                                        '_await_gateway_decision'], ['_cancel_cause']),
    'agent/terminal_approval_batch.py': (['approval_published', 'register_prepared_approval',
                                          'preparing_terminal_approval'], []),
}

# Revision -> {path: sha256}. A path a revision does not list does not exist there.
REVISIONS = {
    '0.21.3 (1ab32b212b)': {
        'tools/approval.py': '430d08bd6dd1a685d228f792377b946bcd97bcc710e74a40e86e8b9b8ac721fc',
        'tools/approval_context.py': '91b086647fed3d5e23c2ef350d87f963530c0ec53d9373d5ef069dfbad022479',
        'tools/approval_gateway_wait.py': '0ef46358d56b13395fbe2234db6b9a54323a45fba26a47ddf6741fe4964fb732',
    },
    '0.21.5 (v2026.9.24)': {
        'tools/approval.py': 'fb8dafe0ed0b18b9c782330724fe17f9ec8503de59cfa166b506c13c7bc685ac',
        'tools/approval_context.py': '2ffc3f6792670ac4dd4c560284db13908b52102454cb4359a8275d10c7679b11',
        'tools/approval_gateway_wait.py': '5b4233b2d0aff4ff70857e29a391978914937bf8ef294e4b1bfb4000997ed056',
        'agent/terminal_approval_batch.py': '8c7c5be7f6650946f98cdee2705959bcc567c77927d24dfa04fd2c6187c09e38',
    },
}


def _checkout():
    repository = Path(__file__).resolve().parents[2]
    checkout = Path(os.environ.get("CUATE_HERMES_TEST_SOURCE", "~/.hermes/hermes-agent")).expanduser().resolve()
    if checkout == repository or repository in checkout.parents:
        raise RuntimeError("CUATE_HERMES_TEST_SOURCE must be outside the Cuate repository")
    return checkout


def _digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def external_revision():
    """The pinned revision the checkout matches in full, or a RuntimeError."""
    checkout = _checkout()
    for revision, files in REVISIONS.items():
        if all(_digest(checkout / path) == digest for path, digest in files.items()):
            return revision
    raise RuntimeError("Set CUATE_HERMES_TEST_SOURCE to an external Hermes checkout at one of "
                       + ", ".join(REVISIONS) + "; " + str(checkout) + " matches none")


def external_source(path):
    """Selected definitions of one subject file, or None when the revision lacks the file."""
    if path not in REVISIONS[external_revision()]:
        return None
    source = (_checkout() / path).read_text()
    definitions = {node.name: node for node in ast.parse(source).body
                   if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
    required, optional = NAMES[path]
    names = required + [name for name in optional if name in definitions]
    return "\n\n".join(ast.get_source_segment(source, definitions[name]) for name in names)
