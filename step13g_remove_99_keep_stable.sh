#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

targets = []
for folder in ["menus", "modules"]:
    p = Path(folder)
    if p.exists():
        targets.extend(p.rglob("*.sh"))

for name in ["toolbox.sh", "main.sh", "viptrue-toolbox.sh"]:
    p = Path(name)
    if p.exists():
        targets.append(p)

changed = []

for path in targets:
    text = path.read_text()
    original = text

    # Remove visible 99 menu lines
    text = re.sub(r'^\s*echo\s+"99\.\s+(Exit toolbox|Main Menu)"\s*\n?', '', text, flags=re.M)

    # Remove 99 case handlers
    text = re.sub(
        r'\n\s*99\)\s*\n\s*(viptrue_exit_toolbox|viptrue_main_menu|exit_toolbox)\s*\n\s*;;\s*',
        '\n',
        text,
        flags=re.M
    )

    # Remove old global-exit loop calls
    text = text.replace("  viptrue_should_exit_toolbox\n", "")
    text = text.replace("viptrue_should_exit_toolbox\n", "")

    if text != original:
        path.write_text(text)
        changed.append(str(path))

# Clean ui helper from global exit experiments but keep colors/ui functions
ui = Path("lib/ui.sh")
if ui.exists():
    text = ui.read_text()
    original = text

    text = re.sub(
        r'\n?# VIPTrue global exit flag\..*?viptrue_should_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
        "\n",
        text,
        flags=re.S
    )
    text = re.sub(
        r'\n?# Global exit flag:.*?viptrue_should_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
        "\n",
        text,
        flags=re.S
    )
    text = re.sub(
        r'\n?viptrue_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
        "\n",
        text,
        flags=re.S
    )
    text = re.sub(
        r'\n?viptrue_main_menu\(\)\s*\{.*?\n\}\s*\n?',
        "\n",
        text,
        flags=re.S
    )
    text = re.sub(
        r'\n?viptrue_should_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
        "\n",
        text,
        flags=re.S
    )

    if text != original:
        ui.write_text(text)
        changed.append("lib/ui.sh")

print("Changed files:")
for f in changed:
    print("-", f)
PY

find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 13-G completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Remove unstable 99 menu shortcut and keep menus stable' && git push"
