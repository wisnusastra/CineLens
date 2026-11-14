#!/bin/bash
set -e

echo "=== 1. Bersihkan Build Lama & Cadangkan Konfigurasi iOS ==="
rm -rf build/ios
mkdir -p /tmp/ios_backup

if [ -f "ios/Runner/Info.plist" ]; then
  cp ios/Runner/Info.plist /tmp/ios_backup/Info.plist
fi

if [ -d "ios/Runner/Assets.xcassets" ]; then
  cp -r ios/Runner/Assets.xcassets /tmp/ios_backup/Assets.xcassets
fi

echo "=== 2. Siapkan Struktur Native iOS & Orientasi Landscape ==="
flutter create --platforms=ios .

if [ -f "/tmp/ios_backup/Info.plist" ]; then
  cp /tmp/ios_backup/Info.plist ios/Runner/Info.plist
else
  /usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 'CineLens membutuhkan akses kamera untuk merekam dan memotret.'" ios/Runner/Info.plist || true
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'CineLens membutuhkan akses mikrofon untuk merekam audio video.'" ios/Runner/Info.plist || true
  /usr/libexec/PlistBuddy -c "Add :NSPhotoLibraryAddUsageDescription string 'CineLens membutuhkan izin menyimpan foto dan video ke galeri.'" ios/Runner/Info.plist || true
fi

# Aktifkan Portrait, Landscape Left, dan Landscape Right pada iPhone
/usr/libexec/PlistBuddy -c "Delete :UISupportedInterfaceOrientations" ios/Runner/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations array" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationPortrait" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:1 string UIInterfaceOrientationLandscapeLeft" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:2 string UIInterfaceOrientationLandscapeRight" ios/Runner/Info.plist

if [ -d "/tmp/ios_backup/Assets.xcassets" ]; then
  rm -rf ios/Runner/Assets.xcassets
  cp -r /tmp/ios_backup/Assets.xcassets ios/Runner/Assets.xcassets
fi

sed -i '' 's/CODE_SIGN_STYLE = Automatic;/CODE_SIGN_STYLE = Manual;/g' ios/Runner.xcodeproj/project.pbxproj
sed -i '' 's/ProvisioningStyle = Automatic;/ProvisioningStyle = Manual;/g' ios/Runner.xcodeproj/project.pbxproj

echo "=== 3. Cek Dependensi, Kode Dart & Aset ==="
flutter pub get
flutter build bundle --release
flutter build ios --config-only --release --no-codesign

echo "=== 4. Kompilasi iOS Release (Unsigned) ==="
BUILD_OUTPUT_DIR="$(pwd)/build/ios"

xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  BUILD_DIR="$BUILD_OUTPUT_DIR" \
  VERBOSE_SCRIPT_LOGGING=YES \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build

echo "=== 5. Verifikasi Binary & Kemas File .ipa ==="
APP_PATH="$BUILD_OUTPUT_DIR/Release-iphoneos/Runner.app"

if [ ! -f "$APP_PATH/Runner" ] || [ ! -d "$APP_PATH/Frameworks/Flutter.framework" ]; then
  echo "ERROR: Runner.app tidak lengkap di $APP_PATH"
  exit 1
fi

mkdir -p "$BUILD_OUTPUT_DIR/ipa/Payload"
cp -r "$APP_PATH" "$BUILD_OUTPUT_DIR/ipa/Payload/"
cd "$BUILD_OUTPUT_DIR/ipa"
zip -ry CineLens_iOS.ipa Payload

IPA_SIZE_KB=$(du -k CineLens_iOS.ipa | cut -f1)
echo "Ukuran akhir CineLens_iOS.ipa: ${IPA_SIZE_KB} KB"

if [ "$IPA_SIZE_KB" -lt 5000 ]; then
  echo "ERROR: Ukuran .ipa terlalu kecil (${IPA_SIZE_KB} KB)."
  exit 1
fi

echo "SUKSES: build/ios/ipa/CineLens_iOS.ipa siap diunduh."
