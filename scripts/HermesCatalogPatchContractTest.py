"""Exercise every shipped paste-block on an isolated, credential-free install.

Reproduce the runtime ImportError, then check repair, preservation, backups,
idempotence and parity with the desktop's pure Swift transform. No gateway or
provider is started. Arguments: compiled Swift patch test, repository root.
"""
import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap

swift_test = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()


def heredoc(text, marker):
    return text.split("<<'" + marker + "'", 1)[1].split("\n", 1)[1].split("\n" + marker, 1)[0]


settings = (root / "Cuate/Addons/HermesAddon/HermesSettingsView.swift").read_text()
remote = textwrap.dedent(settings.split('gatewayPatchRemoteCommands = #"""', 1)[1].split('"""#', 1)[0])
guide = settings.split("HERMES_DIR=$(hermes --version", 1)[1]
scripts = {
    "android": heredoc((root / "android/app/src/main/assets/hermes_gateway_patch.sh").read_text(), "EOF"),
    "remote": heredoc(remote, "EOF"),
    "docs": heredoc((root / "docs/hermes-vps-setup.md").read_text(), "PYEOF"),
    "embedded": heredoc(guide, "PYEOF").replace("\\\\", "\\"),
}
for script in scripts.values():
    ast.parse(script)

formatter = "def _format_price_per_mtok(value):\n    return 'price:' + value\n"
models = "def check_nous_free_tier():\n    return False\n"
broken = '''# Keep this local customization.
def price():
    from hermes_cli.models import (
        _format_price_per_mtok,
        check_nous_free_tier,
    )
    return _format_price_per_mtok("1")
'''
single = broken.replace('from hermes_cli.models import (\n        _format_price_per_mtok,\n        check_nous_free_tier,\n    )',
                        'from hermes_cli.models import _format_price_per_mtok')
fixed = broken.replace('    from hermes_cli.models import (\n        _format_price_per_mtok,\n',
                       '    from hermes_cli.models_pricing import _format_price_per_mtok\n    from hermes_cli.models import (\n')
gateway = 'usage = {"context_tokens": 1, "context_window": 10}\n# continues detached\n'
cases = [
    ("broken group", broken, models, formatter, True),
    ("broken single", single, models, formatter, True),
    ("stock new", fixed, models, formatter, False),
    ("stock old", broken, models + formatter, "", False),
    ("old module still exports formatter", broken, models + formatter, formatter, False),
]


def price_result(directory):
    return subprocess.run([sys.executable, "-B", "-c",
                           "from hermes_cli.inventory import price; assert price() == 'price:1'"],
                          cwd=directory, text=True, capture_output=True)


for name, script in scripts.items():
    for case, inventory, model_source, pricing_source, changed in cases:
        with tempfile.TemporaryDirectory() as directory:
            install = Path(directory)
            server = install / "gateway/platforms/api_server.py"
            server.parent.mkdir(parents=True)
            server.write_text(gateway)
            cli = install / "hermes_cli"
            cli.mkdir()
            (cli / "__init__.py").write_text("")
            inv = cli / "inventory.py"
            inv.write_text(inventory)
            (cli / "models.py").write_text(model_source)
            (cli / "models_pricing.py").write_text(pricing_source)
            before = price_result(install)
            if changed:
                assert before.returncode != 0 and "ImportError" in before.stderr, (name, case)
            else:
                assert before.returncode == 0, before.stderr
            subprocess.run([str(swift_test), "--catalog", str(inv), str(cli / "models.py"),
                            str(cli / "models_pricing.py")], check=True, capture_output=True)
            env = dict(os.environ, HERMES_DIR=str(install))
            subprocess.run([sys.executable, "-B", "-c", script], env=env, check=True, capture_output=True)
            assert inv.read_text() == Path(str(inv) + ".swift-patched").read_text(), (name, case, "Swift parity")
            assert server.read_text() == gateway
            assert "# Keep this local customization." in inv.read_text()
            assert (cli / "models.py").read_text() == model_source
            assert (cli / "models_pricing.py").read_text() == pricing_source
            after = price_result(install)
            assert after.returncode == 0, (name, case, after.stderr)
            backup = Path(str(inv) + ".bak")
            assert backup.exists() == changed
            if changed:
                assert backup.read_text() == inventory
            first = inv.read_bytes()
            subprocess.run([sys.executable, "-B", "-c", script], env=env, check=True, capture_output=True)
            assert inv.read_bytes() == first
            if changed:
                assert backup.read_text() == inventory
    print(name + ": catalog import, preservation, idempotence and Swift parity passed")
