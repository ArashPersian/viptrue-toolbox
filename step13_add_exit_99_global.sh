#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p lib

# Add global exit helper to ui.sh if missing
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

files = []

for folder in ["menus", "modules"]:
    p = Path(folder)
    if p.exists():
        files.extend(p.rglob("*.sh"))

# Also include common root scripts if they exist
for name in ["toolbox.sh", "main.sh", "viptrue-toolbox.sh"]:
    p = Path(name)
    if p.exists():
        files.append(p)

changed = []

for path in files:
    text = path.read_text()

    if "read -r -p" not in text:
        continue

    original = text

    # Ensure source ui exists already in most files; skip if not a menu-ish file.
    if "source" not in text and "lib/ui.sh" not in text:
        continue

    # Add visible 99 option after common 0.Back/0.Exit lines if not already there.
    if "99. Exit toolbox" not in text:
        text = re.sub(
            r'(echo\s+"0\.\s+(?:Back|Home|Exit)"\s*\n)',
            r'\1  echo "99. Exit toolbox"\n',
            text
        )

    # Add case handler before default *) if not already there.
    if "99)" not in text and "viptrue_exit_toolbox" in text or "99. Exit toolbox" in text:
        text = re.sub(
            r'(\s+\*\)\s*\n\s+echo -e "\$\{RED\}Invalid choice\.\$\{NC\}"\s*\n\s+sleep 1\s*\n\s+;;)',
            r'    99)\n      viptrue_exit_toolbox\n      ;;\n\1',
            text
        )

    # Fallback for files that define exit_toolbox locally, like temp tunnel.
    if "99. Exit toolbox" in text and "99)" not in text:
        text = re.sub(
            r'(\s+\*\)\s*\n\s+echo -e "\$\{RED\}Invalid choice\.\$\{NC\}"\s*\n\s+sleep 1\s*\n\s+;;)',
            r'    99)\n      viptrue_exit_toolbox\n      ;;\n\1',
            text
        )

    if text != original:
        path.write_text(text)
        changed.append(str(path))

print("Changed files:")
for item in changed:
    print("-", item)
PY

# Syntax check all bash files
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 13 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add global exit option to toolbox menus' && git push"
