#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p lib

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

    if "read -r -p" not in text or "case" not in text:
        continue

    # Add visible 99 option if missing.
    if "99. Exit toolbox" not in text:
        text = re.sub(
            r'(\n\s*echo\s+"0\.\s+(Back|Home|Exit)"\s*)',
            r'\1\n  echo "99. Exit toolbox"',
            text
        )

    # If file shows 99 but has no 99 handler, inject handler after first case line.
    if "99. Exit toolbox" in text and not re.search(r'(^|\n)\s*99\)', text):
        text = re.sub(
            r'(case\s+"\$choice"\s+in\s*\n)',
            r'\1    99)\n      viptrue_exit_toolbox\n      ;;\n',
            text,
            count=1
        )

    if text != original:
        path.write_text(text)
        changed.append(str(path))

print("Changed files:")
for f in changed:
    print("-", f)
PY

find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
  bash -n "$f"
done

echo
echo "✅ Step 13-C completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Force fix exit 99 handlers' && git push"
