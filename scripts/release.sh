#!/usr/bin/env bash
# Cut a SnapSiphon release:  mise run release
#
#   1. requires main with every change checked in
#   2. refreshes tags from origin and offers patch/minor/major bumps from the
#      newest stable vX.Y.Z tag (an explicit X.Y.Z argument remains available
#      for non-interactive automation)
#   3. refuses a version that isn't semver-greater than the latest tag
#   4. archives with MARKETING_VERSION=<semver>, a UTC-timestamp build id,
#      and the git hash baked into Info.plist (SnapSiphonGitCommit) —
#      all injected as build settings, so the tree stays clean
#   5. uploads to App Store Connect / TestFlight (unless --no-upload), using an
#      App Store Connect API key fetched from 1Password
#   6. tags vX.Y.Z and pushes main + tag
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
        -h|--help)
            echo "usage: mise run release [-- X.Y.Z] [--no-upload]"
            echo "       With no version, choose a tag-derived patch/minor/major bump interactively."
            exit 0
            ;;
        -*)
            echo "✗ unknown option: $arg"
            exit 1
            ;;
        *)
            [[ -z "$VERSION" ]] || { echo "✗ specify only one version"; exit 1; }
            VERSION="$arg"
            ;;
    esac
done

BRANCH=$(git branch --show-current)
[[ "$BRANCH" == "main" ]] || { echo "✗ releases must run from main (currently '$BRANCH')"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ working tree is dirty — commit or stash first"; exit 1; }

git remote get-url origin >/dev/null 2>&1 || { echo "✗ git remote 'origin' is not configured"; exit 1; }
echo "▸ refreshing main and release tags from origin…"
git fetch --quiet --tags origin
if git show-ref --verify --quiet refs/remotes/origin/main; then
    git merge-base --is-ancestor origin/main HEAD ||
        { echo "✗ local main is behind or diverged from origin/main — update it before releasing"; exit 1; }
fi

# Only stable release tags participate. Pre-release/other v* tags are ignored.
LAST=""
while IFS= read -r tag; do
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        LAST="$tag"
        break
    fi
done < <(git tag --list --sort=-v:refname)
[[ -n "$LAST" ]] || { echo "✗ no stable vX.Y.Z release tag found"; exit 1; }

LATEST="${LAST#v}"
IFS=. read -r LATEST_MAJOR LATEST_MINOR LATEST_PATCH <<<"$LATEST"
# Release convention: the default patch choice advances by two. For example,
# v0.2.1 offers v0.2.3, while minor/major choices reset the trailing fields.
PATCH_VERSION="$LATEST_MAJOR.$LATEST_MINOR.$((LATEST_PATCH + 2))"
MINOR_VERSION="$LATEST_MAJOR.$((LATEST_MINOR + 1)).0"
MAJOR_VERSION="$((LATEST_MAJOR + 1)).0.0"

if [[ -z "$VERSION" ]]; then
    echo
    echo "Latest release: $LAST"
    echo "Choose the next release:"
    echo "  1) $PATCH_VERSION  (patch, default)"
    echo "  2) $LATEST_MAJOR.$((LATEST_MINOR + 1))  (minor; tag v$MINOR_VERSION)"
    echo "  3) $((LATEST_MAJOR + 1)).0  (major; tag v$MAJOR_VERSION)"
    if [[ ! -t 0 ]]; then
        echo "✗ interactive version selection requires a terminal; pass X.Y.Z explicitly"
        exit 1
    fi
    if ! read -r -p "Selection [1]: " CHOICE; then
        echo
        echo "✗ no version selected"
        exit 1
    fi
    case "${CHOICE:-1}" in
        1|patch) VERSION="$PATCH_VERSION" ;;
        2|minor) VERSION="$MINOR_VERSION" ;;
        3|major) VERSION="$MAJOR_VERSION" ;;
        *) echo "✗ choose 1, 2, or 3"; exit 1 ;;
    esac
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ '$VERSION' is not X.Y.Z semver"; exit 1; }

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
mkdir -p build
ALOG="build/archive-$VERSION.log"
if ! xcodebuild -project SnapSiphon.xcodeproj -scheme SnapSiphon \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    GIT_COMMIT_HASH="$HASH" \
    archive >"$ALOG" 2>&1; then
    grep -E "error:" "$ALOG" | head -5
    echo "✗ archive failed — see $ALOG"
    exit 1
fi
[[ -d "$ARCHIVE" ]] || { echo "✗ archive missing"; exit 1; }
echo "✓ archived"

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
    ULOG="build/upload-$VERSION.log"
    if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportOptionsPlist scripts/ExportOptions.plist \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEYDIR/AuthKey_$KEY_ID.p8" \
        -authenticationKeyID "$KEY_ID" \
        -authenticationKeyIssuerID "$ISSUER_ID" \
        >"$ULOG" 2>&1; then
        grep -E "error:" "$ULOG" | head -5
        echo "✗ TestFlight upload FAILED — NOT tagging. Fix and re-run (see $ULOG)."
        exit 1
    fi
    echo "✓ uploaded to App Store Connect"
fi

git tag -a "v$VERSION" -m "SnapSiphon $VERSION (build $BUILD, $HASH)"
git push origin main "v$VERSION"
echo "✅ v$VERSION released — archive at $ARCHIVE"
