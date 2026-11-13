#!/usr/bin/env bash
set -e

echo "=== 1. Mencadangkan Konfigurasi Native iOS, App Icon, & Splash Screen ==="
mkdir -p /tmp/cinelens_ios_backup
cp ios/Runner/Info.plist /tmp/cinelens_ios_backup/Info.plist
cp ios/Runner/AppDelegate.swift /tmp/cinelens_ios_backup/AppDelegate.swift
cp ios/Runner/Base.lproj/LaunchScreen.storyboard /tmp/cinelens_ios_backup/LaunchScreen.storyboard
cp -R ios/Runner/Assets.xcassets/AppIcon.appiconset /tmp/cinelens_ios_backup/AppIcon.appiconset

echo "=== 2. Membangkitkan Kerangka Proyek Xcode iOS ==="
flutter create . --platforms=ios --org com.cinelens --project-name cinelens_ios

echo "=== 3. Memulihkan Native Bridge, Cinema App Icon, & Dark LaunchScreen ==="
cp /tmp/cinelens_ios_backup/Info.plist ios/Runner/Info.plist
cp /tmp/cinelens_ios_backup/AppDelegate.swift ios/Runner/AppDelegate.swift
mkdir -p ios/Runner/Base.lproj
cp /tmp/cinelens_ios_backup/LaunchScreen.storyboard ios/Runner/Base.lproj/LaunchScreen.storyboard
rm -rf ios/Runner/Assets.xcassets/AppIcon.appiconset
cp -R /tmp/cinelens_ios_backup/AppIcon.appiconset ios/Runner/Assets.xcassets/AppIcon.appiconset

echo "=== 4. Mengunduh Paket Flutter & CocoaPods iOS ==="
flutter pub get
dart run flutter_launcher_icons
cd ios && pod install && cd ..

echo "=== SELESAI! Aplikasi CineLens iOS Siap Dijalankan / Dibuild ==="
echo "• Jalankan langsung ke iPhone : flutter run --release"
echo "• Buat installer .ipa iOS     : flutter build ipa --no-codesign"
