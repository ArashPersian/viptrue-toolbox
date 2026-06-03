#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p lib

cat > /tmp/viptrue_ui_exit_patch.py <<'PY'
from pathlib import Path
import re

ui = Path("lib/ui.sh")
text = ui.read_text() if ui.exists() else """#!/usr/bin/env bash

NC='\\033[0m'
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
CYAN='\\033[0;36m'

line() {
  echo "============================================================"
}

pause() {
  read -r -p "Press Enter to continue..."
}
"""

# Remove previous exit helper block variants
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
    r'\n?viptrue_should_exit_toolbox\(\)\s*\{.*?\n\}\s*\n?',
    "\n",
    text,
    flags=re.S
)

text += r'''

# VIPTrue global exit flag.
# Must be stable between parent and child menu processes.
export VIPTRUE_EXIT_FLAG="${VIPTRUE_EXIT_FLAG:-/tmp/viptrue_toolbox_exit_${USER:-root}}"

viptrue_exit_toolbox() {
  touch "$VIPTRUE_EXIT_FLAG" 2>/dev/null || true
  clear
  echo "Bye."
  exit 0
}

viptrue_should_exit_toolbox() {
  if [[ -n "${VIPTRUE_EXIT_FLAG:-}" && -f "$VIPTRUE_EXIT_FLAG" ]]; then
    rm -f "$VIPTRUE_EXIT_FLAG" 2>/dev/null || true
    clear
    echo "Bye."
    exit 0
  fi
}
'''

ui.write_text(text)
PY

python3 /tmp/viptrue_ui_exit_patch.py

python3 - <<'PY'
from pathlib import Path
import re

targets = []
for folder in ["menus", "modules"]:
    p = Path(folder)
    if p.exists():
        targets.extend(p.rglob("*.sh"))

for name in ["toolbox.sh", "main.sh", "viptrue-toolbox.sh", "bootstrap.sh"]:
    p = Path(name)
    if p.exists():
        targets.append(p)

changed = []

for path in targets:
    text = path.read_text()
    original = text

    if "read -r -p" not in text and "while true; do" not in text:
        continue

    # Add visible 99 after common 0 option
    if "99. Exit toolbox" not in text:
        text = re.sub(
            r'(\n\s*echo\s+"0\.\s+(Back|Home|Exit)"\s*)',
            r'\1\n  echo "99. Exit toolbox"',
            text
        )

    # Add handler inside first case if missing
    if "99. Exit toolbox" in text and not re.search(r'(^|\n)\s*99\)', text):
        text = re.sub(
            r'(case\s+"\$choice"\s+in\s*\n)',
            r'\1    99)\n      viptrue_exit_toolbox\n      ;;\n',
            text,
            count=1
        )

    # Ensure every loop checks global exit at top
    if "while true; do" in text and "viptrue_should_exit_toolbox" not in text:
        text = text.replace(
            "while true; do",
            "while true; do\n  viptrue_should_exit_toolbox",
            1
        )

    # If there are bash submenu calls, check exit flag immediately after them
    lines = text.splitlines()
    new_lines = []
    for line in lines:
        new_lines.append(line)
        stripped = line.strip()
        if (
            stripped.startswith("bash ")
            and "viptrue_should_exit_toolbox" not in stripped
            and "bash -n" not in stripped
            and not stripped.startswith("bash <")
        ):
            indent = line[:len(line) - len(line.lstrip())]
            new_lines.append(f"{indent}viptrue_should_exit_toolbox")

    text = "\n".join(new_lines) + ("\n" if text.endswith("\n") else "")

    if text != original:
        path.write_text(text)
        changed.append(str(path))

print("Changed files:")
for item in changed:
    print("-", item)
PY

find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 13-E completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Finalize global exit flag behavior' && git push"
