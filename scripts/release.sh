#!/usr/bin/env bash
# Cut a SnapSiphon release:  scripts/release.sh 0.2.1   (or: mise run release -- 0.2.1)
#
#   1. refuses a dirty tree
#   2. refuses a version that isn't semver-greater than the last v* tag
#   3. archives with MARKETING_VERSION=<semver>, a UTC-timestamp build id,
#      and the git hash baked into Info.plist (SnapSiphonGitCommit) —
#      all injected as build settings, so the tree stays clean
#   4. uploads to App Store Connect / TestFlight (unless --no-upload), using an
#      App Store Connect API key fetched from 1Password
#   5. tags vX.Y.Z and pushes branch + tag
#
# TestFlight credentials — a fastlane-style JSON blob in 1Password:
#     {"key_id": "ABC123", "issuer_id": "uuid…", "key": "-----BEGIN PRIVATE KEY-----\n…"}
#   stored at the secret reference in ASC_KEY_JSON_REF (default below), created
#   at App Store Connect → Users and Access → Integrations → App Store Connect API
#   (role: App Manager). Or export ASC_KEY_JSON with the raw JSON directly.
set -euo pipefail
cd "$(dirname "$0")/.."

ASC_KEY_JSON_REF="${ASC_KEY_JSON_REF:-op://Private/SnapSiphon ASC API Key/notesPlain}"

VERSION=""
UPLOAD=1
for arg in "$@"; do
    case "$arg" in
        --no-upload) UPLOAD=0 ;;
        *) VERSION="$arg" ;;
    esac
done
[[ -n "$VERSION" ]] || { echo "usage: release.sh X.Y.Z [--no-upload]"; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ '$VERSION' is not X.Y.Z semver"; exit 1; }

[[ -z "$(git status --porcelain)" ]] || { echo "✗ working tree is dirty — commit or stash first"; exit 1; }

LAST=$(git tag --list 'v*' --sort=-v:refname | head -1)
if [[ -n "$LAST" ]]; then
    HIGHEST=$(printf '%s\n%s\n' "${LAST#v}" "$VERSION" | sort -V | tail -1)
    if [[ "$HIGHEST" != "$VERSION" || "v$VERSION" == "$LAST" ]]; then
        echo "✗ $VERSION must be greater than the last tag ($LAST)"; exit 1
    fi
fi

BUILD=$(date -u +%Y%m%d%H%M)          # timestamp build id, e.g. 202607221530
HASH=$(git rev-parse --short HEAD)
ARCHIVE="build/SnapSiphon-$VERSION.xcarchive"

echo "▸ v$VERSION  build $BUILD  commit $HASH"
xcodegen generate --quiet
xcodebuild -project SnapSiphon.xcodeproj -scheme SnapSiphon \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    GIT_COMMIT_HASH="$HASH" \
    archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$ARCHIVE" ]] || { echo "✗ archive failed"; exit 1; }

if [[ "$UPLOAD" == 1 ]]; then
    KEY_JSON="${ASC_KEY_JSON:-}"
    if [[ -z "$KEY_JSON" ]] && command -v op >/dev/null; then
        KEY_JSON=$(op read "$ASC_KEY_JSON_REF" 2>/dev/null || true)
    fi
    if [[ -z "$KEY_JSON" ]]; then
        echo "✗ no App Store Connect key (1Password item '$ASC_KEY_JSON_REF' or \$ASC_KEY_JSON)."
        echo "  Re-run with --no-upload to skip TestFlight, or add the key."
        exit 1
    fi
    KEYDIR=$(mktemp -d)
    trap 'rm -rf "$KEYDIR"' EXIT
    KEY_ID=$(printf '%s' "$KEY_JSON"    | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_id"])')
    ISSUER_ID=$(printf '%s' "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer_id"])')
    # Sanitize: copy/paste into 1Password can smuggle invisible control chars
    # into the PEM body — strip to pure base64 and rewrap.
    printf '%s' "$KEY_JSON" | python3 -c '
import json, sys, re
k = json.load(sys.stdin)["key"]
body = re.sub(r"[^A-Za-z0-9+/=]", "", k.replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", ""))
lines = "\n".join(body[i:i+64] for i in range(0, len(body), 64))
sys.stdout.write(f"-----BEGIN PRIVATE KEY-----\n{lines}\n-----END PRIVATE KEY-----\n")' \
        > "$KEYDIR/AuthKey_$KEY_ID.p8"
    chmod 600 "$KEYDIR/AuthKey_$KEY_ID.p8"

    echo "▸ uploading to App Store Connect (TestFlight)…"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportOptionsPlist scripts/ExportOptions.plist \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEYDIR/AuthKey_$KEY_ID.p8" \
        -authenticationKeyID "$KEY_ID" \
        -authenticationKeyIssuerID "$ISSUER_ID" \
        | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload" || true
fi

git tag -a "v$VERSION" -m "SnapSiphon $VERSION (build $BUILD, $HASH)"
git push origin HEAD "v$VERSION"
echo "✅ v$VERSION released — archive at $ARCHIVE"
