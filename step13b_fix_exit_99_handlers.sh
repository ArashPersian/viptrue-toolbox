#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p lib

# Ensure global exit function exists
if [[ -f lib/ui.sh ]]; then
  if ! grep -q 'viptrue_exit_toolbox' lib/ui.sh; then
    cat >> lib/ui.sh <<'EOF'

viptrue_exit_toolbox() {
  clear
  echo "Bye."
  exit 0
}
EOF
  fi
else
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

viptrue_exit_toolbox() {
  clear
  echo "Bye."
  exit 0
}
EOF
fi

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

    # Only menu-like files
    if "case" not in text or "read -r -p" not in text:
        continue

    # Add visible 99 option after common 0 option if missing
    if "99. Exit toolbox" not in text:
        text = re.sub(
            r'(\n\s*echo\s+"0\.\s+(Back|Home|Exit)"\s*)',
            r'\1\n  echo "99. Exit toolbox"',
            text
        )

    # If visible 99 exists but no case handler, add handler before default case
    if "99. Exit toolbox" in text and not re.search(r'(^|\n)\s*99\)', text):
        # Prefer viptrue_exit_toolbox; if file has local exit_toolbox, both are okay
        default_patterns = [
            r'(\n\s*\*\)\s*\n\s*echo -e "\$\{RED\}Invalid choice\.\$\{NC\}"\s*\n\s*sleep 1\s*\n\s*;;)',
            r'(\n\s*\*\)\s*\n\s*echo.*Invalid choice.*\n\s*sleep 1\s*\n\s*;;)',
            r'(\n\s*\*\)\s*\n\s*.*Invalid choice.*\n\s*;;)',
        ]

        inserted = False
        handler = '\n    99)\n      viptrue_exit_toolbox\n      ;;\n'

        for pat in default_patterns:
            if re.search(pat, text):
                text = re.sub(pat, handler + r'\1', text, count=1)
                inserted = True
                break

        if not inserted:
            print(f"WARNING: Could not insert 99 handler in {path}")

    if text != original:
        path.write_text(text)
        changed.append(str(path))

print("Changed files:")
for item in changed:
    print("-", item)
PY

# Syntax check
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 13-B completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Fix global exit handlers in menus' && git push"
