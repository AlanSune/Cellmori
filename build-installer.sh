#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
APP="$ROOT/Cellmori.app"
[[ -x "$APP/Contents/MacOS/Cellmori" ]] || { echo '请先执行 bash build.sh'; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
PACKAGE_BASE="${CELLMORI_PACKAGE_WORK:-$ROOT/.installer-build}"
mkdir -p "$PACKAGE_BASE"
BUILD=$(mktemp -d "$PACKAGE_BASE/package.XXXXXX")
mkdir -p "$BUILD/root/Applications" "$BUILD/packages" "$BUILD/backend-scripts" "$BUILD/app-scripts"
ditto --norsrc "$APP" "$BUILD/root/Applications/Cellmori.app"
cp "$ROOT/Packaging/app-scripts/preinstall" "$BUILD/app-scripts/preinstall"
cp "$ROOT/Packaging/backend-scripts/postinstall" "$BUILD/backend-scripts/postinstall"
chmod 755 "$BUILD/app-scripts/preinstall" "$BUILD/backend-scripts/postinstall"
shasum -a 256 "$APP/Contents/Resources/cellmori-helper" | awk '{print $1}' > "$BUILD/backend-scripts/helper.sha256"
shasum -a 256 "$APP/Contents/Resources/install.sh" | awk '{print $1}' > "$BUILD/backend-scripts/install.sha256"
awk -F '"' '/^let expectedHelperVersion = / {print $2}' "$ROOT/Source/Shared.swift" > "$BUILD/backend-scripts/helper.version"
[[ -s "$BUILD/backend-scripts/helper.version" ]] || { echo '无法读取后台版本'; exit 1; }
cat > "$BUILD/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>Applications/Cellmori.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
pkgbuild --root "$BUILD/root" --install-location / --ownership recommended --component-plist "$BUILD/components.plist" --scripts "$BUILD/app-scripts" --identifier io.cellmori.installer.app --version "$VERSION" "$BUILD/packages/app.pkg"
pkgbuild --nopayload --scripts "$BUILD/backend-scripts" --identifier io.cellmori.installer.backend --version "$VERSION" "$BUILD/packages/backend.pkg"
sed "s/@VERSION@/$VERSION/g" "$ROOT/Packaging/Distribution.xml" > "$BUILD/Distribution.xml"
mkdir -p "$ROOT/dist"
OUTPUT="$ROOT/dist/Cellmori-$VERSION-arm64.pkg"
productbuild --distribution "$BUILD/Distribution.xml" --resources "$ROOT/Packaging/Resources" --package-path "$BUILD/packages" "$OUTPUT"
echo "Installer: $OUTPUT"
echo "Build files: $BUILD"
