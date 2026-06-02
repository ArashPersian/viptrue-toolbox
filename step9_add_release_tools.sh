#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/viptrue-toolbox"
cd "$PROJECT_DIR"

mkdir -p scripts

cat > VERSION <<'EOF'
0.1.0
EOF

cat > scripts/release.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ ! -f VERSION ]]; then
  echo "0.1.0" > VERSION
fi

CURRENT_VERSION="$(cat VERSION | tr -d '[:space:]')"

echo -e "${CYAN}VIPTrue Toolbox Release Helper${NC}"
echo "Current version: ${CURRENT_VERSION}"
echo

echo "Choose release type:"
echo "1. Patch  - bug fix        ${CURRENT_VERSION} -> x.x.+1"
echo "2. Minor  - new feature    x.+1.0"
echo "3. Major  - big change     +1.0.0"
echo "4. Custom version"
echo "0. Cancel"
echo
read -r -p "Enter your choice [0-4]: " choice

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$choice" in
  1)
    PATCH=$((PATCH + 1))
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    ;;
  2)
    MINOR=$((MINOR + 1))
    PATCH=0
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    ;;
  3)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    ;;
  4)
    read -r -p "Enter custom version, example 0.2.0: " NEW_VERSION
    ;;
  0)
    echo "Cancelled."
    exit 0
    ;;
  *)
    echo -e "${RED}Invalid choice.${NC}"
    exit 1
    ;;
esac

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo -e "${RED}Invalid version format. Use format like 0.1.1${NC}"
  exit 1
fi

TAG="v${NEW_VERSION}"

echo
echo -e "${YELLOW}New version:${NC} ${NEW_VERSION}"
echo -e "${YELLOW}Git tag:${NC} ${TAG}"
echo

read -r -p "Release title: " RELEASE_TITLE
if [[ -z "${RELEASE_TITLE// /}" ]]; then
  RELEASE_TITLE="VIPTrue Toolbox ${TAG}"
fi

echo
echo "Write release notes. End with CTRL+D:"
echo "----------------------------------------"
RELEASE_NOTES="$(cat)"
echo "----------------------------------------"
echo

echo "$NEW_VERSION" > VERSION

git add .

if git diff --cached --quiet; then
  echo -e "${YELLOW}No changes to commit.${NC}"
else
  git commit -m "Release ${TAG}"
fi

git tag -a "$TAG" -m "$RELEASE_TITLE"

git push origin main
git push origin "$TAG"

if command -v gh >/dev/null 2>&1; then
  echo "$RELEASE_NOTES" | gh release create "$TAG" \
    --title "$RELEASE_TITLE" \
    --notes-file -
  echo -e "${GREEN}GitHub Release created: ${TAG}${NC}"
else
  echo -e "${YELLOW}GitHub CLI not found. Tag was pushed, but release page was not created.${NC}"
  echo "Install gh or create the release manually on GitHub."
fi

echo
echo -e "${GREEN}Release completed successfully.${NC}"
echo "Version: ${NEW_VERSION}"
echo "Tag: ${TAG}"
EOF

chmod +x scripts/release.sh

bash -n scripts/release.sh

echo
echo "✅ Step 9 completed successfully."
echo "Now run:"
echo "git add . && git commit -m 'Add release helper tools' && git push"
