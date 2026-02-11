#!/usr/bin/env bash
set -euo pipefail

# Flags
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage: ./publish_db.sh [-v]

  -v   verbose (print commands as they run)
USAGE
}

while getopts ":vh" opt; do
  case "$opt" in
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
  esac
done
shift "$((OPTIND - 1))"
if (( $# > 0 )); then
  echo "Unexpected arguments: $*" >&2
  usage
  exit 2
fi

if (( VERBOSE )); then
  export PS4='+(${BASH_SOURCE##*/}:${LINENO}): '
  set -x
fi

# ──────────────────────────────────────────────────────────────────────────────
# Config
REPO="goldstandardsolutions/goldstandardsolutions.github.io"
MANIFEST="updates/manifest.json"
PAGES_BASE="https://goldstandardsolutions.github.io"
# ──────────────────────────────────────────────────────────────────────────────

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1' — install it and re-run."; exit 1; }; }
need_repo_root() { git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "Run from repo root."; exit 1; }; }

stat_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }
stat_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

attention() {
  if [[ -w /dev/tty ]]; then
    if command -v tput >/dev/null 2>&1 && [[ "${TERM:-}" != "dumb" ]]; then
      tput bel >/dev/tty 2>/dev/null || printf '\a' >/dev/tty
    else
      printf '\a' >/dev/tty
    fi
  else
    if command -v tput >/dev/null 2>&1 && [[ "${TERM:-}" != "dumb" ]]; then
      tput bel 2>/dev/null || printf '\a' >&2
    else
      printf '\a' >&2
    fi
  fi
}

read_drag_path() {
  local prompt="$1"
  local raw
  attention
  printf '%s\n' "$prompt" >&2
  read -r raw
  raw="${raw%\"}"; raw="${raw#\"}"
  printf "%b" "$raw"
}

read_tag() {
  local prompt="$1"
  local tag
  attention
  printf '%s' "$prompt" >&2
  read -r tag
  [[ "$tag" =~ ^20[0-9]{2}\.[0-1][0-9]\.[0-3][0-9]$ ]] || { echo "Invalid format."; exit 1; }
  printf "%s" "$tag"
}

abs_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
    return
  fi
  local dir base
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  (cd "$dir" && printf '%s/%s' "$(pwd -P)" "$base")
}

auto_find_zip() {
  local best=""
  local best_mtime=""
  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    local m
    m="$(stat_mtime "$f")" || continue
    if [[ -z "$best" || "$m" -gt "$best_mtime" ]]; then
      best="$f"
      best_mtime="$m"
    fi
  done < <(find . -maxdepth 1 -type f -name '*.zip' -print)

  if [[ -z "$best" ]]; then
    return 1
  fi
  printf "%s" "$best"
}

confirm_zip() {
  local zip_path="$1"
  local ans
  attention
  read -r -p "Found ZIP: ${zip_path}. Use this? [Y/n]: " ans
  case "$ans" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

release_exists() {
  local tag="$1"
  gh release view "$tag" --repo "$REPO" >/dev/null 2>&1
}

asset_name_db() { printf "towers-%s.db" "$1"; }
asset_name_summary() { printf "tower_summary-%s.json" "$1"; }
asset_name_whatsnew() { printf "whatsnewin%s.json" "${1//./-}"; }
asset_name_zip() { printf "towers-%s.zip" "$1"; }

read_old_tag() {
  local old=""
  if [[ -f "$MANIFEST" ]]; then
    old="$(jq -r '.version // empty' "$MANIFEST" || true)"
  fi
  printf "%s" "$old"
}

write_or_update_manifest() {
  local tag="$1"
  local release_url="$2"
  local size="$3"
  local sha="$4"

  mkdir -p "$(dirname "$MANIFEST")"

  if [[ -f "$MANIFEST" ]]; then
    local tmp
    tmp="$(mktemp)"
    jq \
      --arg v "$tag" \
      --arg u "$release_url" \
      --argjson z "$size" \
      --arg s "$sha" \
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
  "version": "${tag}",
  "releasedAt": "${tag//./-}T00:00:00Z",
  "minAppVersion": "1.0.0",
  "sizeBytes": ${size},
  "sha256": "${sha}",
  "url": "${release_url}",
  "notes": ""
}
JSON
  fi

  git add "$MANIFEST"
  git commit -m "update manifest for ${tag}" || true
  git push
}

cleanup_local_asset_if_present() {
  local filename="$1"
  if [[ -f "$filename" ]]; then
    rm -f "$filename"
    echo "→ Deleted local file $filename"
  fi
}

pick_single_file() {
  local label="$1"
  shift
  if (( $# == 0 )); then
    echo "Could not find ${label} inside the ZIP."
    exit 1
  fi
  if (( $# > 1 )); then
    echo "Found multiple candidates for ${label} inside the ZIP. Keep only one and retry:"
    printf '  - %s\n' "$@"
    exit 1
  fi
  printf "%s" "$1"
}

extract_payload_from_zip() {
  local zip_path="$1"

  local tmpdir
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf \"$tmpdir\"" EXIT

  unzip -q "$zip_path" -d "$tmpdir"

  local find_args=(
    "$tmpdir"
    -type f
    -not -path '*/__MACOSX/*'
    -not -name '._*'
  )

  local db_candidates=()
  local summary_candidates=()
  local whatsnew_candidates=()

  while IFS= read -r f; do db_candidates+=("$f"); done < <(find "${find_args[@]}" -name '*.db' -print)
  while IFS= read -r f; do summary_candidates+=("$f"); done < <(find "${find_args[@]}" \( -iname '*tower_summary*.json' -o -iname '*towersummary*.json' \) -print)
  while IFS= read -r f; do whatsnew_candidates+=("$f"); done < <(find "${find_args[@]}" -iname '*whatsnew*.json' -print)

  DB_EXTRACTED="$(pick_single_file "DB (.db)" "${db_candidates[@]}")"
  SUMMARY_EXTRACTED="$(pick_single_file "tower summary JSON" "${summary_candidates[@]}")"
  WHATSNEW_EXTRACTED="$(pick_single_file "what's new JSON" "${whatsnew_candidates[@]}")"
}

need_repo_root

# deps for the default full workflow
need gh; need jq; need shasum; need stat; need curl; need unzip

# read current/old version from manifest if present
OLD_TAG="$(read_old_tag)"

ZIP_SRC=""
if DEFAULT_ZIP="$(auto_find_zip)"; then
  if confirm_zip "$DEFAULT_ZIP"; then
    ZIP_SRC="$DEFAULT_ZIP"
  fi
fi
if [[ -z "$ZIP_SRC" ]]; then
  ZIP_SRC="$(read_drag_path "Drag the ZIP (contains DB + tower summary + what's new), then press Enter:")"
fi
[[ -f "$ZIP_SRC" ]] || { echo "File not found: $ZIP_SRC"; exit 1; }

TAG="$(read_tag "Enter the version date for this DB (YYYY.MM.DD, e.g. 2025.10.13): ")"

ASSET_NAME="$(asset_name_db "$TAG")"
JSON_NAME="$(asset_name_summary "$TAG")"
WHATSNEW_NAME="$(asset_name_whatsnew "$TAG")"
ZIP_NAME="$(asset_name_zip "$TAG")"

ASSET_PATH="./${ASSET_NAME}"
JSON_PATH="./${JSON_NAME}"
WHATSNEW_PATH="./${WHATSNEW_NAME}"
ZIP_PATH="./${ZIP_NAME}"

RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"

extract_payload_from_zip "$ZIP_SRC"

cp -f "$DB_EXTRACTED" "$ASSET_PATH"
cp -f "$SUMMARY_EXTRACTED" "$JSON_PATH"
cp -f "$WHATSNEW_EXTRACTED" "$WHATSNEW_PATH"
if [[ "$(abs_path "$ZIP_SRC")" == "$(abs_path "$ZIP_PATH")" ]]; then
  echo "→ ZIP already in place: $ZIP_PATH"
else
  cp -f "$ZIP_SRC" "$ZIP_PATH"
fi

JSON_SIZE="$(stat_size "$JSON_PATH")"
WHATSNEW_SIZE="$(stat_size "$WHATSNEW_PATH")"
ZIP_SIZE="$(stat_size "$ZIP_PATH")"

SHA256="$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')"
SIZE="$(stat_size "$ASSET_PATH")"

echo
echo "Summary:"
echo "  Source ZIP:    $ZIP_SRC"
echo "  ZIP contains:  $(basename "$DB_EXTRACTED"), $(basename "$SUMMARY_EXTRACTED"), $(basename "$WHATSNEW_EXTRACTED")"
echo "  Old version:   ${OLD_TAG:-<none>}"
echo "  New version:   $TAG"
echo "  Asset:         $ASSET_NAME  (${SIZE} bytes)"
echo "  JSON:          $JSON_NAME   (${JSON_SIZE} bytes)"
echo "  What's new:    $WHATSNEW_NAME   (${WHATSNEW_SIZE} bytes)"
echo "  ZIP:           $ZIP_NAME   (${ZIP_SIZE} bytes)"
echo "  SHA256:        $SHA256"
echo "  Release URL:   $RELEASE_URL"
echo

if release_exists "$TAG"; then
  if [[ "$TAG" == "$OLD_TAG" ]]; then
    echo "Note: $TAG matches current manifest version — this will overwrite the existing release assets."
  else
    echo "Note: Release $TAG already exists — this will overwrite its assets."
  fi
fi

attention
read -r -p "Ready to push update? Press Enter to continue (Ctrl+C to cancel) " _

# create or update release (clobber enables re-uploading the same tag)
if release_exists "$TAG"; then
  echo "→ Release $TAG exists — uploading (clobber) assets…"
  gh release upload "$TAG" "$ASSET_PATH" "$JSON_PATH" "$WHATSNEW_PATH" "$ZIP_PATH" --repo "$REPO" --clobber
else
  echo "→ Creating release $TAG and uploading assets…"
  gh release create "$TAG" "$ASSET_PATH" "$JSON_PATH" "$WHATSNEW_PATH" "$ZIP_PATH" \
    --repo "$REPO" \
    --title "Database ${TAG}" \
    --notes "Monthly tower data update"
fi

write_or_update_manifest "$TAG" "$RELEASE_URL" "$SIZE" "$SHA256"

# optional cleanup of previous release/asset
if [[ -n "${OLD_TAG}" && "${OLD_TAG}" != "${TAG}" ]]; then
  echo
  attention
  read -r -p "Do you also want to remove the previous release ${OLD_TAG} (and its asset) from GitHub? [y/N]: " ANSW
  case "$ANSW" in
    y|Y|yes|YES)
      echo "→ Deleting release ${OLD_TAG}…"
      gh release delete "${OLD_TAG}" --repo "$REPO" --yes || echo "Note: release ${OLD_TAG} not found or already gone."
      cleanup_local_asset_if_present "$(asset_name_db "$OLD_TAG")"
      cleanup_local_asset_if_present "$(asset_name_summary "$OLD_TAG")"
      cleanup_local_asset_if_present "$(asset_name_whatsnew "$OLD_TAG")"
      cleanup_local_asset_if_present "$(asset_name_zip "$OLD_TAG")"
      ;;
    *) echo "Keeping previous release ${OLD_TAG}." ;;
  esac
fi

echo
echo "✅ Done."
echo "   Manifest (cache-busted): ${PAGES_BASE}/updates/manifest.json?cb=$(date +%s)"

echo
attention
read -r -p "Send push notification now? [y/N]: " SEND_PUSH
case "$SEND_PUSH" in
  y|Y|yes|YES)
    echo "→ Triggering GitHub Action: send-db-update-push (version: ${TAG})"
    gh workflow run send-db-update-push -f version="$TAG" --repo "$REPO"
    echo "→ Workflow triggered. Check GitHub Actions for status."
    ;;
  *)
    echo "→ Skipped push notification."
    ;;
esac
