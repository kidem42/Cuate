"""Minimal credential-free installation for patch compatibility tests."""
from pathlib import Path

SERVER = '''usage = {"context_tokens": 1, "context_window": 10}
# continues detached
class APIServerAdapter:
    _run_approval_sessions = {}
    def _set_run_status(self): pass
    async def _handle_get_run(self, request): pass
    async def _handle_stop_run(self, request): pass
    async def _handle_run_approval(self, request): pass
    async def _run_agent(self, active_run_id=None, tool_progress_callback=None):
        loop = asyncio.get_running_loop()
        def _run():
            result = agent.run_conversation(user_message=user_message)
            return result
        return _run()
    def session_stream(self):
        def _tool_progress(event_type, **kwargs):
            if event_type == "reasoning.available":
                pass
'''


def make_install(root):
    root = Path(root)
    (root / "tools").mkdir(exist_ok=True)
    (root / "gateway/platforms").mkdir(parents=True, exist_ok=True)
    # Cuate-authored shape stubs; executable Hermes subjects live outside this repo.
    (root / "tools/approval.py").write_text(
        "def register_gateway_notify(session_key, cb): pass\n"
        "def unregister_gateway_notify(session_key): pass\n"
        "def resolve_gateway_approval(session_key, choice, request_id=None): pass\n"
        "def list_gateway_approvals(session_key): pass\n"
        "def register_gateway_settle(session_key, cb): pass\n"
        "def _gateway_notify_cb(session_key): pass\n")
    (root / "tools/approval_context.py").write_text(
        "def set_current_session_key(key): pass\ndef reset_current_session_key(token): pass\n"
        "def get_current_session_key(): pass\ndef _is_gateway_approval_context(): pass\n"
        "def _get_session_platform(): pass\ndef _is_cron_approval_context(): pass\n")
    (root / "gateway/run.py").write_text("def _redact_approval_command(command): return command\n")
    (root / "gateway/platforms/api_server.py").write_text(SERVER)
