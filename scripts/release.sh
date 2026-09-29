#!/bin/bash
# Builds a Termstead release, ready to publish: signed with Developer ID,
# notarized and stapled, packed as a DMG, signed for Sparkle, with the appcast
# and the Homebrew cask that point at it.
#
#   scripts/release.sh 0.2.0
#   scripts/release.sh 0.2.0 --resume
#
# --resume picks up after an interrupted run: it reuses releases/<version>/export
# instead of archiving again. Apple can hold a submission for days, and a script
# left waiting that long gets killed; once the submission is accepted, --resume
# staples that very build without sending it again.
#
# Nothing is pushed or uploaded except to Apple's notary service. Everything
# lands in releases/<version>/; the script ends by listing what to publish.
#
# Needs, once per Mac:
#   - the "Developer ID Application" certificate in the login keychain;
#   - notarytool credentials saved as the keychain profile `termstead-notary`;
#   - Sparkle's EdDSA key in the login keychain (Sparkle's generate_keys).
# macOS may ask to let codesign and sign_update use those keys: allow it.
set -euo pipefail

VERSION="${1:-}"
RESUME="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ( -z "$RESUME" || "$RESUME" == --resume ) ]] \
    || { echo "usage: $0 <x.y.z> [--resume]" >&2; exit 1; }

TEAM=YHQLC8PBT3
NOTARY_PROFILE=termstead-notary
REPO=https://github.com/pkhorenyan/termstead
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/releases/$VERSION"
SPARKLE_BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }

# --- Version -----------------------------------------------------------------
# The build number is what Sparkle compares, so it only ever goes up: a new
# marketing version takes the next one.
step "Version $VERSION"
current=$(sed -nE 's/^ *MARKETING_VERSION: "(.*)"/\1/p' project.yml)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "(.*)"/\1/p' project.yml)
if [[ "$current" != "$VERSION" ]]; then
    build=$((build + 1))
    sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
    sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$build\"/" project.yml
fi
# README's version badge: its image and its alt text.
sed -i '' -E -e "s#(img\.shields\.io/badge/version-)[0-9.]+-#\1$VERSION-#" \
             -e "s#alt=\"Version [0-9.]+\"#alt=\"Version $VERSION\"#" README.md
echo "version $VERSION, build $build"

# --- Release notes -------------------------------------------------------------
# The Unreleased section of CHANGELOG.md becomes this version's, dated today,
# and an empty Unreleased goes back on top. Run again for the same version, it
# only moves the date to today.
step "Changelog"
python3 - "$VERSION" <<'EOF'
import datetime, pathlib, re, sys
version = sys.argv[1]
p = pathlib.Path("CHANGELOG.md"); s = p.read_text()
today = datetime.date.today()
if f"## [{version}]" not in s:
    s = s.replace("## [Unreleased]", f"## [Unreleased]\n\n## [{version}] - {today}", 1)
else:
    s = re.sub(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}", f"## [{version}] - {today}", s, flags=re.M)
p.write_text(s)
EOF

mkdir -p "$OUT"
python3 - "$VERSION" "$OUT/notes.html" <<'EOF'
import html, pathlib, re, sys
version, out = sys.argv[1], sys.argv[2]
s = pathlib.Path("CHANGELOG.md").read_text()
m = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", s, re.S | re.M)
body = m.group(1).strip() if m else ""
parts, item = [], None
def flush():
    global item
    if item is not None:
        parts.append(f"<li>{html.escape(item)}</li>"); item = None
for line in body.splitlines():
    if line.startswith("### "):
        flush(); parts.append(f"<h3>{html.escape(line[4:])}</h3>")
    elif line.startswith("- "):
        flush(); item = line[2:]
    elif line.startswith("  ") and item is not None:
        item += " " + line.strip()
    elif line.strip():
        flush(); parts.append(f"<p>{html.escape(line)}</p>")
flush()
text = "\n".join(parts)
text = re.sub(r"(<h3>[^<]*</h3>)\n((?:<li>.*</li>\n?)+)", lambda m: m.group(1) + "\n<ul>\n" + m.group(2).rstrip() + "\n</ul>\n", text)
pathlib.Path(out).write_text(text)
EOF

# --- Build and sign ----------------------------------------------------------
# An archive exported for Developer ID: the export re-signs everything nested
# (the askpass helper, Sparkle's installer and XPC services) with our identity,
# a secure timestamp and the hardened runtime, which notarization requires.
APP="$OUT/export/Termstead.app"
if [[ -n "$RESUME" ]]; then
step "Reuse the exported app"
[[ -d "$APP" ]] || { echo "nothing to resume: $APP is missing" >&2; exit 1; }
else
step "Archive"
xcodegen generate >/dev/null
xcodebuild -project Termstead.xcodeproj -scheme Termstead -configuration Release \
    -derivedDataPath build -archivePath "$OUT/Termstead.xcarchive" archive \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGNING_REQUIRED=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
    ENABLE_HARDENED_RUNTIME=YES \
    | grep -E "error:|warning:|ARCHIVE" || true
[[ -d "$OUT/Termstead.xcarchive" ]] || { echo "archive failed" >&2; exit 1; }

step "Export for Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
rm -rf "$OUT/export"
xcodebuild -exportArchive -archivePath "$OUT/Termstead.xcarchive" \
    -exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    | grep -E "error:|EXPORT" || true
[[ -d "$APP" ]] || { echo "export failed" >&2; exit 1; }
fi
codesign --verify --deep --strict "$APP"
# --verbose=2: without it codesign prints the timestamp but not the identity.
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID Application|Timestamp" | head -2

# --- Notarize ----------------------------------------------------------------
# The app first, so its own ticket can be stapled and it opens offline even
# outside the DMG (Homebrew copies it out); then the DMG around it.
step "Notarize the app"
# Gatekeeper asks Apple online, so an accepted build passes before it is stapled.
if spctl -a -t exec "$APP" 2>/dev/null; then
    echo "Apple has already accepted this build; stapling it."
else
    ditto -c -k --keepParent "$APP" "$OUT/Termstead.zip"
    xcrun notarytool submit "$OUT/Termstead.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm "$OUT/Termstead.zip"
fi
xcrun stapler staple "$APP"

step "DMG"
DMG="$OUT/Termstead.dmg"
staging=$(mktemp -d)
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$DMG"
hdiutil create -volname Termstead -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$staging"
codesign --sign "Developer ID Application" --timestamp "$DMG"

step "Notarize the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | head -2

# --- Sparkle appcast ---------------------------------------------------------
# One item, the newest: Sparkle only needs to know about the latest release.
# It is published as a release asset, so SUFeedURL's releases/latest/download
# always finds the current one.
step "Appcast"
signature=$("$SPARKLE_BIN/sign_update" "$DMG")
notes=$(cat "$OUT/notes.html")
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Termstead</title>
    <item>
      <title>Termstead $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
$notes
      ]]></description>
      <enclosure url="$REPO/releases/download/v$VERSION/Termstead.dmg" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
EOF

# --- Homebrew ----------------------------------------------------------------
step "Homebrew cask"
sha=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
cat > "$OUT/termstead.rb" <<EOF
cask "termstead" do
  version "$VERSION"
  sha256 "$sha"

  url "$REPO/releases/download/v#{version}/Termstead.dmg"
  name "Termstead"
  desc "Native SSH client with a session tree, jump hosts and SFTP"
  homepage "$REPO"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Termstead.app"

  zap trash: [
    "~/Library/Application Support/Termstead",
    "~/Library/Preferences/com.pavelkhorenyan.Termstead.plist",
  ]
end
EOF

step "Ready: releases/$VERSION"
cat <<EOF
To publish:
  1. Commit the version bump and CHANGELOG, tag v$VERSION, push.
  2. On GitHub, a release for tag v$VERSION with two files:
       releases/$VERSION/Termstead.dmg
       releases/$VERSION/appcast.xml
     Its notes: the $VERSION section of CHANGELOG.md.
  3. Copy releases/$VERSION/termstead.rb to Casks/ in homebrew-tap and push.
EOF
