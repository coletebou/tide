#!/bin/bash
# Build and upload the sample site.
set -euo pipefail

TARGET="${1:-staging}"
BUILD_DIR="./dist"

echo "Deploying to $TARGET..."
if [[ "$TARGET" == "production" ]]; then
  read -r -p "Deploy to production? [y/N] " answer
  [[ "$answer" == "y" ]] || exit 1
fi

mkdir -p "$BUILD_DIR"
for file in web/*.html web/*.css; do
  cp "$file" "$BUILD_DIR/"
done
echo "Done: $(ls "$BUILD_DIR" | wc -l) files"
