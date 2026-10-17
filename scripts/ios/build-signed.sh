#!/bin/bash
set -euo pipefail
umask 077

: "${APPLE_SIGNING_KEYCHAIN_PATH:?Run through apple-signing-lane}"
: "${APPLE_SIGNING_IDENTITY_SHA1:?Run through apple-signing-lane}"
: "${APPLE_SIGNING_ARTIFACTS_FILE:?Run through apple-signing-lane}"

build_number="${1:?build number}"
output_dir="${2:?absolute output directory}"
source_revision="${3:?source revision}"
profile_uuid="${4:?existing profile UUID}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]]
[[ "$source_revision" =~ ^[0-9a-f]{40}$ ]]
[[ "$profile_uuid" =~ ^[0-9A-Fa-f-]{36}$ ]]
case "$output_dir" in /tmp/remux-ota-*|/private/tmp/remux-ota-*) ;; *) exit 2 ;; esac

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test "$(git -C "$repo_dir" rev-parse HEAD)" = "$source_revision"
profile="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$profile_uuid.mobileprovision"
test -f "$profile" && test ! -L "$profile"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$repo_dir"

xcodebuild build -project Remux.xcodeproj -scheme Remux \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$output_dir/DerivedData" -jobs 4 \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$build_number" \
  COMPILER_INDEX_STORE_ENABLE=NO

mkdir -p "$output_dir/Payload"
app_path="$output_dir/Payload/Remux.app"
/usr/bin/ditto "$output_dir/DerivedData/Build/Products/Release-iphoneos/Remux.app" "$app_path"
cp "$profile" "$app_path/embedded.mobileprovision"
entitlements="$APPLE_SIGNING_RUN_DIR/entitlements.plist"
/usr/bin/python3 - "$entitlements" "$APPLE_SIGNING_TEAM_ID" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'application-identifier': sys.argv[2]+'.com.davidjson.remux',
                  'com.apple.developer.team-identifier': sys.argv[2],
                  'get-task-allow': True}, f)
PY

signer=(/usr/bin/codesign --force --sign "$APPLE_SIGNING_IDENTITY_SHA1"
  --keychain "$APPLE_SIGNING_KEYCHAIN_PATH" --timestamp=none)
while IFS= read -r -d '' code_path; do
  "${signer[@]}" "$code_path"
done < <(find "$app_path" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
"${signer[@]}" --entitlements "$entitlements" --generate-entitlement-der "$app_path"
/usr/bin/python3 - "$APPLE_SIGNING_ARTIFACTS_FILE" "$app_path" <<'PY'
import json,sys
with open(sys.argv[1], 'w') as f:
    json.dump({'schemaVersion':1, 'artifacts':[{'id':'app','path':sys.argv[2]}]},f)
PY
