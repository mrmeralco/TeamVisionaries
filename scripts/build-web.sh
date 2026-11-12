#!/usr/bin/env bash
# Build the Solaris app for the web and publish it on the landing page at /app/.
#   bash scripts/build-web.sh
# Output: landing/app/ (committed, like the APK). The host laptop serves it at http://<laptop-ip>:8000/app/.
#
# --no-web-resources-cdn  CanvasKit is served from here, not Google's CDN: works on a hotspot with no internet
# SOLARIS_SAME_ORIGIN     the app talks to the server that served it (same host, port and http/https)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/landing/app"
TMP="$ROOT/app/build/web-hosted"

command -v flutter >/dev/null || { echo "Flutter is not installed (https://docs.flutter.dev/get-started/install)"; exit 1; }

cd "$ROOT/app"
flutter pub get
flutter build web --release --base-href /app/ --no-web-resources-cdn \
  --dart-define=SOLARIS_SAME_ORIGIN=true -o "$TMP"

rm -rf "$OUT"
cp -R "$TMP" "$OUT"
rm -f "$OUT/.last_build_id"
# This is a dart2js build on the CanvasKit renderer (see flutter_bootstrap.js buildConfig): it loads
# canvaskit/canvaskit.* or canvaskit/chromium/canvaskit.* only. Drop the WebAssembly-build renderers
# (skwasm, wimp), the experimental one and the debug symbols: ~25 MB the repo doesn't need.
rm -rf "$OUT"/canvaskit/skwasm* "$OUT"/canvaskit/wimp* "$OUT"/canvaskit/experimental_webparagraph
find "$OUT" -name '*.symbols' -delete

echo
echo "  Web app  landing/app/  ($(du -sh "$OUT" | cut -f1))"
echo "  Next: git add -A landing/app && git commit -m 'Web app build' && git push"
