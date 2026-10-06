"""Isolated v6 bridge tests against extracted Hermes queue and wait code.

No running gateway, credentials, model calls, database, or application builds.
"""
import asyncio
import contextlib
import contextvars
import importlib.util
import json
import logging
import os
import textwrap
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
from typing import Optional
from hermes.approval_fixture import make_install, SERVER
from hermes.external_approval_source import external_source, external_revision

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patch", ROOT / "scripts/hermes/native_approval_patch.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class Response:
    def __init__(self, data, status=200):
        self.body = json.dumps(data).encode()
        self.status = status


class Contracts(unittest.TestCase):
    def setUp(self):
        self.modules = dict(sys.modules)
        tools = types.ModuleType("tools")
        core = types.ModuleType("tools.approval")
        core.__dict__.update(threading=threading, Optional=Optional, _lock=threading.Lock(),
                             _gateway_queues={}, _gateway_notify_cbs={})
        exec(external_source("tools/approval.py"), core.__dict__)
        tools.approval = core
        self.core = core
        key = contextvars.ContextVar("approval_key", default="original")
        self.key = key
        ctx = types.ModuleType("tools.approval_context")
        ctx.set_current_session_key = key.set
        ctx.reset_current_session_key = key.reset
        ctx.get_current_session_key = key.get
        ctx._session_env = lambda name: self.env.get(name, "")
        ctx.is_truthy_value = bool
        ctx.env_var_enabled = lambda name: bool(self.env.get(name))
        ctx._UNATTENDED_APPROVAL_PLATFORMS = {"api_server", "webhook", "msgraph_webhook"}
        self.env = {"HERMES_SESSION_PLATFORM": "api_server"}
        exec(external_source("tools/approval_context.py"), ctx.__dict__)
        core._is_gateway_approval_context = ctx._is_gateway_approval_context
        core._is_cron_approval_context = ctx._is_cron_approval_context
        core._resolve_cli_approval_callback = lambda callback: callback
        core._is_interactive_cli = lambda: False
        core._is_single_query_approval_context = lambda: False
        core.env_var_enabled = lambda name: False
        tools.approval_context = ctx
        ctx._fire_approval_hook = lambda *a, **k: None
        ctx._get_approval_timeout = lambda: 0.8
        self.wait = dict(threading=threading, time=time, uuid=uuid, _ctx=ctx,
                         logger=logging.getLogger("test"), is_interrupted=lambda: False,
                         get_interrupt_reason=lambda: None,
                         activity_heartbeat=lambda _: lambda: None,
                         human_wait_window=lambda _: contextlib.nullcontext())
        exec("from __future__ import annotations\n" + external_source("tools/approval_gateway_wait.py"), self.wait)
        # 0.21.5+: the wait consults the terminal approval batch; with no batch slot
        # bound (every API run here) its real hooks are no-ops.
        agent = types.ModuleType("agent")
        batch = types.ModuleType("agent.terminal_approval_batch")
        batch.__dict__.update(_slot=contextvars.ContextVar("terminal_approval_slot", default=None))
        batch_source = external_source("agent/terminal_approval_batch.py")
        if batch_source:
            exec(batch_source, batch.__dict__)
        agent.terminal_approval_batch = batch
        gateway_run = types.ModuleType("gateway.run")
        gateway_run._redact_approval_command = lambda text: text.replace("SECRET", "[redacted]")
        sys.modules.update({"tools": tools, "tools.approval": core, "tools.approval_context": ctx,
                            "gateway.run": gateway_run, "agent": agent, "agent.terminal_approval_batch": batch,
                            "aiohttp": types.SimpleNamespace(web=types.SimpleNamespace(json_response=Response))})

        class Adapter:
            def __init__(self):
                self._run_approval_sessions = {}
                self._run_statuses = {"run": {"run_id": "run", "status": "running", "session_id": "session"}}

            def _set_run_status(self, run_id, status, **fields):
                self._run_statuses[run_id].update(status=status, **fields)

            async def _handle_get_run(self, request):
                return Response(self._run_statuses["run"]) if request.authorized else Response({}, 403)

            async def _handle_run_approval(self, request):
                body = await request.json()
                count = core.resolve_gateway_approval(self._run_approval_sessions["run"], body["choice"], request_id=body["request_id"])
                return Response({"resolved": count}, status=200 if count else 409)

            async def _handle_stop_run(self, request):
                if not request.authorized:
                    return Response({}, 403)
                self._set_run_status("run", "stopping")
                return Response({"status": "stopping"})

        self.runtime = dict(APIServerAdapter=Adapter)
        exec(patch.RUNTIME, self.runtime)
        self.adapter = Adapter()
        class Request:
            match_info = {"run_id": "run"}
            authorized = True
            body = {}
            async def json(self):
                return self.body
        self.request = Request()
        self.events = []
        self.loop = types.SimpleNamespace(call_soon_threadsafe=lambda callback: callback())
        self.threads = []

    def tearDown(self):
        for key in list(self.core._gateway_notify_cbs):
            self.core.unregister_gateway_notify(key)
        for thread in self.threads:
            thread.join(2)
            self.assertFalse(thread.is_alive())
        for name in ("tools", "tools.approval", "tools.approval_context", "gateway.run", "aiohttp",
                     "agent", "agent.terminal_approval_batch"):
            if name in self.modules:
                sys.modules[name] = self.modules[name]
            else:
                sys.modules.pop(name, None)

    def scope(self):
        return self.runtime["_cuate_native_approval"](self.adapter, "run", lambda *a, **k: self.events.append((a, k)), self.loop)

    def enqueue(self, command):
        key = self.adapter._run_approval_sessions["run"]
        result = []
        thread = threading.Thread(target=lambda: result.append(self.wait["_await_gateway_decision"](
            key, self.core._gateway_notify_cbs[key], {"command": command})))
        self.threads.append(thread)
        thread.start()
        deadline = time.monotonic() + 1
        while not any(item["command"] == command for item in self.core.list_gateway_approvals(key)):
            if time.monotonic() > deadline:
                self.fail("waiter was not enqueued")
            time.sleep(.001)
        return result, thread

    def status(self):
        return json.loads(asyncio.run(self.adapter._handle_get_run(self.request)).body)

    def test_exact_allow_deny_and_multiple_requests(self):
        with self.scope():
            a, ta = self.enqueue("a SECRET")
            b, tb = self.enqueue("b")
            state = self.status()
            self.assertEqual(state["status"], "waiting_for_approval")
            self.assertEqual(len(state["approvals"]), 2)
            self.assertNotIn("SECRET", json.dumps(state))
            first, second = state["approvals"]
            key = self.key.get()
            self.assertEqual(self.core.resolve_gateway_approval(key, "once", request_id=first["request_id"]), 1)
            ta.join(1)
            self.assertEqual(a[0]["choice"], "once")
            self.assertEqual(len(self.status()["approvals"]), 1)
            self.assertEqual(self.core.resolve_gateway_approval(key, "deny", request_id=first["request_id"]), 0)
            self.assertTrue(tb.is_alive())  # stale reply cannot resolve the next request
            self.core.resolve_gateway_approval(key, "deny", request_id=second["request_id"])
            tb.join(1)
            self.assertEqual(b[0]["choice"], "deny")
            self.assertEqual(self.status()["status"], "running")

    def test_disconnect_reopen_and_lost_post_response(self):
        with self.scope():
            result, thread = self.enqueue("read status only")
            before = self.status()
            # No stream or client state is needed to recover all pending requests.
            self.events.clear()
            self.assertEqual(self.status()["approvals"], before["approvals"])
            self.assertTrue(thread.is_alive())
            request_id = before["approvals"][0]["request_id"]
            self.core.resolve_gateway_approval(self.key.get(), "once", request_id=request_id)
            # Simulate losing the HTTP response, then GET instead of replaying POST.
            self.assertEqual(self.status()["approvals"], [])
            self.assertEqual(self.core.resolve_gateway_approval(self.key.get(), "once", request_id=request_id), 0)
            thread.join(1)
            self.assertEqual(result[0]["choice"], "once")

    def test_stop_releases_all_waiters_without_permission(self):
        with self.scope():
            results = [self.enqueue(str(index)) for index in range(2)]
            asyncio.run(self.adapter._handle_stop_run(self.request))
            for result, thread in results:
                thread.join(1)
                self.assertNotEqual(result[0]["choice"], "once")
                if "_cancel_cause" in self.wait:
                    # 0.21.5+: a withdrawn prompt is reported as cancelled, never as a user deny.
                    self.assertTrue(result[0].get("cancelled"))
            self.assertEqual(self.status()["status"], "stopping")
            self.assertEqual(self.status()["approvals"], [])

    def test_timeout_and_exception_cleanup(self):
        with self.assertRaisesRegex(RuntimeError, "agent failed"):
            with self.scope():
                result, thread = self.enqueue("timeout")
                thread.join(1.5)
                self.assertFalse(result[0]["resolved"])
                self.assertEqual(self.status()["approvals"], [])
                raise RuntimeError("agent failed")
        self.assertEqual(self.key.get(), "original")
        self.assertEqual(self.adapter._run_approval_sessions, {})
        self.assertEqual(self.core._gateway_notify_cbs, {})

    def test_authentication_is_preserved(self):
        with self.scope():
            _, thread = self.enqueue("private")
            self.request.authorized = False
            self.assertEqual(asyncio.run(self.adapter._handle_get_run(self.request)).status, 403)
            self.assertEqual(asyncio.run(self.adapter._handle_stop_run(self.request)).status, 403)
            self.assertTrue(thread.is_alive())

    def test_native_resolver_rejects_bulk_missing_id_and_stop_race(self):
        with self.scope():
            _, thread = self.enqueue("exact only")
            request_id = self.status()["approvals"][0]["request_id"]
            for body in ({"choice": "once"}, {"request_id": request_id, "choice": "always"},
                         {"request_id": request_id, "choice": "once", "all": True}):
                self.request.body = body
                self.assertEqual(asyncio.run(self.adapter._handle_run_approval(self.request)).status, 400)
                self.assertTrue(thread.is_alive())
            self.request.body = {"request_id": "stale", "choice": "deny"}
            self.assertEqual(asyncio.run(self.adapter._handle_run_approval(self.request)).status, 409)
            asyncio.run(self.adapter._handle_stop_run(self.request))
            self.request.body = {"request_id": request_id, "choice": "once"}
            self.assertEqual(asyncio.run(self.adapter._handle_run_approval(self.request)).status, 409)

    def test_transform_idempotence_preservation_and_refusals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_install(root)
            source = SERVER + "\n# unrelated local change\n"
            result = patch.transform(source, root)
            self.assertEqual(patch.transform(result, root), result)
            self.assertIn("# unrelated local change", result)
            self.assertIn("result = agent.run_conversation(user_message=user_message)", result)
            self.assertIn('events.enqueue(event_type, kwargs["approval"])', result)
            self.assertEqual((root / "gateway/platforms/api_server.py").read_text(), SERVER)
            for foreign in (source.replace("active_run_id=None", "other=None"),
                            source.replace("result = agent.run_conversation", "register_gateway_notify = None\n            result = agent.run_conversation"),
                            result.replace("choices=[\"once\", \"deny\"]", "choices=[]")):
                with self.assertRaises(ValueError):
                    patch.transform(foreign, root)
            (root / "tools/approval.py").write_text("def resolve_gateway_approval(): pass\n")
            with self.assertRaises(ValueError):
                patch.transform(source, root)

    def test_real_presence_gate_only_enrolls_live_native_context(self):
        self.assertFalse(self.core._presence()[2])
        with self.scope():
            self.assertTrue(self.core._presence()[2])
            self.env["HERMES_CRON_SESSION"] = "1"
            self.assertFalse(self.core._presence()[2])
            self.env.pop("HERMES_CRON_SESSION")
            self.env["HERMES_SESSION_PLATFORM"] = "webhook"
            self.assertFalse(self.core._presence()[2])
            self.env["HERMES_SESSION_PLATFORM"] = "api_server"
            self.core.unregister_gateway_notify(self.key.get())
            self.assertFalse(self.core._presence()[2])
        self.assertEqual(self.key.get(), "original")
        self.assertFalse(self.core._presence()[2])

    def test_queued_notification_cannot_resurrect_stopped_run(self):
        callbacks = []
        self.loop.call_soon_threadsafe = callbacks.append
        with self.scope():
            result, thread = self.enqueue("stop race")
            asyncio.run(self.adapter._handle_stop_run(self.request))
            thread.join(1)
            for callback in callbacks:
                callback()
            self.assertEqual(self.adapter._run_statuses["run"]["status"], "stopping")
            self.assertNotEqual(result[0]["choice"], "once")

    def test_all_installers_refuse_before_writing_on_missing_queue_api(self):
        settings = (ROOT / "Cuate/Addons/HermesAddon/HermesSettingsView.swift").read_text()
        remote = textwrap.dedent(settings.split('gatewayPatchRemoteCommands = #"""', 1)[1].split('"""#', 1)[0])
        def heredoc(text, marker):
            return text.split("<<'" + marker + "'", 1)[1].split("\n", 1)[1].split("\n" + marker, 1)[0]
        scripts = [
            heredoc(remote, "EOF"),
            heredoc((ROOT / "android/app/src/main/assets/hermes_gateway_patch.sh").read_text(), "EOF"),
            heredoc((ROOT / "docs/hermes-vps-setup.md").read_text(), "PYEOF"),
            heredoc(settings.split("HERMES_DIR=$(hermes --version", 1)[1], "PYEOF").replace("\\\\", "\\"),
        ]
        for script in scripts:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                make_install(root)
                (root / "tools/approval.py").write_text("# incompatible Hermes\n")
                before = {str(path.relative_to(root)): path.read_bytes() for path in root.rglob("*") if path.is_file()}
                result = subprocess.run([sys.executable, "-B", "-c", script],
                    env=dict(os.environ, HERMES_DIR=str(root)), capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                after = {str(path.relative_to(root)): path.read_bytes() for path in root.rglob("*") if path.is_file()}
                self.assertEqual(before, after)

    def test_generated_installers_match(self):
        subprocess.run([sys.executable, "scripts/hermes/sync_approval_patch.py", "--check"], cwd=ROOT, check=True)


if __name__ == "__main__":
    print("Hermes subjects:", external_revision())
    unittest.main()
