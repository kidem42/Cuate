HP=$(hermes --version 2>/dev/null | sed -n 's/^Install directory: //p'); \
[ -z "$HP" ] && HP=$(dirname "$(dirname "$(dirname "$(find /root /home /opt /usr/local \
  -name api_server.py -path '*/gateway/platforms/*' 2>/dev/null | head -1)")")"); \
echo "hermes at: $HP"; \
HERMES_DIR="$HP" python3 - <<'EOF' && hermes gateway restart
import os, re, pathlib
p = pathlib.Path(os.environ["HERMES_DIR"]) / "gateway/platforms/api_server.py"
src = orig = p.read_text()
fill_v3 = '"context_tokens": max(0, getattr(getattr(agent, "context_compressor", None), "last_prompt_tokens", 0) or 0),'
fill = '"context_tokens": (lambda _a, _c: max(0, int(_a["prompt_tokens"]) + int(_a.get("completion_tokens") or 0)) if isinstance(_a, dict) and _a.get("prompt_tokens") else max(0, getattr(_c, "last_prompt_tokens", 0) or 0))(getattr(agent, "_usage_anchor", None), getattr(agent, "context_compressor", None)),'
window = '"context_window": max(0, getattr(getattr(agent, "context_compressor", None), "context_length", 0) or 0),'
total = '"total_tokens": getattr(agent, "session_total_tokens", 0) or 0'
if fill in src:
    print("context_tokens: v4 already in place")
elif fill_v3 in src:
    src = src.replace(fill_v3, fill)
    print("context_tokens: upgraded v3 -> v4 (usage-anchored)")
elif '"context_tokens"' in src:
    print("context_tokens: native upstream - leaving as is")
else:
    # Up to 0.21.0 the usage dict holds one entry per line (trailing comma);
    # 0.21.1 packs "total_tokens" and the closing brace on one line.
    pat = re.compile(r'^(\s*)' + re.escape(total) + r'(,|\})$', re.M)
    src, n = pat.subn(lambda m: m.group(1) + total + ",\n" + m.group(1) + fill + ("" if m.group(2) == "," else "\n" + m.group(1) + "}"), src)
    assert n >= 1, "context anchor not found - different Hermes version, patch by hand"
    print(f"context_tokens: ok, {n} site(s)")
if '"context_window"' in src:
    print("context_window: already patched")
else:
    pat = re.compile(r'^(\s*)(' + re.escape(fill) + r')$', re.M)
    src, n = pat.subn(lambda m: m.group(0) + "\n" + m.group(1) + window, src)
    assert n >= 1, "context_window anchor not found - different Hermes version, patch by hand"
    print(f"context_window: ok, {n} site(s)")
if "continues detached" in src:
    print("detached runs: already patched")
else:
    call = (
        '            await self._drain_session_stream_task_on_disconnect(\n'
        '                run_id, task, interrupt_message="SSE client disconnected", shield_wait=False'
    )
    log = '            logger.info("Session SSE client disconnected; interrupted live run %s", run_id)'
    new = '            logger.info("Session SSE client disconnected; run %s continues detached", run_id)'
    # Up to 0.21.0 the call closes on its own line; 0.21.1 hugs the bracket.
    old = next((o for o in (call + '\n            )\n' + log, call + ')\n' + log) if o in src), None)
    assert old, "disconnect anchor not found - different Hermes version, patch by hand"
    src = src.replace(old, new)
    print("detached runs: ok")
# Repair a retained old inventory after the pricing module was split out.
# Stock old/new installs are no-ops; preserve every unrelated local edit.
catalog = p.parents[2] / "hermes_cli/inventory.py"
models = p.parents[2] / "hermes_cli/models.py"
pricing = p.parents[2] / "hermes_cli/models_pricing.py"
catalog_orig = catalog_new = None
if all(f.is_file() for f in (catalog, models, pricing)):
    definition = r"(?m)^def _format_price_per_mtok\("
    if re.search(definition, pricing.read_text()) and not re.search(definition, models.read_text()):
        catalog_orig = catalog.read_text()
        catalog_new = re.sub(
            r"(?m)^([ \t]*)from hermes_cli\.models import \(\n[ \t]*_format_price_per_mtok,\n",
            r"\1from hermes_cli.models_pricing import _format_price_per_mtok\n\1from hermes_cli.models import (\n",
            catalog_orig)
        catalog_new = re.sub(
            r"(?m)^([ \t]*)from hermes_cli\.models import _format_price_per_mtok$",
            r"\1from hermes_cli.models_pricing import _format_price_per_mtok", catalog_new)
# BEGIN CUATE APPROVAL PATCH V6 (generated)
'''Cuate gateway patch v6: native approvals, using Hermes' own queue.

Pure transform. The existing Cuate installer owns validation, backups and restart.
No gateway modules are imported while preparing the patch.
'''
import ast
from pathlib import Path

VERSION = 6
MARKER = "# Cuate native approvals v6"
RUNTIME = r'''
# Cuate native approvals v6
from contextlib import contextmanager as _cuate_contextmanager


def _cuate_approval_snapshot(adapter, run_id):
    from tools.approval import list_gateway_approvals
    from gateway.run import _redact_approval_command
    key = adapter._run_approval_sessions.get(run_id)
    # Read the authoritative queue, including concurrent requests and timeouts.
    # Do not retain commands, decisions, or a second queue in the adapter.
    return [dict(request_id=item["request_id"], run_id=run_id,
                 command=_redact_approval_command(item.get("command", "")),
                 choices=["once", "deny"])
            for item in (list_gateway_approvals(key) if key else [])
            if isinstance(item.get("request_id"), str) and item["request_id"]]


def _cuate_enable_native_presence():
    from tools import approval, approval_context
    # Preserve Hermes policy for every other surface. Only an API run with
    # our live notifier is a human-addressable approval context. Do not spoof
    # HERMES_SESSION_PLATFORM: background delivery/continuation uses it too.
    if getattr(approval, "_cuate_native_presence_v6", False):
        return
    original = approval_context._is_gateway_approval_context

    def present():
        key = approval_context.get_current_session_key()
        native = (approval_context._get_session_platform() == "api_server"
                  and not approval_context._is_cron_approval_context()
                  and key.startswith("cuate-native:")
                  and approval._gateway_notify_cb(key) is not None)
        return native or original()

    approval_context._is_gateway_approval_context = present
    approval._is_gateway_approval_context = present
    approval._cuate_native_presence_v6 = True


@_cuate_contextmanager
def _cuate_native_approval(adapter, run_id, callback, loop):
    if not run_id:
        yield
        return
    from tools.approval import register_gateway_notify, unregister_gateway_notify, register_gateway_settle
    from tools.approval_context import set_current_session_key, reset_current_session_key
    _cuate_enable_native_presence()
    key = "cuate-native:" + run_id
    token = set_current_session_key(key)
    previous = adapter._run_approval_sessions.get(run_id)

    def publish():
        # Serialize state changes with HTTP Stop on the gateway's event loop.
        pending = _cuate_approval_snapshot(adapter, run_id)
        state = adapter._run_statuses.get(run_id, {}).get("status")
        if state in {"running", "waiting_for_approval", "queued"}:
            adapter._set_run_status(run_id, "waiting_for_approval" if pending else "running",
                                    last_event="approval.changed")
        if callback:
            callback("approval.changed", approval={"run_id": run_id})

    def changed():
        loop.call_soon_threadsafe(publish)

    def notify(payload):
        # The queue already owns the request. Polling GET /v1/runs restores it
        # even if the stream has disconnected. Never overwrite Stop/terminal.
        state = adapter._run_statuses.get(run_id, {}).get("status")
        if state in {"stopping", "completed", "failed", "cancelled"}:
            unregister_gateway_notify(key)
            return
        changed()
        if not register_gateway_settle(key, payload["request_id"], lambda reason: changed()):
            changed()

    try:
        adapter._run_approval_sessions[run_id] = key
        register_gateway_notify(key, notify)
        yield
    finally:
        try:
            unregister_gateway_notify(key)
        finally:
            reset_current_session_key(token)
            if previous is None:
                adapter._run_approval_sessions.pop(run_id, None)
            else:
                adapter._run_approval_sessions[run_id] = previous


def _cuate_install_approval_routes(cls):
    import json
    from aiohttp import web
    get_run = cls._handle_get_run
    stop_run = cls._handle_stop_run
    resolve_run = cls._handle_run_approval

    async def get(self, request):
        # Keep Hermes authentication, ownership checks and error responses.
        response = await get_run(self, request)
        if response.status != 200:
            return response
        state = json.loads(response.body)
        run_id = request.match_info["run_id"]
        pending = _cuate_approval_snapshot(self, run_id)
        status = state.get("status")
        if status in {"queued", "running", "waiting_for_approval"}:
            status = "waiting_for_approval" if pending else ("running" if status == "waiting_for_approval" else status)
        else:
            pending = []
        state.update(status=status, approvals=pending, cuate_approval_version=1)
        state.pop("approval", None)
        return web.json_response(state)

    async def stop(self, request):
        response = await stop_run(self, request)
        if 200 <= response.status < 300:
            # The upstream handler has authenticated and set the interrupt.
            # Wake waiters with NO decision: unregister never grants consent.
            from tools.approval import unregister_gateway_notify
            key = self._run_approval_sessions.get(request.match_info["run_id"])
            if key and key.startswith("cuate-native:"):
                unregister_gateway_notify(key)
        return response

    async def resolve(self, request):
        # Authenticate/authorize status before inspecting native run state;
        # the original resolver still enforces its approval permission.
        run_id = request.match_info["run_id"]
        key = self._run_approval_sessions.get(run_id, "")
        if not key.startswith("cuate-native:"):
            return await resolve_run(self, request)
        response = await get_run(self, request)
        if response.status != 200:
            return response
        state = json.loads(response.body)
        if state.get("status") in {"stopping", "completed", "failed", "cancelled"}:
            return web.json_response({"error": "approval_not_active"}, status=409)
        key = self._run_approval_sessions.get(run_id, "")
        if key.startswith("cuate-native:"):
            try:
                body = await request.json()
            except Exception:
                return web.json_response({"error": "invalid_approval_request"}, status=400)
            request_id = body.get("request_id") if isinstance(body, dict) else None
            if (not isinstance(request_id, str) or not request_id.strip() or len(request_id) > 256
                    or body.get("choice") not in {"once", "deny"}
                    or "all" in body or "resolve_all" in body):
                return web.json_response({"error": "exact_request_required"}, status=400)
        return await resolve_run(self, request)

    cls._handle_get_run = get
    cls._handle_stop_run = stop
    cls._handle_run_approval = resolve


_cuate_install_approval_routes(APIServerAdapter)
'''


def repair_skills_catalog(source, root):
    '''Adapt the known retained Gateway call to the installed skills signature.'''
    tree = ast.parse(source)
    handlers = [node for node in ast.walk(tree)
                if isinstance(node, ast.AsyncFunctionDef) and node.name == "_handle_skills"]
    calls = [node for handler in handlers for node in ast.walk(handler)
             if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
             and node.func.id == "_find_all_skills"
             and any(kw.arg == "include_editorial" for kw in node.keywords)]
    if not calls:
        return source
    if len(calls) != 1:
        raise ValueError("Ambiguous skills catalog call; no files changed")
    skills = ast.parse((Path(root) / "tools/skills_tool.py").read_text())
    definitions = [node for node in skills.body
                   if isinstance(node, ast.FunctionDef) and node.name == "_find_all_skills"]
    if len(definitions) != 1:
        raise ValueError("Unsupported skills catalog definition")
    args = definitions[0].args
    names = {arg.arg for arg in args.args + args.kwonlyargs}
    if "include_editorial" in names or args.kwarg:
        return source
    call = calls[0]
    keywords = {kw.arg: kw.value for kw in call.keywords}
    if (call.args or len(call.keywords) != 2
            or set(keywords) != {"skip_disabled", "include_editorial"}
            or "skip_disabled" not in names
            or not isinstance(keywords["skip_disabled"], ast.Constant)
            or keywords["skip_disabled"].value is not False
            or not isinstance(keywords["include_editorial"], ast.Constant)
            or keywords["include_editorial"].value is not True):
        raise ValueError("Unknown skills catalog call; inspect before patching")
    original = ast.get_source_segment(source, call)
    if source.count(original) != 1:
        raise ValueError("Ambiguous skills catalog source")
    result = source.replace(original, "_find_all_skills(skip_disabled=False)", 1)
    compile(result, "<cuate-skills-compatibility>", "exec")
    return result


def transform(source, root):
    source = repair_skills_catalog(source, root)
    tree = ast.parse(source)
    already = MARKER in source
    if already:
        if not source.endswith(RUNTIME) or source.count("with _cuate_native_approval(self, active_run_id, tool_progress_callback, loop):") != 1:
            raise ValueError("Different Cuate approval patch; inspect before replacing it")
    functions = [n for n in ast.walk(tree) if isinstance(n, ast.AsyncFunctionDef) and n.name == "_run_agent"]
    if len(functions) != 1:
        raise ValueError("Unsupported native agent layout; no approval patch applied")
    function = functions[0]
    section = ast.get_source_segment(source, function)
    if not already and ("register_gateway_notify" in section or "native_approval" in section):
        raise ValueError("Native approval support already exists; review upstream/foreign implementation")
    if "asyncio.get_running_loop()" not in section:
        raise ValueError("Unsupported native event loop")
    if "active_run_id" not in [arg.arg for arg in function.args.args]:
        raise ValueError("Native runs have no control identity")
    # Validate actual protocol seams, including a complete pending snapshot.
    root = Path(root)
    approval = ast.parse((root / "tools/approval.py").read_text())
    definitions = {n.name: n for n in approval.body if isinstance(n, ast.FunctionDef)}
    for name in ("list_gateway_approvals", "register_gateway_settle", "_gateway_notify_cb", "register_gateway_notify", "unregister_gateway_notify", "resolve_gateway_approval"):
        if name not in definitions:
            raise ValueError("Hermes lacks required approval API: " + name)
    args = definitions["resolve_gateway_approval"].args
    if "request_id" not in [a.arg for a in args.args + args.kwonlyargs]:
        raise ValueError("Hermes cannot resolve an exact approval request")
    for path, names in (("tools/approval_context.py", ("set_current_session_key", "reset_current_session_key", "get_current_session_key", "_is_gateway_approval_context", "_get_session_platform", "_is_cron_approval_context")),
                        ("gateway/run.py", ("_redact_approval_command",))):
        parsed = ast.parse((root / path).read_text())
        found = {n.name for n in parsed.body if isinstance(n, ast.FunctionDef)}
        if not set(names) <= found:
            raise ValueError("Unsupported approval context/redaction")
    routes = source + "\n" + "\n".join(path.read_text() for path in (root / "gateway/platforms").glob("api_server_*.py"))
    if not all(name in routes for name in ("_run_approval_sessions", "_handle_get_run", "_handle_stop_run", "_handle_run_approval", "_set_run_status")):
        raise ValueError("Unsupported run routes")
    if already:
        return source
    calls = [n for n in ast.walk(function) if isinstance(n, ast.Assign)
             and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Attribute)
             and n.value.func.attr == "run_conversation"]
    if len(calls) != 1:
        raise ValueError("Ambiguous native invocation")
    call = calls[0]
    lines = source.splitlines(keepends=True)
    original = lines[call.lineno - 1:call.end_lineno]
    lines[call.lineno - 1:call.end_lineno] = [" " * call.col_offset + "with _cuate_native_approval(self, active_run_id, tool_progress_callback, loop):\n"] + ["    " + line for line in original]
    transformed = "".join(lines)
    anchor = '            if event_type == "reasoning.available":'
    if transformed.count(anchor) != 1:
        raise ValueError("Unsupported session event callback")
    transformed = transformed.replace(anchor,
        '            if event_type == "approval.changed":\n'
        '                events.enqueue(event_type, kwargs["approval"])\n'
        '            elif event_type == "reasoning.available":')
    result = transformed.rstrip() + "\n" + RUNTIME
    compile(result, "<cuate-gateway-v6>", "exec")
    return result

src = transform(src, p.parents[2])
# END CUATE APPROVAL PATCH V6
# Validate BOTH candidates before either file changes. No module is imported
# here: patching must not load credentials or contact provider APIs.
import ast
ast.parse(src)
if catalog_new is not None:
    ast.parse(catalog_new)
if src != orig:
    pathlib.Path(str(p) + ".bak").write_text(orig)
    p.write_text(src)
    print("written; backup at api_server.py.bak")
else:
    print("nothing to do")
if catalog_new is not None and catalog_new != catalog_orig:
    pathlib.Path(str(catalog) + ".bak").write_text(catalog_orig)
    catalog.write_text(catalog_new)
    print("model catalog: repaired pricing import; backup at inventory.py.bak")
else:
    print("model catalog: no repair needed")
EOF
