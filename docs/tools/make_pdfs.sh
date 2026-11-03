#!/bin/zsh
# Rebuilds the manual's HTML from docs/USER_MANUAL.md, then prints the brochure and the manual
# to PDF with WebKit (no browser needed).
set -e
T="${0:A:h}"     # docs/tools
D="${T:h}"       # docs
APP="${TMPDIR:-/tmp}/KalshiBotHTML2PDF.app"
mkdir -p "$APP/Contents/MacOS" "${TMPDIR:-/tmp}/html2pdf-cache"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>html2pdf</string>
  <key>CFBundleIdentifier</key><string>com.imtheteam.kalshibot.html2pdf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -O -module-cache-path "${TMPDIR:-/tmp}/html2pdf-cache" "$T/html2pdf.swift" -o "$APP/Contents/MacOS/html2pdf"

python3 -I "$T/build_manual.py" "$D/USER_MANUAL.md" "$D/manual/Kalshi-Bot-User-Manual.html"
pdf() {
  rm -f "$2"
  open -W -n "$APP" --args "$1" "$2"
  [[ -s "$2" ]] && ls -la "$2" || { echo "failed: $2" >&2; exit 1; }
}
pdf "$D/brochure/Kalshi-Bot-Brochure.html" "$D/Kalshi-Bot-Brochure.pdf"
pdf "$D/manual/Kalshi-Bot-User-Manual.html" "$D/Kalshi-Bot-User-Manual.pdf"
