# CineLens iOS

Aplikasi kamera sinematik Flutter untuk iOS: LUT Hollywood real-time, video 24 fps,
bingkai anamorphic 2.39:1, pembuat tone kustom, serta export/import preset `.json`.

## Fitur

- **7 LUT bawaan** — Standard, Kodak 2383, Teal & Orange, Fuji Velvia, Noir B&W,
  Golden Hour, Vintage 16mm.
- **Grading real-time** di viewfinder lewat `ColorFilter.matrix` (matriks 5×4).
- **Slider intensitas LUT** 0–100 %, diinterpolasi linear dari matriks identitas.
- **Film emulation** — Foto dan video hasil export memakai mesin film native
  (Core Image, `FilmEngine` di `ios/Runner/AppDelegate.swift`): kurva tone S per
  kanal, crosstalk warna, desaturasi highlight, tint shadow/highlight, black &
  white point, halation merah-oranye di sekitar highlight, bloom, grain
  monokrom yang bergerak per frame, softness, dan vignette. Slider intensitas
  menskalakan seluruh efek. Parameternya disetel manual agar menyerupai
  karakter tiap stock; bukan data sensitometri terukur. Viewfinder memakai
  pendekatan matriks linear dari model yang sama, jadi grain/halation baru
  terlihat pada hasil foto dan video. Tone kustom dan preset impor tetap
  memakai matriks warna biasa.
- **Foto sinematik** — frame kamera di-render ulang (`dart:ui`) dengan LUT + bar
  anamorphic, lalu disimpan ke Apple Photos.
- **Video 24 fps** — export lewat native bridge `com.cinelens.ios/video_grader`
  (`AVMutableVideoComposition` + `CIColorMatrix` di `ios/Runner/AppDelegate.swift`).
- **Custom Tone Studio** — atur temperature, tint, contrast, saturation, exposure;
  simpan sebagai preset dengan label warna.
- **Library preset** — export satu/semua preset sebagai file `.json`, bagikan lewat
  share sheet, import dari file atau tempel JSON.
- **Kontrol kamera** — tap-to-focus, exposure offset, flash (off/auto/on/torch),
  ganti kamera depan/belakang, grid komposisi, dan pilihan aspect ratio.

## Struktur proyek

```
lib/
  core/
    constants/     # AppConstants (channel name, pref key, fps, rasio)
    routing/       # GoRouter + argumen navigasi /preview
    theme/         # AppTheme (palet dark cinema)
  features/
    about/         # Layar About & support
    cinema_camera/
      data/        # Preset source, repository (grading, galeri, JSON I/O)
      domain/      # Entity CinemaTone, color matrix builder
      presentation/# Provider (Riverpod AsyncNotifier), screen, widget
    options/       # Grid, aspect ratio, HUD, haptic, mirror
ios/Runner/        # AppDelegate.swift (native video grader), Info.plist
sample_presets/    # Contoh paket preset .json
test/              # Unit test matriks warna & entity
```

## Menjalankan

```bash
flutter pub get
flutter run                 # debug di perangkat/Simulator
flutter analyze             # static analysis
flutter test                # unit test
```

> Kamera dan galeri butuh perangkat iOS asli; Simulator tidak menyediakan kamera.

Membuat IPA unsigned langsung dari Mac:

```bash
flutter build ios --release --no-codesign
mkdir -p build/ios/ipa/Payload
cp -r build/ios/iphoneos/Runner.app build/ios/ipa/Payload/
cd build/ios/ipa && zip -ry CineLens_iOS.ipa Payload
```

Atau jalankan workflow **Build CineLens iOS IPA** di tab Actions.

## Format preset `.json`

```json
{
  "app": "CineLens iOS",
  "schemaVersion": 1,
  "exportedAt": "2026-11-14T16:00:00.000Z",
  "presets": [
    {
      "id": "custom_1",
      "name": "TOKYO NIGHT",
      "filmReference": "35mm",
      "description": "Neon night look",
      "accentColorHex": 4287572283,
      "matrix": [1.0, 0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 0, 1.0, 0],
      "isCustom": true
    }
  ]
}
```

`matrix` wajib berisi tepat 20 angka (baris R, G, B, A; masing-masing 4 koefisien
warna + 1 bias). Import menerima bentuk paket di atas, satu objek dengan `matrix`,
maupun array preset.

## Lisensi

Belum ditentukan.
