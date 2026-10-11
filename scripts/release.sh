#!/bin/bash
# Release preparation is local-only. Publishing is a separate, explicit action.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="driveclue/DriveClue"
APP_NAME="DriveClue"
BUNDLE_ID="com.trantuan.driveclue"
TEAM_ID="R3YX83R9RQ"
PUBLIC_KEY="mwTWSAi4FYAOlIGHncqA8MniPfH5V9Kra9bDqfoGeZI="
REQUIRED_ARCHS="arm64 x86_64"
TOOLS="$ROOT/build/sparkle-tools/bin"
# Convenience copy of the final DMG for manual distribution (gitignored).
RELEASES_DIR="$ROOT/releases"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'usage: scripts/release.sh preflight VERSION' \
    '       scripts/release.sh prepare VERSION --notarize PROFILE [--notes FILE]' \
    '       scripts/release.sh publish-draft VERSION --confirm vVERSION' \
    '       scripts/release.sh publish VERSION --confirm vVERSION' >&2
  exit 2
}
[ $# -ge 2 ] || usage
ACTION="$1"; VERSION="$2"; shift 2
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'VERSION must be a bare MAJOR.MINOR.PATCH version'
TAG="v$VERSION"
OUT="$ROOT/build/release/$VERSION"
ZIP="$OUT/$APP_NAME-$VERSION.zip"
FEED="$OUT/appcast.xml"
MANIFEST="$OUT/manifest.json"
NOTES="$OUT/notes.html"
# The DMG name includes the build number, so it is set once BUILD is known (set_dmg_paths).
DMG_NAME=""
DMG=""
PROFILE=""
NOTES_INPUT=""
CONFIRM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notarize) [ $# -ge 2 ] || usage; PROFILE="$2"; shift 2 ;;
    --notes) [ $# -ge 2 ] || usage; NOTES_INPUT="$2"; shift 2 ;;
    --confirm) [ $# -ge 2 ] || usage; CONFIRM="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$ACTION" in
  preflight) [ -z "$PROFILE$NOTES_INPUT$CONFIRM" ] || usage ;;
  prepare) [ -n "$PROFILE" ] && [ -z "$CONFIRM" ] || usage ;;
  publish-draft|publish) [ -z "$PROFILE$NOTES_INPUT" ] && [ "$CONFIRM" = "$TAG" ] || usage ;;
  *) usage ;;
esac
cd "$ROOT"

require() { command -v "$1" >/dev/null || fail "missing tool: $1"; }
require git
require python3
require xcrun
require security
require spctl
require tar
require cmp
require codesign
require ditto
require lipo
require diskutil
require hdiutil
require xcodebuild
require xcodegen
require swift
require swiftlint
require plutil
require gh
require curl

# The version must already be committed: a release archive is built from exactly
# this commit, not from a mutable checkout or a script-generated version bump.
source_checks() {
  [ -z "$(git status --porcelain --untracked-files=all)" ] || fail 'working tree is not clean (including untracked files); commit or remove changes first'
  [ "$(git branch --show-current)" = main ] || fail 'release must start on main'
  [ "$(git remote get-url origin)" = "https://github.com/$REPO.git" ] || fail 'unexpected origin remote'
  git fetch --quiet origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail 'HEAD must equal origin/main'
  [ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || fail "tag $TAG already exists"
  [ -z "$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id 2>/dev/null || true)" ] || fail "release $TAG already exists"
  local current previous build previous_version
  current="$(python3 -c 'import re; s=open("project.yml").read(); m=re.findall(r"^\s*MARKETING_VERSION: [\x27\"]([^\x27\"]+)[\x27\"]",s,re.M); print(m[0] if len(m)==1 else "")')"
  build="$(python3 -c 'import re; s=open("project.yml").read(); m=re.findall(r"^\s*CURRENT_PROJECT_VERSION: [\x27\"]([0-9]+)[\x27\"]",s,re.M); print(m[0] if len(m)==1 else "")')"
  [ "$current" = "$VERSION" ] || fail "project.yml MARKETING_VERSION must be $VERSION (currently $current)"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] || fail 'CURRENT_PROJECT_VERSION must be a positive integer'
  previous="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse('appcast.xml').getroot()
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = root.findall('./channel/item')
print(max((int(item.findtext('sparkle:version', namespaces=ns)) for item in items), default=0))
PY
)"
  [ "$build" -gt "$previous" ] || fail "build $build must exceed latest feed build $previous"
  previous_version="$(git tag -l 'v[0-9]*' --sort=-version:refname | sed -n '1s/^v//p')"
  if [ -n "$previous_version" ]; then
    VERSION="$VERSION" PREVIOUS_VERSION="$previous_version" python3 - <<'PY' || fail "version $VERSION must exceed existing local tag v$previous_version"
import os
from itertools import zip_longest
new = tuple(int(n) for n in os.environ['VERSION'].split('.'))
old = tuple(int(n) for n in os.environ['PREVIOUS_VERSION'].split('.'))
assert new > old
PY
  fi
  BUILD="$build"
  set_dmg_paths
  SOURCE_COMMIT="$(git rev-parse HEAD)"
  printf 'Source %s; version %s (build %s); no existing tag/release.\n' "$SOURCE_COMMIT" "$VERSION" "$BUILD"
}

check_app() {
  local app="$1" value identity
  [ -d "$app" ] || fail "app missing: $app"
  codesign --verify --deep --strict --verbose=2 "$app" || fail 'code signature invalid'
  identity="$(codesign -dv --verbose=2 "$app" 2>&1)"
  [[ "$identity" == *"Authority=Developer ID Application:"* ]] || fail 'app is not Developer ID Application signed'
  [[ "$identity" == *"TeamIdentifier=$TEAM_ID"* ]] || fail 'wrong signing team'
  [[ "$identity" == *"flags=0x10000(runtime)"* ]] || fail 'hardened runtime missing'
  value="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  [ "$value" = "$BUNDLE_ID" ] || fail 'wrong bundle ID'
  value="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  [ "$value" = "$VERSION" ] || fail 'wrong marketing version'
  value="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  [ "$value" = "$BUILD" ] || fail 'wrong build number'
  value="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
  [ "$value" = "$PUBLIC_KEY" ] || fail 'wrong Sparkle public key'
  check_universal "$app"
  xcrun stapler validate "$app" || fail 'notarization ticket missing/invalid'
  spctl --assess --type execute --verbose "$app" || fail 'Gatekeeper rejected app'
}

set_dmg_paths() {
  DMG_NAME="driveclue_${VERSION}_build_${BUILD}_universal.dmg"
  DMG="$OUT/$DMG_NAME"
}

# Every Mach-O in the bundle (app, Sparkle, XPC helpers) must run on Intel and Apple Silicon.
check_universal() {
  local app="$1" binary archs arch
  while IFS= read -r binary; do
    archs="$(lipo -archs "$binary" 2>/dev/null)" || continue
    for arch in $REQUIRED_ARCHS; do
      [[ " $archs " == *" $arch "* ]] || fail "${binary#"$app"/} is missing $arch (has: $archs)"
    done
  done < <(find "$app" -type f -perm +111)
}

# Build a compressed DMG holding the stapled app and an /Applications shortcut.
make_dmg() {
  local app="$1" staging="$OUT/dmg-staging"
  rm -rf "$staging"
  mkdir "$staging"
  ditto "$app" "$staging/$APP_NAME.app"
  ln -s /Applications "$staging/Applications"
  # `diskutil image` replaces the deprecated `hdiutil create` on newer macOS.
  if diskutil image create from -h >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "$APP_NAME $VERSION" "$staging" "$DMG" >/dev/null
  else
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
  fi
  rm -rf "$staging"
  codesign --sign "$(dev_id_identity)" --timestamp "$DMG"
}

# Full name of the team's Developer ID Application identity, e.g. "Developer ID Application: Name (TEAM)".
dev_id_identity() {
  security find-identity -v -p codesigning | grep -F 'Developer ID Application' | grep -F "($TEAM_ID)" | head -1 | sed -E 's/.*"(.*)"/\1/'
}

# Mount the DMG read-only and verify it exactly as a user would receive it.
check_dmg() {
  local dmg="$1" mount status identity
  codesign --verify --strict --verbose=2 "$dmg" || fail 'DMG signature invalid'
  identity="$(codesign -dv --verbose=2 "$dmg" 2>&1)"
  [[ "$identity" == *"Authority=Developer ID Application:"* ]] || fail 'DMG is not Developer ID Application signed'
  [[ "$identity" == *"TeamIdentifier=$TEAM_ID"* ]] || fail 'DMG signed by wrong team'
  xcrun stapler validate "$dmg" || fail 'DMG notarization ticket missing/invalid'
  spctl --assess --type open --context context:primary-signature --verbose "$dmg" || fail 'Gatekeeper rejected DMG'
  mount="$(mktemp -d "$OUT/mount.XXXXXX")"
  if diskutil image attach -h >/dev/null 2>&1; then
    diskutil image attach --readOnly --nobrowse --mountPoint "$mount" "$dmg" >/dev/null
  else
    hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
  fi
  # Subshell: always detach, even when a check fails.
  (
    [ -L "$mount/Applications" ] || fail 'DMG is missing the Applications shortcut'
    check_app "$mount/$APP_NAME.app"
  ) && status=0 || status=$?
  diskutil eject "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
  rmdir "$mount" 2>/dev/null || true
  [ "$status" = 0 ] || exit "$status"
}

notarize() {
  local file="$1" log="$2"
  printf 'Notarizing %s (usually a few minutes)...\n' "$(basename "$file")"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$log"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("status")=="Accepted" else "Notarization not accepted: " + str(d))' "$log"
}

verify_bundle() {
  [ -f "$MANIFEST" ] && [ -f "$ZIP" ] && [ -f "$FEED" ] && [ -f "$NOTES" ] || fail 'missing prepared files; run prepare first'
  BUILD="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$MANIFEST")"
  set_dmg_paths
  [ -f "$DMG" ] || fail "missing prepared DMG $DMG; rerun prepare"
  VERSION="$VERSION" ZIP="$ZIP" DMG="$DMG" FEED="$FEED" NOTES="$NOTES" MANIFEST="$MANIFEST" python3 - <<'PY'
import hashlib, json, os, pathlib, sys, xml.etree.ElementTree as ET
p = pathlib.Path
m = json.loads(p(os.environ['MANIFEST']).read_text())
if m.get('dmg_name') != p(os.environ['DMG']).name:
    sys.exit('prepared DMG name mismatch')
for key, filename in [('archive_sha256', 'ZIP'), ('dmg_sha256', 'DMG'), ('feed_sha256', 'FEED'), ('notes_sha256', 'NOTES')]:
    if hashlib.sha256(p(os.environ[filename]).read_bytes()).hexdigest() != m[key]:
        sys.exit(f'{filename} changed since prepare')
if m['version'] != os.environ['VERSION'] or p(os.environ['ZIP']).stat().st_size != m['length']:
    sys.exit('prepared version/size mismatch')
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
item = next((i for i in ET.parse(os.environ['FEED']).findall('./channel/item') if i.findtext('s:shortVersionString', namespaces=ns) == m['version']), None)
if item is None or item.findtext('s:version', namespaces=ns) != str(m['build']):
    sys.exit('prepared feed version mismatch')
e = item.find('enclosure')
if e is None or e.get('{%s}edSignature' % ns['s']) != m['signature'] or e.get('length') != str(m['length']) or e.get('url') != m['url']:
    sys.exit('prepared feed enclosure mismatch')
PY
  SOURCE_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$MANIFEST")"
  URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$MANIFEST")"
}

remote_tag_matches() {
  [ "$(git ls-remote origin "refs/tags/$TAG" | cut -f1)" = "$SOURCE_COMMIT" ] || fail "remote tag $TAG does not point to prepared source $SOURCE_COMMIT"
}

verify_draft_asset() {
  local meta tmp file name
  meta="$(gh release view "$TAG" --repo "$REPO" --json isDraft,isPrerelease,assets --jq '.isDraft, .isPrerelease, (.assets[] | [.name, .size] | @tsv)')"
  [ "$(printf '%s\n' "$meta" | grep -Fxc true)" = 2 ] || fail 'release is not a draft pre-release'
  tmp="$(mktemp -d "$OUT/download.XXXXXX")"
  for file in "$ZIP" "$DMG"; do
    name="$(basename "$file")"
    printf '%s\n' "$meta" | grep -Fxq "$name$(printf '\t')$(stat -f %z "$file")" || fail "draft asset $name missing or has wrong size"
    gh release download "$TAG" --repo "$REPO" --pattern "$name" --dir "$tmp"
    cmp "$file" "$tmp/$name" || fail "draft asset $name differs from prepared file"
  done
  rm -rf "$tmp"
}

case "$ACTION" in
  preflight)
    source_checks
    printf 'Preflight passed; no source or remote changes made.\n'
    ;;
  prepare)
    source_checks
    [ -z "$NOTES_INPUT" ] || [ -f "$NOTES_INPUT" ] || fail 'notes file not found'
    [ -x "$TOOLS/sign_update" ] && [ -x "$TOOLS/generate_keys" ] || fail 'install pinned Sparkle CLI tools in build/sparkle-tools/bin (see RELEASE_NOTES.md)'
    [ "$("$TOOLS/generate_keys" -p)" = "$PUBLIC_KEY" ] || fail 'Sparkle keychain public key differs from embedded key'
    security find-identity -v -p codesigning | grep -Fq "$TEAM_ID" || fail 'Developer ID signing identity missing'
    [ ! -e "$OUT" ] || fail "prepared directory already exists: $OUT (remove manually only after reviewing it)"
    mkdir -p "$OUT/source"
    # Copy only committed source into isolation: xcodegen never edits the shared project.
    git archive "$SOURCE_COMMIT" | tar -x -C "$OUT/source"
    printf '==> Tests and lint\n'
    swift test --package-path "$OUT/source/DriveClueCore"
    (cd "$OUT/source" && swiftlint lint --strict)
    printf '==> Unsigned build\n'
    (cd "$OUT/source" && xcodegen generate && xcodebuild -project DriveClue.xcodeproj -scheme DriveClue -configuration Release -destination 'platform=macOS' -derivedDataPath "$OUT/unsigned" CODE_SIGNING_ALLOWED=NO build)
    printf '==> Developer ID signed build\n'
    (cd "$OUT/source" && xcodebuild -project DriveClue.xcodeproj -scheme DriveClue -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$OUT/signed" ARCHS="$REQUIRED_ARCHS" ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application' DEVELOPMENT_TEAM="$TEAM_ID" build)
    APP="$OUT/signed/Build/Products/Release/$APP_NAME.app"
    codesign --verify --deep --strict "$APP"
    check_universal "$APP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    printf '==> Submit app for notarization\n'
    notarize "$ZIP" "$OUT/notary.json"
    xcrun stapler staple "$APP"
    check_app "$APP"
    rm "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    # Verify the actual archive, not just the build directory.
    mkdir "$OUT/extracted"
    ditto -x -k "$ZIP" "$OUT/extracted"
    check_app "$OUT/extracted/$APP_NAME.app"
    # DMG for first-time downloads; Sparkle updates keep using the ZIP.
    printf '==> Build, sign and notarize DMG\n'
    make_dmg "$APP"
    notarize "$DMG" "$OUT/notary-dmg.json"
    xcrun stapler staple "$DMG"
    check_dmg "$DMG"
    SIGN_OUTPUT="$("$TOOLS/sign_update" "$ZIP")"
    export SIGN_OUTPUT
    if [ -n "$NOTES_INPUT" ]; then
      cp "$NOTES_INPUT" "$NOTES"
    else
      printf 'See the release notes at https://github.com/%s/releases/tag/%s\n' "$REPO" "$TAG" > "$NOTES"
    fi
    SOURCE_COMMIT="$SOURCE_COMMIT" BUILD="$BUILD" VERSION="$VERSION" REPO="$REPO" APP_NAME="$APP_NAME" ZIP="$ZIP" DMG="$DMG" FEED="$FEED" NOTES="$NOTES" MANIFEST="$MANIFEST" python3 - <<'PY'
import datetime, hashlib, json, os, pathlib, re, xml.etree.ElementTree as ET
p = pathlib.Path
sign = os.environ['SIGN_OUTPUT']
sig = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', sign)
size = re.search(r'length="([0-9]+)"', sign)
assert sig and size, f'Unexpected sign_update output: {sign}'
zipfile = p(os.environ['ZIP'])
assert int(size.group(1)) == zipfile.stat().st_size
version = os.environ['VERSION']
build = int(os.environ['BUILD'])
url = f"https://github.com/{os.environ['REPO']}/releases/download/v{version}/{os.environ['APP_NAME']}-{version}.zip"
feed = p(os.environ['FEED'])
original = p('appcast.xml').read_text()
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
root = ET.fromstring(original)
assert not any(i.findtext('s:shortVersionString', namespaces=ns) == version for i in root.findall('./channel/item')), 'feed already has version'
notes = p(os.environ['NOTES']).read_text()
item = f'''    <item>
      <title>DriveClue {version}</title>
      <link>https://github.com/{os.environ['REPO']}</link>
      <pubDate>{datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <enclosure url="{url}" length="{size.group(1)}" type="application/octet-stream" sparkle:edSignature="{sig.group(1)}" />
      <description><![CDATA[{notes.replace(']]>', ']]]]><![CDATA[>')}]]></description>
    </item>
'''
marker = '    <item>' if '    <item>' in original else '  </channel>'
assert marker in original
feed.write_text(original.replace(marker, item + marker, 1))
ET.parse(feed)
def sha(path): return hashlib.sha256(p(path).read_bytes()).hexdigest()
manifest = {'version': version, 'build': build, 'source_commit': os.environ['SOURCE_COMMIT'], 'signature': sig.group(1), 'length': zipfile.stat().st_size, 'url': url, 'archive_sha256': sha(zipfile), 'dmg_name': p(os.environ['DMG']).name, 'dmg_sha256': sha(os.environ['DMG']), 'feed_sha256': sha(feed), 'notes_sha256': sha(os.environ['NOTES'])}
p(os.environ['MANIFEST']).write_text(json.dumps(manifest, indent=2) + '\n')
PY
    verify_bundle
    mkdir -p "$RELEASES_DIR"
    cp "$DMG" "$RELEASES_DIR/$DMG_NAME"
    printf 'Prepared in %s (source %s). No commit, tag, upload, or publication performed.\n' "$OUT" "$SOURCE_COMMIT"
    printf 'DMG copy: releases/%s\n' "$DMG_NAME"
    ;;
  publish-draft)
    verify_bundle
    source_checks
    [ "$(git rev-parse HEAD)" = "$SOURCE_COMMIT" ] || fail 'HEAD differs from prepared source'
    [ "$BUILD" = "$(python3 -c 'import re; print(re.search(r"CURRENT_PROJECT_VERSION: [\x27\"]([0-9]+)",open("project.yml").read()).group(1))')" ] || fail 'build changed since prepare'
    printf '==> Explicitly authorized: create tag %s at %s and upload draft\n' "$TAG" "$SOURCE_COMMIT"
    gh api -X POST "repos/$REPO/git/refs" -f "ref=refs/tags/$TAG" -f "sha=$SOURCE_COMMIT" >/dev/null
    remote_tag_matches
    gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPO" --verify-tag --draft --prerelease --title "$APP_NAME $VERSION" --notes-file "$NOTES"
    verify_draft_asset
    printf 'Draft verified. Publish the verified pre-release only after separate authorization; stage the prepared feed after the asset is public.\n'
    ;;
  publish)
    verify_bundle
    git fetch --quiet origin main
    [ -z "$(git status --porcelain --untracked-files=all)" ] || fail 'working tree must be clean'
    [ "$(git branch --show-current)" = main ] || fail 'release must publish from main'
    [ "$(git remote get-url origin)" = "https://github.com/$REPO.git" ] || fail 'unexpected origin remote'
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail 'HEAD must equal origin/main'
    [ "$(git rev-parse HEAD)" = "$SOURCE_COMMIT" ] || fail 'source changed since prepare; publish the exact prepared source first'
    remote_tag_matches
    verify_draft_asset
    printf '==> Explicitly authorized: make verified pre-release %s downloadable\n' "$TAG"
    gh release edit "$TAG" --repo "$REPO" --draft=false
    gh release view "$TAG" --repo "$REPO" --json isDraft,isPrerelease --jq '[.isDraft, .isPrerelease] | @tsv' | grep -Fxq "false$(printf '\t')true" || fail 'release did not become a public pre-release'
    curl --fail --location --silent --show-error --retry 5 --retry-delay 2 "$URL" -o "$OUT/public-download.zip" || fail 'public archive is not downloadable'
    cmp "$ZIP" "$OUT/public-download.zip" || fail 'public archive differs from prepared archive'
    rm "$OUT/public-download.zip"
    curl --fail --location --silent --show-error --retry 5 --retry-delay 2 "https://github.com/$REPO/releases/download/$TAG/$DMG_NAME" -o "$OUT/public-download.dmg" || fail 'public DMG is not downloadable'
    cmp "$DMG" "$OUT/public-download.dmg" || fail 'public DMG differs from prepared DMG'
    rm "$OUT/public-download.dmg"
    printf 'Pre-release and public downloads verified. Separately authorize the prepared feed commit and push.\n'
    ;;
esac
