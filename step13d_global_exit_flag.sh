#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p lib

# Patch lib/ui.sh with a real global exit flag mechanism
if [[ ! -f lib/ui.sh ]]; then
  cat > lib/ui.sh <<'EOF'
#!/usr/bin/env bash

NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'

line() {
  echo "============================================================"
}

pause() {
  read -r -p "Press Enter to continue..."
}
EOF
fi

python3 - <<'PY'
from pathlib import Path
import re

ui = Path("lib/ui.sh")
text = ui.read_text()

# Remove older/simple viptrue_exit_toolbox definition if present
text = re.sub(
    r'\n?viptrue_exit_toolbox\(\)\s*\{\s*\n\s*clear\s*\n\s*echo "Bye\."\s*\n\s*exit 0\s*\n\}\s*\n?',
    "\n",
    text,
    flags=re.S
)

if "viptrue_should_exit_toolbox()" not in text:
    text += r'''

# Global exit flag:
# Submenus are often executed as child bash processes.
# Plain "exit" only returns to the parent menu.
# This flag lets all parent menus exit cleanly too.
if [[ -z "${VIPTRUE_EXIT_FLAG:-}" ]]; then
  export VIPTRUE_EXIT_FLAG="/tmp/viptrue_toolbox_exit_${USER:-root}_$$_$RANDOM"
  rm -f "$VIPTRUE_EXIT_FLAG" 2>/dev/null || true
fi

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

    if "while true; do" not in text:
        continue

    # Add visible 99 option if missing after common 0 option
    if "99. Exit toolbox" not in text:
        text = re.sub(
            r'(\n\s*echo\s+"0\.\s+(Back|Home|Exit)"\s*)',
            r'\1\n  echo "99. Exit toolbox"',
            text
        )

    # Add 99 case handler if missing
    if "99. Exit toolbox" in text and not re.search(r'(^|\n)\s*99\)', text):
        text = re.sub(
            r'(case\s+"\$choice"\s+in\s*\n)',
            r'\1    99)\n      viptrue_exit_toolbox\n      ;;\n',
            text,
            count=1
        )

    # Add global exit check at the beginning of each loop
    if "viptrue_should_exit_toolbox" not in text:
        text = text.replace(
            "while true; do",
            "while true; do\n  viptrue_should_exit_toolbox",
            1
        )
    else:
        # If function exists only in ui or elsewhere, still ensure loop calls it
        if "while true; do\n  viptrue_should_exit_toolbox" not in text:
            text = text.replace(
                "while true; do",
                "while true; do\n  viptrue_should_exit_toolbox",
                1
            )

    if text != original:
        path.write_text(text)
        changed.append(str(path))

print("Changed files:")
for item in changed:
    print("-", item)
PY

# Syntax check all shell files
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 13-D completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Implement real global exit flag for toolbox' && git push"
