#!/usr/bin/env bash
set -Eeuo pipefail

cd ~/viptrue-toolbox

VERSION="$(cat VERSION 2>/dev/null | tr -d '[:space:]')"
VERSION="${VERSION:-0.1.0}"
TAG="v${VERSION}"

echo "Current version: $VERSION"
echo "Release tag: $TAG"
echo

echo "Checking git status..."
git status --short

echo
read -r -p "Continue and create release $TAG? [y/N]: " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

# Make sure latest commits are pushed
git push

# Create tag if missing
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag already exists locally: $TAG"
else
  git tag -a "$TAG" -m "VIPTrue Server Toolbox $TAG"
fi

# Push tag
git push origin "$TAG"

# Create GitHub Release if gh is available
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    if gh release view "$TAG" >/dev/null 2>&1; then
      echo "GitHub Release already exists: $TAG"
    else
      gh release create "$TAG" \
        --title "VIPTrue Server Toolbox $TAG" \
        --notes "Stable release: Temporary Proxy Mode with subscriptions, VLESS Reality support, delay sorting, and sing-box proxy mode."
    fi
    echo
    echo "✅ GitHub Release created: $TAG"
  else
    echo
    echo "⚠️ gh is installed but not logged in."
    echo "Run:"
    echo "gh auth login"
    echo
    echo "Tag was pushed, but GitHub Release was not created."
  fi
else
  echo
  echo "⚠️ GitHub CLI not installed."
  echo "Tag was pushed, but GitHub Release was not created."
  echo
  echo "Install gh or create release manually from GitHub UI:"
  echo "Releases > Create a new release > Choose tag: $TAG"
fi
