#!/usr/bin/env bash
set -euo pipefail

# publish_db.sh
# Usage: ./publish_db.sh 2025.11
#
# Requirements:
# - gh CLI configured and authenticated
# - openssl installed
# - git configured & on main branch
# - ec_private.pem available in repo root OR EC_PRIVATE_PEM env var set (PEM text)
# - repo variable below points to your repo (owner/repo)
#
# What it does:
# 1) creates a GitHub release and uploads the DB asset
# 2) writes updates/manifest.json (exact bytes)
# 3) signs that manifest with ec_private.pem (DER ECDSA P-256)
# 4) commits & pushes manifest and manifest.sig
# 5) verifies signature locally

REPO="goldstandardsolutions/goldstandardsolutions.github.io"  # change if needed
PRIVATE_KEY_FILE="ec_private.pem"  # local private key (preferred)
TMP_KEY_FILE=""
WORKDIR="$(pwd)"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <VERSION>   e.g. $0 2025.11"
  exit 2
fi

VERSION="$1"
ASSET="towers-${VERSION}.db"
RELEASE_TITLE="DB ${VERSION}"
RELEASE_NOTES="Published DB ${VERSION} by publish_db.sh"

# helper: portable stat filesize
filesize() {
  if stat -f%z "$1" >/dev/null 2>&1; then
    stat -f%z "$1"
  else
    # Linux fallback
    stat -c%s "$1"
  fi
}

# sanity checks
if [ ! -f "${ASSET}" ]; then
  echo "ERROR: asset ${ASSET} not found in ${WORKDIR}"
  exit 3
fi

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found. Install and login (gh auth login)."; exit 4; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found."; exit 5; }

echo "=== Publishing ${ASSET} as release ${VERSION} for repo ${REPO} ==="

# 1) create release (if it exists, gh will error; allow continuing)
echo "-- creating release (if not exists)..."
set +e
gh release create "${VERSION}" "${ASSET}" --repo "${REPO}" --title "${RELEASE_TITLE}" --notes "${RELEASE_NOTES}"
RC=$?
set -e
if [ $RC -ne 0 ]; then
  echo "Note: gh release create returned non-zero (release may already exist). Continuing..."
fi

# 2) compute metadata
SHA=$(shasum -a 256 "${ASSET}" | awk '{print $1}')
SIZE=$(filesize "${ASSET}")
RELEASED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST_PATH="updates/manifest.json"
SIG_PATH="updates/manifest.sig"
SIG_B64_PATH="updates/manifest.sig.b64"
mkdir -p updates

# 3) write manifest.json (these exact bytes will be signed)
cat > "${MANIFEST_PATH}" <<EOF
{
  "version": "${VERSION}",
  "releasedAt": "${RELEASED}",
  "minAppVersion": "1.0.0",
  "sizeBytes": ${SIZE},
  "sha256": "${SHA}",
  "url": "https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}",
  "notes": "Monthly update ${VERSION}",
  "signature": ""
}
EOF

echo "-- manifest written to ${MANIFEST_PATH} (size: $(filesize ${MANIFEST_PATH}))"

# 4) choose private key source: file or env var
use_temp_key=false
if [ -f "${PRIVATE_KEY_FILE}" ]; then
  echo "-- using local private key ${PRIVATE_KEY_FILE}"
  KEY_FILE="${PRIVATE_KEY_FILE}"
elif [ -n "${EC_PRIVATE_PEM-}" ]; then
  echo "-- EC_PRIVATE_PEM env var found; writing temp key file"
  TMP_KEY_FILE="$(mktemp -t ec_private.XXXXXX.pem)"
  printf "%s\n" "${EC_PRIVATE_PEM}" > "${TMP_KEY_FILE}"
  chmod 600 "${TMP_KEY_FILE}"
  KEY_FILE="${TMP_KEY_FILE}"
  use_temp_key=true
else
  echo "ERROR: no private key found. Put your PEM in ${PRIVATE_KEY_FILE} or set EC_PRIVATE_PEM env var."
  exit 6
fi

# 5) sign manifest with openssl (DER signature)
echo "-- signing manifest (DER ECDSA P-256)"
openssl dgst -sha256 -sign "${KEY_FILE}" -out "${SIG_PATH}" "${MANIFEST_PATH}"

# also write base64 variant (convenience)
openssl base64 -in "${SIG_PATH}" -A -out "${SIG_B64_PATH}"

echo "-- signature created: ${SIG_PATH} and ${SIG_B64_PATH}"

# 6) cleanup temp key (if created)
if [ "${use_temp_key}" = true ]; then
  echo "-- removing temporary key file"
  shred -u "${TMP_KEY_FILE}" 2>/dev/null || rm -f "${TMP_KEY_FILE}"
fi

# 7) commit & push manifest and signature
echo "-- committing & pushing manifest + signature"
git add "${MANIFEST_PATH}" "${SIG_PATH}" "${SIG_B64_PATH}"
git commit -m "chore: publish manifest ${VERSION}" || echo "Nothing to commit (maybe identical manifest)"
git push origin HEAD

# 8) sanity verify locally (served files may take a moment to update on Pages)
echo "-- local verify: openssl dgst -sha256 -verify updates/pubkey.pem -signature ${SIG_PATH} ${MANIFEST_PATH}"
set +e
openssl dgst -sha256 -verify updates/pubkey.pem -signature "${SIG_PATH}" "${MANIFEST_PATH}"
VERIFY_RC=$?
set -e
if [ $VERIFY_RC -eq 0 ]; then
  echo "=== Verified OK locally"
else
  echo "WARNING: local verify failed (openssl exit ${VERIFY_RC}). Do not proceed blindly."
fi

# 9) upload the asset to release (ensure asset exists on the release; gh release create might have already uploaded)
echo "-- uploading asset to release (idempotent attempt)"
set +e
gh release upload "${VERSION}" "${ASSET}" --repo "${REPO}" --clobber
RC_UPLOAD=$?
set -e
if [ $RC_UPLOAD -ne 0 ]; then
  echo "Note: gh release upload returned non-zero (asset may exist). Continuing."
fi

echo "=== Publish complete. Manifest: ${MANIFEST_PATH}, Signature: ${SIG_PATH}"
echo "Next: wait ~30-90s for Pages to serve new files, then verify externally via:"
echo "  curl -s https://goldstandardsolutions.github.io/updates/manifest.json -o /tmp/manifest.json"
echo "  curl -s https://goldstandardsolutions.github.io/updates/manifest.sig -o /tmp/manifest.sig"
echo "  openssl dgst -sha256 -verify updates/pubkey.pem -signature /tmp/manifest.sig /tmp/manifest.json"
