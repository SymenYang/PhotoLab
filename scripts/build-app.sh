#!/bin/zsh
set -eu
cd "${0:A:h:h}"
"${PHOTOLAB_BUILD_PYTHON:-python3}" scripts/build-redlamp-native.py
if [[ "${PHOTOLAB_DIRECT_BUILD:-0}" == "1" ]]; then
  mkdir -p build
  xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -whole-module-optimization -module-name PhotoLab -target arm64-apple-macosx26.3 -I Sources/CSQLite Sources/PhotoLab/*.swift -o build/PhotoLab-direct
  BINARY="build/PhotoLab-direct"
else
  swift build -c release
  BINARY=".build/release/PhotoLab"
fi
if [[ "${PHOTOLAB_DISTRIBUTION_BUILD:-0}" == "1" ]]; then
  APP="build/PhotoLab-Distribution.app"
else
  APP="build/PhotoLab.app"
fi
export PHOTOLAB_PACKAGE_APP="$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/ThirdParty/Redlamp"
ditto .build/redlamp-native/Frameworks "$APP/Contents/Frameworks"
cp Vendor/Redlamp/LICENSE Vendor/Redlamp/source.json "$APP/Contents/Resources/ThirdParty/Redlamp/"
cp .build/redlamp-native/LibRaw/*/LICENSE.CDDL "$APP/Contents/Resources/ThirdParty/Redlamp/LibRaw-LICENSE.CDDL"
cp .build/redlamp-native/LibRaw/*/COPYRIGHT "$APP/Contents/Resources/ThirdParty/Redlamp/LibRaw-COPYRIGHT"
zsh scripts/build-icon.sh
ICON_HASH="$(shasum -a 256 Resources/AppIcon.icns | cut -c 1-12)"
ICON_FILE="PhotoLabIcon-$ICON_HASH.icns"
cp Resources/AppIcon.icns "$APP/Contents/Resources/$ICON_FILE"
cp Resources/AppIcon.iconset/icon_512x512@2x.png "$APP/Contents/Resources/AppDockIcon.png"
BUILD_VERSION="1.$(date +%y%m%d).$(date +%H%M%S)"
cp "$BINARY" "$APP/Contents/MacOS/PhotoLab"
ditto Resources/Decorations "$APP/Contents/Resources/Decorations"
mkdir -p "$APP/Contents/Resources/AI"
rm -rf "$APP/Contents/Resources/AI/__pycache__"
cp AI/shared_worker.py AI/art_worker.py AI/worker.py AI/qwen_engine.py AI/qwen_coreml.py AI/fusion_engine.py AI/color_worker.py AI/install_model.py AI/jarvis_prompt.py AI/models.json AI/requirements.lock AI/scoring-requirements.lock AI/MODEL_DISTRIBUTION.md "$APP/Contents/Resources/AI/"
ditto AI/licenses "$APP/Contents/Resources/AI/licenses"
/usr/bin/python3 - <<'PYCONFIG'
import json, pathlib, os, hashlib, subprocess
root = pathlib.Path.cwd()
archive = root / "Vendor/Redlamp/vendor/color-tools.tar.gz"
metadata = json.loads(archive.with_suffix(".json").read_text())
if hashlib.sha256(archive.read_bytes()).hexdigest() != metadata["sha256"]:
    raise RuntimeError("ColorTools archive checksum mismatch")
target = root / os.environ["PHOTOLAB_PACKAGE_APP"] / "Contents/Resources/ColorTools"
target.mkdir(parents=True, exist_ok=True)
subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(target)], check=True)
(target / "source.json").write_text(json.dumps(metadata, indent=2))

PYCONFIG
CONFIG_ARGUMENTS=(--project "$PWD" --app "$APP")
if [[ "${PHOTOLAB_DISTRIBUTION_BUILD:-0}" == "1" ]]; then
  CONFIG_ARGUMENTS+=(--distribution)
fi
/usr/bin/python3 -B scripts/write-ai-config.py "${CONFIG_ARGUMENTS[@]}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PhotoLab</string>
<key>CFBundleDisplayName</key><string>PhotoLab</string>
<key>CFBundleIdentifier</key><string>local.photolab.app</string>
<key>CFBundleExecutable</key><string>PhotoLab</string>
<key>CFBundleIconFile</key><string>$ICON_FILE</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
<key>LSMinimumSystemVersion</key><string>26.3</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>PhotoLab</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
# Notify Launch Services that this in-place development build has changed.
touch "$APP"
if [[ "${PHOTOLAB_DISTRIBUTION_BUILD:-0}" != "1" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
echo "Built $APP"
