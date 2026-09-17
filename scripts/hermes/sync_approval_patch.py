"""Generate identical v6 approval transforms in Cuate's existing installers.

Run with --check in contract tests. The canonical transform is adjacent.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
source = Path(__file__).with_name("native_approval_patch.py").read_text().replace('"""', "'''")
BEGIN = "# BEGIN CUATE APPROVAL PATCH V6 (generated)"
END = "# END CUATE APPROVAL PATCH V6"
block = BEGIN + "\n" + source + "\nsrc = transform(src, p.parents[2])\n" + END + "\n"


def replace_block(text, content, anchor):
    if BEGIN in text:
        start = text.index(BEGIN)
        # Include the existing indentation in the replacement.
        start = text.rfind("\n", 0, start) + 1
        end = text.index(END, start) + len(END)
        return text[:start] + content.rstrip("\n") + text[end:]
    at = text.index(anchor)
    return text[:at] + content + text[at:]


updates = {}
for name in ("android/app/src/main/assets/hermes_gateway_patch.sh", "docs/hermes-vps-setup.md"):
    path = ROOT / name
    updates[path] = replace_block(path.read_text(), block, "# Validate BOTH candidates")

path = ROOT / "Cuate/Addons/HermesAddon/HermesSettingsView.swift"
text = path.read_text()
# Two representations: the raw remote command and the escaped embedded guide.
split = text.index('    """#', text.index('gatewayPatchRemoteCommands = #"""'))
first, second = text[:split], text[split:]
first = replace_block(first, "".join("    " + line if line.strip() else line for line in block.splitlines(keepends=True)), "    # Validate BOTH candidates")
second = replace_block(second, block.replace("\\", "\\\\"), "# Validate BOTH candidates")
updates[path] = first + second

path = ROOT / "Cuate/Addons/HermesAddon/HermesGatewayPatch.swift"
text = path.read_text()
marker = "\n// Generated from scripts/hermes/native_approval_patch.py."
text = text.split(marker)[0]
updates[path] = text.rstrip() + marker + '''
extension HermesGatewayPatch {
    static let approvalVersion = 6
    static let approvalProgram = #"""
''' + source + '''
import sys
root, original, output = map(Path, sys.argv[1:])
Path(output).write_text(transform(Path(original).read_text(), root))
"""#
}
'''

different = []
for path, text in updates.items():
    if path.read_text() != text:
        different.append(str(path.relative_to(ROOT)))
        if "--check" not in sys.argv:
            path.write_text(text)
if "--check" in sys.argv and different:
    raise SystemExit("Approval patch copies differ: " + ", ".join(different))
