#!/usr/bin/env bash
set -Eeuo pipefail

VERSION_FILE="VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "0.1.0" > "$VERSION_FILE"
fi

current="$(cat "$VERSION_FILE" | tr -d '[:space:]')"

IFS='.' read -r major minor patch <<< "$current"

major="${major:-0}"
minor="${minor:-1}"
patch="${patch:-0}"

mode="${1:-patch}"

case "$mode" in
  patch)
    patch=$((patch + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  set)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: ./scripts/bump-version.sh set 0.1.2"
      exit 1
    fi
    echo "$2" > "$VERSION_FILE"
    echo "Version set to $2"
    exit 0
    ;;
  *)
    echo "Usage:"
    echo "  ./scripts/bump-version.sh patch"
    echo "  ./scripts/bump-version.sh minor"
    echo "  ./scripts/bump-version.sh major"
    echo "  ./scripts/bump-version.sh set 0.1.2"
    exit 1
    ;;
esac

new="${major}.${minor}.${patch}"
echo "$new" > "$VERSION_FILE"
echo "Version bumped: $current -> $new"
