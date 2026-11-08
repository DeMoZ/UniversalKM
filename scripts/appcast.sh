#!/bin/zsh
# Signs the update archive for Sparkle and writes build/appcast.xml, the feed the app checks for updates
# (published as a release asset, so releases/latest/download/appcast.xml is always the newest one).
#   scripts/appcast.sh build/UniversalKM-0.1.0.zip
# The EdDSA private key comes from $SPARKLE_PRIVATE_KEY (the Release workflow's secret), else from the login
# keychain (account "UniversalKM", made with Sparkle's generate_keys). Its public half is SUPublicEDKey in
# Resources/Info.plist. The key is never printed.
set -euo pipefail

root=${0:A:h:h}
cd "$root"

zip=$1
plist=Resources/Info.plist
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $plist)
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $plist)
minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" $plist)
repo=https://github.com/DeMoZ/UniversalKM

sign_update=$(find .build/artifacts -path "*/Sparkle/bin/sign_update" -type f | head -1)
[[ -n "$sign_update" ]] || { echo "sign_update not found: build the app first (swift build fetches Sparkle)"; exit 1; }
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$zip")
else
  signature=$("$sign_update" --account UniversalKM "$zip")
fi
# sign_update prints: sparkle:edSignature="…" length="…"
[[ "$signature" == *edSignature=* ]] || { echo "Signing failed"; exit 1; }

# The release notes, as simple HTML for Sparkle's update window (up to "## Установка").
notes=$(python3 -I - "docs/releases/v$version.md" <<'EOF'
import html, re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except FileNotFoundError:
    text = ""
text = re.split(r"^## (?:Установка|Install)", text, flags=re.M)[0].strip()
def inline(s):
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", s)
out = []
for block in re.split(r"\n\s*\n", text):
    lines = [l.strip() for l in block.splitlines() if l.strip()]
    if not lines or lines[0].startswith("# "):
        continue
    if lines[0].startswith("## "):
        out.append(f"<h3>{inline(lines[0][3:])}</h3>")
    elif lines[0].startswith("- "):
        items, current = [], []
        for l in lines:
            if l.startswith("- ") and current:
                items.append(" ".join(current)); current = []
            current.append(l[2:] if l.startswith("- ") else l)
        items.append(" ".join(current))
        out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
    else:
        out.append(f"<p>{inline(' '.join(lines))}</p>")
print("\n".join(out))
EOF
)

mkdir -p build
cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>UniversalKM</title>
    <link>$repo</link>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$repo/releases</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$notes
      ]]></description>
      <enclosure url="$repo/releases/download/v$version/${zip:t}" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
EOF
echo "Wrote $root/build/appcast.xml (${zip:t}, version $version, build $build)"
