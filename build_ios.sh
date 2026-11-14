#!/bin/bash
set -e

echo "=== 1. Membersihkan Sisa Build Lama & Mencadangkan Konfigurasi iOS ==="
rm -rf build/ios
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

echo "=== 4. Mengunduh Dependensi & Build iOS Release (No Codesign) ==="
flutter pub get
flutter build ios --release --no-codesign || true

echo "=== 5. Memverifikasi Kelengkapan Runner.app ==="
APP_PATH="build/ios/iphoneos/Runner.app"

if [ ! -f "$APP_PATH/Runner" ]; then
  echo "ERROR: Binary utama Runner.app/Runner tidak ditemukan. Cek pesan error Dart/Flutter di atas."
  exit 1
fi

if [ ! -d "$APP_PATH/Frameworks/Flutter.framework" ] || [ ! -d "$APP_PATH/Frameworks/App.framework" ]; then
  echo "ERROR: Flutter.framework atau App.framework tidak ditemukan di dalam Runner.app!"
  exit 1
fi

echo "Runner.app lengkap ditemukan di: $APP_PATH"
du -sh "$APP_PATH"

echo "=== 6. Mengemas & Memvalidasi Ukuran File .ipa ==="
mkdir -p build/ios/ipa/Payload
cp -r "$APP_PATH" build/ios/ipa/Payload/
cd build/ios/ipa
zip -ry CineLens_iOS.ipa Payload

IPA_SIZE_KB=$(du -k CineLens_iOS.ipa | cut -f1)
echo "Ukuran akhir CineLens_iOS.ipa: ${IPA_SIZE_KB} KB"

if [ "$IPA_SIZE_KB" -lt 5000 ]; then
  echo "ERROR: Ukuran .ipa terlalu kecil (${IPA_SIZE_KB} KB), hasil kompilasi tidak utuh!"
  exit 1
fi

echo "Build sukses dan valid: build/ios/ipa/CineLens_iOS.ipa"
