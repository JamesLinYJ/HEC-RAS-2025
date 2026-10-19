#!/usr/bin/env bash
set -euo pipefail
APP_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_SOURCE"
# Keep compiler intermediates in a per-checkout temporary cache.
# The packaged application stays in build/.
BUILD_CACHE_ID="$(printf '%s' "$APP_SOURCE" | shasum -a 256 | cut -c 1-16)"
SWIFT_SCRATCH_PATH="${HECRAS_SWIFT_SCRATCH_PATH:-${TMPDIR:-/private/tmp}/HECRAS2025Mac-$BUILD_CACHE_ID}"
swift build --scratch-path "$SWIFT_SCRATCH_PATH" -c release --product HECRAS2025
BIN_DIR="$(swift build --scratch-path "$SWIFT_SCRATCH_PATH" -c release --show-bin-path)"
APP_DIR="${HECRAS_APP_DIRECTORY:-$APP_SOURCE/build/HEC-RAS 2025.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/HECRAS2025" "$APP_DIR/Contents/MacOS/HECRAS2025"
cp -R "$APP_SOURCE/Sources/HECRAS2025/Resources/"*.lproj "$APP_DIR/Contents/Resources/"
# A shared SwiftPM cache also contains test fixture bundles after `swift test`.
# Only the executable target's runtime resources belong in the application.
RESOURCE_BUNDLE="$BIN_DIR/HECRAS2025Mac_HECRAS2025.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    printf 'Missing SwiftUI application resource bundle.\n' >&2
    exit 1
fi
rm -rf "$APP_DIR/Contents/Resources/HECRAS2025Mac_EditingTests.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
BACKEND_SOURCE="${HECRAS_BACKEND_SOURCE:-$APP_SOURCE/../backend/build/publish/osx-arm64}"
if [[ ! -x "$BACKEND_SOURCE/HECRASBackend" ]]; then
    printf 'Missing published backend. Run bash build-all.sh from the repository root first.\n' >&2
    exit 1
fi
BACKEND_STAGE="$(mktemp -d "$APP_DIR/Contents/Resources/.Backend.XXXXXX")"
ditto "$BACKEND_SOURCE" "$BACKEND_STAGE"
rm -rf "$APP_DIR/Contents/Resources/Backend" "$APP_DIR/Contents/Helpers/HECRASBackend"
mv "$BACKEND_STAGE" "$APP_DIR/Contents/Resources/Backend"
python3 - "$APP_DIR/Contents/Resources/Backend" <<'PY'
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
for path in sorted(root.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        is_macho = stream.read(4) in magic
    if is_macho:
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True)
PY
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HECRAS2025</string>
<key>CFBundleIdentifier</key><string>org.hecras2025.swiftui</string>
<key>CFBundleName</key><string>HEC-RAS 2025</string>
<key>CFBundleDisplayName</key><string>HEC-RAS 2025</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>HEC-RAS 2025 Project</string>
<key>CFBundleTypeExtensions</key><array><string>ras</string></array>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Alternate</string>
</dict><dict>
<key>CFBundleTypeName</key><string>HEC-RAS V6 Project</string>
<key>CFBundleTypeExtensions</key><array><string>prj</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
