"""Check copyable guide commands without a VPS, SSH connection, or app build.

The tunnel test runs the real shell/PlistBuddy against temporary files while
SSH, launchctl, network checks and port discovery are replaced with fakes.
"""
import ast
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUIDE = (ROOT / 'Cuate/Addons/HermesAddon/HermesConnectionGuide.swift').read_text()
VIEW = (ROOT / 'Cuate/Addons/HermesAddon/HermesSettingsView.swift').read_text()
LOCALIZATION = (ROOT / 'Cuate/Addons/HermesAddon/HermesLocalization.swift').read_text()


def literal(source, name):
    return textwrap.dedent(source.split(name + ' = #"""', 1)[1].split('"""#', 1)[0]).strip('\n')


PATCH = literal(VIEW, 'gatewayPatchRemoteCommands')
PATCH_BODY = PATCH.split("<<'EOF' && hermes gateway restart\n", 1)[1].rsplit('\nEOF', 1)[0]
COMMANDS = {name: literal(GUIDE, name) for name in (
    'serverPrefix', 'serverSuffix', 'tunnelCommands', 'domainCommands', 'runtimeCommands')}
SERVER = COMMANDS['serverPrefix'] + '\nHERMES_DIR="$INSTALL" "$PYTHON" - <<\'EOF\'\n' + PATCH_BODY + '\nEOF\n' + COMMANDS['serverSuffix']


class GuideCommandsTest(unittest.TestCase):
    def test_complete_shell_and_python_syntax(self):
        for name, script in [('server', SERVER)] + list(COMMANDS.items())[2:]:
            with self.subTest(name=name):
                result = subprocess.run(['/bin/bash', '-n'], input=script, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                for body in re.findall(r"<<'PY'\n(.*?)\nPY", script, re.S):
                    ast.parse(body)
        ast.parse(PATCH_BODY)

    def test_translation_completeness(self):
        entries = re.findall(r'"(hermes\.guide\.[^"]+)": \[(.*?)\n        \],', LOCALIZATION, re.S)
        keys = [key for key, _ in entries]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertGreater(len(keys), 30)
        for key, body in entries:
            with self.subTest(key=key):
                for lang in ('english', 'spanish', 'russian'):
                    value = re.search(r'\.' + lang + r': ("(?:[^"\\]|\\.)*")', body)
                    self.assertIsNotNone(value)
                    self.assertTrue(json.loads(value.group(1)))
        for key in re.findall(r'HL\("(hermes\.guide\.[^"\\]+)"\)', VIEW + GUIDE):
            self.assertIn(key, keys)
        for route in ('domain', 'tunnel'):
            for suffix in ('intro', 'title', 'body', 'fields', 'restart'):
                self.assertIn('hermes.guide.' + route + '.' + suffix, keys)

    def test_server_preserves_keys_and_rejects_old_sqlite(self):
        # Run the actual config-writing heredoc with only the path, dotenv
        # dependency and SQLite metadata replaced. No server modules imported.
        body = re.search(r"<<'PY'\n(.*?)\nPY", COMMANDS['serverPrefix'], re.S).group(1)
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / '.env'
            original = "API_SERVER_KEY='existing-chat'\nHERMES_DASHBOARD_SESSION_TOKEN='existing-files'\nPROVIDER_KEY='keep-me'\n"
            p.write_text(original)
            fake = '''import sys, types, pathlib
module = types.ModuleType('dotenv')
def read(path):
    return dict(line.split('=', 1) for line in pathlib.Path(path).read_text().splitlines() if '=' in line)
def values(path):
    return {k: v.strip("'") for k, v in read(path).items()}
def set_key(path, key, value, **kwargs):
    d = read(path)
    d[key] = repr(value)
    pathlib.Path(path).write_text(''.join(k + '=' + v + '\\n' for k, v in d.items()))
module.dotenv_values = values
module.set_key = set_key
sys.modules['dotenv'] = module
import sqlite3
'''
            candidate = body.replace("'/root/.hermes/.env'", repr(str(p)))
            for version, expected in [((3, 50, 4), 1), ((3, 53, 1), 0), ((3, 53, 1), 0)]:
                result = subprocess.run([os.sys.executable, '-c', fake + '\nsqlite3.sqlite_version_info = ' + repr(version) + '\n' + candidate], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected:
                    self.assertEqual(p.read_text(), original)
                else:
                    data = p.read_text()
                    for value in ('existing-chat', 'existing-files', 'keep-me'):
                        self.assertIn(value, data)
                    self.assertEqual(data.count('API_SERVER_KEY='), 1)
                    self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            p.write_text("PROVIDER_KEY='keep-me'\n")
            result = subprocess.run([os.sys.executable, '-c', fake + '\nsqlite3.sqlite_version_info = (3, 53, 1)\n' + candidate], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            values = dict(line.split('=', 1) for line in p.read_text().splitlines())
            self.assertNotEqual(values['API_SERVER_KEY'], values['HERMES_DASHBOARD_SESSION_TOKEN'])

    @unittest.skipUnless(Path('/usr/libexec/PlistBuddy').exists(), 'macOS PlistBuddy required')
    def test_tunnel_installer_and_port_conflict(self):
        with tempfile.TemporaryDirectory(prefix='cuate-guide-') as directory:
            root = Path(directory)
            mac = root / 'Mac account'
            key = mac / '.ssh/key with spaces'
            key.parent.mkdir(parents=True)
            key.touch()
            fake = root / 'fake'
            fake.mkdir()
            log = root / 'calls.jsonl'
            for name in ('ssh', 'ssh-add', 'launchctl', 'curl', 'lsof'):
                path = fake / name
                path.write_text('#!' + os.sys.executable + '\n' + '''import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['CUATE_TEST_LOG'], 'a') as f:
    f.write(json.dumps([name] + sys.argv[1:]) + '\\n')
if name == 'lsof':
    sys.exit(0 if os.environ.get('CUATE_TEST_BUSY') == '1' else 1)
''')
                path.chmod(0o700)
            script = COMMANDS['tunnelCommands'].replace('YOUR_SERVER_IP', '192.0.2.1').replace('YOUR_SSH_KEY', 'key with spaces')
            script = script.replace('$HOME', str(mac)).replace(' </dev/tty', '')
            for before, after in [('/usr/bin/ssh-add', fake / 'ssh-add'), ('/usr/bin/ssh', fake / 'ssh'), ('/usr/sbin/lsof', fake / 'lsof')]:
                script = script.replace(before, str(after))
            script = re.sub(r'\blaunchctl\b', str(fake / 'launchctl'), script)
            script = re.sub(r'\bcurl\b', str(fake / 'curl'), script)
            env = dict(os.environ, CUATE_TEST_LOG=str(log))
            for _ in range(2):
                result = subprocess.run(['/bin/bash'], input=script, capture_output=True, text=True, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            plist = mac / 'Library/LaunchAgents/com.cuate.hermes-tunnel.plist'
            data = plistlib.loads(plist.read_bytes())
            self.assertTrue(data['RunAtLoad'])
            self.assertTrue(data['KeepAlive'])
            generated = Path(data['ProgramArguments'][1])
            self.assertTrue(generated.with_suffix('.sh.backup').exists())
            result = subprocess.run(['/bin/bash', str(generated)], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            call = json.loads(log.read_text().splitlines()[-1])
            self.assertIn(str(key), call)
            for option in ('UseKeychain=yes', 'ExitOnForwardFailure=yes', '127.0.0.1:18642:127.0.0.1:8642', '127.0.0.1:19119:127.0.0.1:9119'):
                self.assertIn(option, call)
            before = generated.read_bytes()
            result = subprocess.run(['/bin/bash'], input=script, capture_output=True, text=True, env=dict(env, CUATE_TEST_BUSY='1'))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('busy', result.stdout)
            self.assertNotIn('Tunnel ready', result.stdout)
            self.assertEqual(generated.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
