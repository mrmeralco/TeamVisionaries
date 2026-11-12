#!/usr/bin/env bash
# Build the Solaris Android app and publish it on the landing page.
#   bash scripts/build-apk.sh
# Puts the release APK at landing/downloads/solaris.apk and its details in landing/downloads/latest.json.
# Commit both and push: the host laptop just pulls and serves them (http://<laptop-ip>:8000/apk).
#
# ARM only (every real Android phone): x86_64 is for emulators and would add ~18 MB to the repo per build.
# The app has no server address built in; the phone types the laptop's address in Settings
# (the landing page shows it when it is served by the Solaris server).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/landing/downloads"

command -v flutter >/dev/null || { echo "Flutter is not installed (https://docs.flutter.dev/get-started/install)"; exit 1; }

cd "$ROOT/app"
flutter pub get
flutter build apk --release --target-platform android-arm,android-arm64

APK="$ROOT/app/build/app/outputs/flutter-apk/app-release.apk"
mkdir -p "$OUT"
cp "$APK" "$OUT/solaris.apk"

VERSION=$(sed -nE 's/^version:[[:space:]]*([^+[:space:]]+).*/\1/p' pubspec.yaml)
SIZE=$(wc -c < "$OUT/solaris.apk" | tr -d ' ')
SHA=$(shasum -a 256 "$OUT/solaris.apk" | cut -d' ' -f1)
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILT=$(date +%Y-%m-%d)
cat > "$OUT/latest.json" <<EOF
{
  "file": "solaris.apk",
  "version": "$VERSION",
  "size_bytes": $SIZE,
  "sha256": "$SHA",
  "built": "$BUILT",
  "commit": "$COMMIT"
}
EOF

echo
echo "  APK  landing/downloads/solaris.apk  ($(( SIZE / 1048576 )) MB, version $VERSION)"
echo "  Next: git add landing/downloads && git commit -m 'APK $VERSION' && git push"
