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

if src != orig:
    pathlib.Path(str(p) + ".bak").write_text(orig)  # backup next to the file
    import ast; ast.parse(src)  # refuse to write a broken file
    p.write_text(src)
    print("written; backup at api_server.py.bak")
else:
    print("nothing to do")
EOF
