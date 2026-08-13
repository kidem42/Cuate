HP=$(hermes --version 2>/dev/null | sed -n 's/^Install directory: //p'); \
[ -z "$HP" ] && HP=$(dirname "$(dirname "$(dirname "$(find /root /home /opt /usr/local \
  -name api_server.py -path '*/gateway/platforms/*' 2>/dev/null | head -1)")")"); \
echo "hermes at: $HP"; \
HERMES_DIR="$HP" python3 - <<'EOF' && hermes gateway restart
import os, re, pathlib
p = pathlib.Path(os.environ["HERMES_DIR"]) / "gateway/platforms/api_server.py"
src = orig = p.read_text()

# --- edit 1: usage.context_tokens + context_window in run.completed -------
# context_tokens = real fill (last call's prompt); context_window = the
# window the agent ACTUALLY operates with (OAuth caps included) — the pair
# the client gauge needs, from the same frame.
fill = '"context_tokens": max(0, getattr(getattr(agent, "context_compressor", None), "last_prompt_tokens", 0) or 0),'
window = '"context_window": max(0, getattr(getattr(agent, "context_compressor", None), "context_length", 0) or 0),'
if '"context_tokens"' in src:
    print("context_tokens: already patched")
else:
    pat = re.compile(r'^(\s*)("total_tokens": getattr\(agent, "session_total_tokens", 0\) or 0,)$', re.M)
    src, n = pat.subn(lambda m: m.group(0) + "\n" + m.group(1) + fill, src)
    assert n >= 1, "context anchor not found - different Hermes version, patch by hand"
    print(f"context_tokens: ok, {n} site(s)")
if '"context_window"' in src:
    print("context_window: already patched")
else:
    # Anchored on the context_tokens line so this also UPGRADES a gateway
    # carrying only the older one-line patch.
    pat = re.compile(r'^(\s*)("context_tokens": max\(0, getattr\(getattr\(agent, "context_compressor", None\), "last_prompt_tokens", 0\) or 0\),)$', re.M)
    src, n = pat.subn(lambda m: m.group(0) + "\n" + m.group(1) + window, src)
    assert n >= 1, "context_window anchor not found - different Hermes version, patch by hand"
    print(f"context_window: ok, {n} site(s)")

# --- edit 2: POST /api/sessions/{id}/steer (mid-turn steering) ------------
def put(old, new):
    global src
    assert src.count(old) == 1, "steer anchor not found - need Hermes 0.20 (run 'hermes update' first)"
    src = src.replace(old, new, 1)

if '_handle_session_steer' in src:
    print("session_steer: already patched")
else:
    put('        self._shutdown_interruptible_agents: Dict[int, Any] = {}\n',
        '        self._shutdown_interruptible_agents: Dict[int, Any] = {}\n'
        '        # Cuate patch: live agent per session for mid-turn steering.\n'
        '        self._active_session_agents: Dict[str, Any] = {}\n')
    put('            ("POST", "/api/sessions/{session_id}/model", self._handle_session_model_lock),\n',
        '            ("POST", "/api/sessions/{session_id}/model", self._handle_session_model_lock),\n'
        '            ("POST", "/api/sessions/{session_id}/steer", self._handle_session_steer),\n')
    put('                "session_model_lock": True,\n',
        '                "session_model_lock": True,\n'
        '                "session_steer": True,\n')
    put('                "session_model_lock": {"method": "POST", "path": "/api/sessions/{session_id}/model"},\n',
        '                "session_model_lock": {"method": "POST", "path": "/api/sessions/{session_id}/model"},\n'
        '                "session_steer": {"method": "POST", "path": "/api/sessions/{session_id}/steer"},\n')
    put('                    self._shutdown_interruptible_agents[id(agent)] = agent\n',
        '                    self._shutdown_interruptible_agents[id(agent)] = agent\n'
        '                    if session_id:\n'
        '                        # Cuate patch: expose the live agent for /steer.\n'
        '                        self._active_session_agents[session_id] = agent\n')
    put('                        self._shutdown_interruptible_agents.pop(id(agent), None)\n',
        '                        self._shutdown_interruptible_agents.pop(id(agent), None)\n'
        '                        # Cuate patch: drop only this turn\'s registration.\n'
        '                        if session_id and self._active_session_agents.get(session_id) is agent:\n'
        '                            self._active_session_agents.pop(session_id, None)\n')
    put('    @_admit_api_agent_request\n'
        '    async def _handle_session_chat(self, request: "web.Request") -> "web.Response":\n',
        '''    async def _handle_session_steer(self, request: "web.Request") -> "web.Response":
        """POST /api/sessions/{session_id}/steer - Cuate patch.

        Nudges the running turn via AIAgent.steer(): the text rides on the
        next completed tool batch, no interrupt (TUI session.steer semantics).
        200 queued/rejected; 409 no_active_turn -> client sends normally.
        """
        auth_err = self._check_auth(request)
        if auth_err:
            return auth_err
        session_id = request.match_info["session_id"]
        _session, err = await self._get_existing_session_or_404(session_id)
        if err:
            return err
        body, err = await self._read_json_body(request)
        if err:
            return err
        text = str(body.get("text") or "").strip()
        if not text:
            return web.json_response(_openai_error("'text' is required", code="invalid_steer"), status=400)
        agent = self._active_session_agents.get(session_id)
        if agent is None or not hasattr(agent, "steer"):
            return web.json_response(_openai_error("No active turn to steer for this session", code="no_active_turn"), status=409)
        try:
            accepted = bool(agent.steer(text))
        except Exception as exc:
            return web.json_response(_openai_error(f"steer failed: {exc}", code="steer_failed"), status=500)
        return web.json_response({
            "object": "hermes.session.steer",
            "session_id": session_id,
            "status": "queued" if accepted else "rejected",
        })

    @_admit_api_agent_request
    async def _handle_session_chat(self, request: "web.Request") -> "web.Response":
''')
    print("session_steer: ok")

if src != orig:
    pathlib.Path(str(p) + ".bak").write_text(orig)  # backup next to the file
    import ast; ast.parse(src)  # refuse to write a broken file
    p.write_text(src)
    print("written; backup at api_server.py.bak")
else:
    print("nothing to do")
EOF
