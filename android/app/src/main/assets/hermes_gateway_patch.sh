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
if fill in src:
    print("context_tokens: v4 already in place")
elif fill_v3 in src:
    src = src.replace(fill_v3, fill)
    print("context_tokens: upgraded v3 -> v4 (usage-anchored)")
elif '"context_tokens"' in src:
    print("context_tokens: native upstream - leaving as is")
else:
    pat = re.compile(r'^(\s*)("total_tokens": getattr\(agent, "session_total_tokens", 0\) or 0,)$', re.M)
    src, n = pat.subn(lambda m: m.group(0) + "\n" + m.group(1) + fill, src)
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
    old = (
        '            await self._drain_session_stream_task_on_disconnect(\n'
        '                run_id, task, interrupt_message="SSE client disconnected", shield_wait=False\n'
        '            )\n'
        '            logger.info("Session SSE client disconnected; interrupted live run %s", run_id)'
    )
    new = '            logger.info("Session SSE client disconnected; run %s continues detached", run_id)'
    assert old in src, "disconnect anchor not found - different Hermes version, patch by hand"
    src = src.replace(old, new)
    print("detached runs: ok")
if src != orig:
    pathlib.Path(str(p) + ".bak").write_text(orig)
    import ast; ast.parse(src)
    p.write_text(src)
    print("written; backup at api_server.py.bak")
else:
    print("nothing to do")
EOF
