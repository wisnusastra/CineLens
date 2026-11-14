#!/bin/bash
set -e

echo "=== 1. Mencadangkan Konfigurasi Native iOS, App Icon, & Splash Screen ==="
mkdir -p /tmp/ios_backup

if [ -f "ios/Runner/Info.plist" ]; then
  cp ios/Runner/Info.plist /tmp/ios_backup/Info.plist
  echo "Info.plist ditemukan dan dicadangkan."
else
  echo "Folder ios/ belum ada di repo, akan dibuat otomatis oleh Flutter."
fi

if [ -d "ios/Runner/Assets.xcassets" ]; then
  cp -r ios/Runner/Assets.xcassets /tmp/ios_backup/Assets.xcassets
fi

echo "=== 2. Membuat Ulang Struktur Native iOS ==="
flutter create --platforms=ios .

echo "=== 3. Memulihkan atau Mengatur Konfigurasi Info.plist ==="
if [ -f "/tmp/ios_backup/Info.plist" ]; then
  cp /tmp/ios_backup/Info.plist ios/Runner/Info.plist
else
  /usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 'CineLens membutuhkan akses kamera untuk merekam dan memotret.'" ios/Runner/Info.plist || true
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'CineLens membutuhkan akses mikrofon untuk merekam audio video.'" ios/Runner/Info.plist || true
  /usr/libexec/PlistBuddy -c "Add :NSPhotoLibraryAddUsageDescription string 'CineLens membutuhkan izin menyimpan foto dan video ke galeri.'" ios/Runner/Info.plist || true
fi

if [ -d "/tmp/ios_backup/Assets.xcassets" ]; then
  rm -rf ios/Runner/Assets.xcassets
  cp -r /tmp/ios_backup/Assets.xcassets ios/Runner/Assets.xcassets
fi

echo "=== 4. Mengunduh Dependensi & Menyiapkan Konfigurasi Xcode ==="
flutter pub get
flutter build ios --config-only --release --no-codesign

echo "=== 5. Build iOS Tanpa Code Signing via xcodebuild ==="
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/ios_xcode \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  build

echo "=== 6. Mengemas File .ipa ==="
mkdir -p build/ios/ipa/Payload
cp -r build/ios_xcode/Build/Products/Release-iphoneos/Runner.app build/ios/ipa/Payload/
cd build/ios/ipa
zip -r CineLens_iOS.ipa Payload
echo "Build selesai: build/ios/ipa/CineLens_iOS.ipa"
