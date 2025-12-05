#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Config
REPO="goldstandardsolutions/goldstandardsolutions.github.io"
MANIFEST="updates/manifest.json"
PAGES_BASE="https://goldstandardsolutions.github.io"
# ──────────────────────────────────────────────────────────────────────────────

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1' — install it and re-run."; exit 1; }; }
need gh; need jq; need shasum; need stat; need curl; git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "Run from repo root."; exit 1; }

# read current/old version from manifest if present
OLD_TAG=""
if [[ -f "$MANIFEST" ]]; then
  OLD_TAG="$(jq -r '.version // empty' "$MANIFEST" || true)"
fi

echo "Drag the DB file you want to upload, then press Enter:"
read -r RAW_PATH
RAW_PATH="${RAW_PATH%\"}"; RAW_PATH="${RAW_PATH#\"}"
DB_SRC=$(printf "%b" "$RAW_PATH")
[[ -f "$DB_SRC" ]] || { echo "File not found: $DB_SRC"; exit 1; }

echo "Drag the tower summary JSON you want to upload, then press Enter:"
read -r RAW_JSON
RAW_JSON="${RAW_JSON%\"}"; RAW_JSON="${RAW_JSON#\"}"
JSON_SRC=$(printf "%b" "$RAW_JSON")
[[ -f "$JSON_SRC" ]] || { echo "File not found: $JSON_SRC"; exit 1; }

echo -n "Enter the version date for this DB (YYYY.MM.DD, e.g. 2025.10.13): "
read -r TAG
[[ "$TAG" =~ ^20[0-9]{2}\.[0-1][0-9]\.[0-3][0-9]$ ]] || { echo "Invalid format."; exit 1; }

JSON_NAME="tower_summary-${TAG}.json"
JSON_PATH="./${JSON_NAME}"

ASSET_NAME="towers-${TAG}.db"
ASSET_PATH="./${ASSET_NAME}"
RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"

cp -f "$DB_SRC" "$ASSET_PATH"
cp -f "$JSON_SRC" "$JSON_PATH"
JSON_SIZE=$(stat -f%z "$JSON_PATH" 2>/dev/null || stat -c%s "$JSON_PATH")

SHA256=$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')
SIZE=$(stat -f%z "$ASSET_PATH" 2>/dev/null || stat -c%s "$ASSET_PATH")

echo
echo "Summary:"
echo "  Source:        $DB_SRC"
echo "  Old version:   ${OLD_TAG:-<none>}"
echo "  New version:   $TAG"
echo "  Asset:         $ASSET_NAME  (${SIZE} bytes)"
echo "  JSON:          $JSON_NAME   (${JSON_SIZE} bytes)"
echo "  SHA256:        $SHA256"
echo "  Release URL:   $RELEASE_URL"
echo
read -r -p "Ready to push update? Press Enter to continue (Ctrl+C to cancel) " _

# create or update release
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "→ Release $TAG exists — uploading (clobber) asset…"
  gh release upload "$TAG" "$ASSET_PATH" "$JSON_PATH" --repo "$REPO" --clobber
else
  echo "→ Creating release $TAG and uploading asset…"
  gh release create "$TAG" "$ASSET_PATH" "$JSON_PATH" \
    --repo "$REPO" \
    --title "Database ${TAG}" \
    --notes "Monthly tower data update"
fi

# ensure manifest dir exists
mkdir -p "$(dirname "$MANIFEST")"

# write/update manifest
if [[ -f "$MANIFEST" ]]; then
  tmp=$(mktemp)
  jq \
    --arg v "$TAG" \
    --arg u "$RELEASE_URL" \
    --argjson z "$SIZE" \
    --arg s "$SHA256" \
    '
    .version = $v
    | .releasedAt = ($v | sub("\\.";"-";"g") | . + "T00:00:00Z")
    | .url = $u
    | .sizeBytes = $z
    | .sha256 = $s
    ' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
else
  cat > "$MANIFEST" <<JSON
{
  "version": "${TAG}",
  "releasedAt": "${TAG//./-}T00:00:00Z",
  "minAppVersion": "1.0.0",
  "sizeBytes": ${SIZE},
  "sha256": "${SHA256}",
  "url": "${RELEASE_URL}",
  "notes": ""
}
JSON
fi

git add "$MANIFEST"
git commit -m "update manifest for ${TAG}" || true
git push

# optional cleanup of previous release/asset
if [[ -n "${OLD_TAG}" && "${OLD_TAG}" != "${TAG}" ]]; then
  echo
  read -r -p "Do you also want to remove the previous release ${OLD_TAG} (and its asset) from GitHub? [y/N]: " ANSW
  case "$ANSW" in
    y|Y|yes|YES)
      echo "→ Deleting release ${OLD_TAG}…"
      # deleting the release leaves the git tag by default; that’s fine
      gh release delete "${OLD_TAG}" --repo "$REPO" --yes || echo "Note: release ${OLD_TAG} not found or already gone."
      # clean up any local old asset copy
      if [[ -f "towers-${OLD_TAG}.db" ]]; then
        rm -f "towers-${OLD_TAG}.db"
        echo "→ Deleted local file towers-${OLD_TAG}.db"
      fi
      ;;
    *) echo "Keeping previous release ${OLD_TAG}."; ;;
  esac
fi

echo
echo "✅ Done."
echo "   Manifest (cache-busted): ${PAGES_BASE}/updates/manifest.json?cb=$(date +%s)"
echo "   Asset URL:               ${RELEASE_URL}"
echo "   Tip: in app, fetch manifest with a cache-buster & set cachePolicy = reloadIgnoringLocalCacheData."
