# CineLens iOS — Turnkey Hollywood Cinema Camera App (Complete + App Icon)

Paket ini sudah terkonfigurasi penuh ("terima beres") termasuk:
- **Cinema Camera App Icon (`assets/icon/app_icon.png` + seluruh resolusi `ios/Runner/Assets.xcassets/AppIcon.appiconset/` tanpa alpha channel sesuai standar App Store).**
- **Dark Cinema Splash Screen (`ios/Runner/Base.lproj/LaunchScreen.storyboard`).**
- **Kode Aplikasi Flutter Lengkap (`lib/`):** 7 LUT Hollywood, Video 24fps, Anamorphic 2.39:1, Custom Tone Studio, serta Export/Import Preset `.json`.
- **Native Bridge iOS (`ios/Runner/AppDelegate.swift` & `Info.plist`)** + skrip otomatis `build_ios.sh` dan CI/CD GitHub Actions `.github/workflows/build_ios_ipa.yml`.

## Cara Pakai Cepat (Terima Beres)

### Di Mac + Xcode:
```bash
chmod +x build_ios.sh && ./build_ios.sh
flutter run --release   # Pasang langsung ke iPhone
# atau
flutter build ipa       # Hasilkan file .ipa
```

### Tanpa Mac (Via GitHub Actions Cloud):
1. Upload isi folder `cinelens_ios` ini ke GitHub.
2. Buka tab **Actions** -> jalankan **Build CineLens iOS IPA**.
3. Unduh artifak **`CineLens-iOS-IPA`** (`.ipa`) dan instal ke iPhone via Sideloadly / AltStore.
