// lib/core/l10n/app_strings.dart

import 'package:flutter/widgets.dart';

/// Clean, zero-clutter localization that automatically follows the iPhone's
/// system language (`id` for Bahasa Indonesia, `en` default/fallback).
///
/// Universal pro camera notations (`ISO`, `WB`, `RAW`, `LOG`, `ProRes`, `LUT`,
/// `EV`, `B&W`, `180°`, `4K · 24`) stay consistent across all locales.
class AppStrings {
  final bool isId;

  const AppStrings._(this.isId);

  static AppStrings of(BuildContext context) {
    final locale = Localizations.maybeLocaleOf(context);
    return AppStrings._(locale?.languageCode.toLowerCase() == 'id');
  }

  static const AppStrings en = AppStrings._(false);
  static const AppStrings id = AppStrings._(true);

  String _t(String enText, String idText) => isId ? idText : enText;

  // Common actions
  String get save => _t('SAVE', 'SIMPAN');
  String get cancel => _t('Cancel', 'Batal');
  String get delete => _t('Delete', 'Hapus');
  String get reset => _t('Reset', 'Reset');
  String get resetAll => _t('Reset All', 'Reset Semua');
  String get done => _t('Done', 'Selesai');
  String get select => _t('Select', 'Pilih');
  String get selectAll => _t('All', 'Semua');
  String get close => _t('Close', 'Tutup');
  String get retry => _t('Retry', 'Coba Lagi');
  String get importLabel => _t('IMPORT', 'IMPOR');
  String get undo => _t('Undo', 'Urungkan');
  String get redo => _t('Redo', 'Ulangi');
  String get auto => _t('AUTO', 'AUTO');
  String get original => _t('ORIGINAL', 'ASLI');
  String get edited => _t('EDITED', 'EDIT');
  String get holdOriginal => _t('HOLD: ORIGINAL', 'TAHAN: ASLI');
  String get splitCompare => _t('SPLIT', 'SPLIT');
  String get off => _t('OFF', 'MATI');
  String get on => _t('ON', 'AKTIF');

  // Camera modes & HUD
  String get photo => _t('PHOTO', 'FOTO');
  String get video => _t('VIDEO', 'VIDEO');
  String get resFps => _t('RES · FPS', 'RES · FPS');
  String get shutter => _t('SHUTTER', 'SHUTTER');
  String get iso => _t('ISO', 'ISO');
  String get wb => _t('WB', 'WB');
  String get focus => _t('FOCUS', 'FOKUS');
  String get mix => _t('MIX', 'MIX');
  String get custom => _t('+ CUSTOM', '+ KUSTOM');
  String get hide => _t('HIDE', 'TUTUP');

  // Pro Control Drawer tabs
  String get tabExposure => _t('EXPOSURE', 'EKSPOSUR');
  String get tabLook => _t('LOOK', 'LOOK');
  String get tabOptics => _t('OPTICS', 'OPTIK');
  String get tabCamera => _t('CAMERA', 'KAMERA');

  // Pro Drawer labels (1-2 words + concise technical sub-labels)
  String get shutterSpeed => _t('SHUTTER SPEED', 'KECEPATAN SHUTTER');
  String get isoSensitivity => _t('ISO SENSITIVITY', 'SENSITIVITAS ISO');
  String get whiteBalance => _t('WHITE BALANCE', 'WHITE BALANCE');
  String get manualFocus => _t('MANUAL FOCUS', 'FOKUS MANUAL');
  String get processZero => _t('PROCESS ZERO', 'PROCESS ZERO');
  String get processZeroSub => _t('12-bit Bayer RAW', 'Bayer RAW 12-bit');
  String get saveDngRaw => _t('SAVE DNG RAW', 'SIMPAN DNG RAW');
  String get saveDngRawSub => _t('Keep raw negative', 'Simpan file DNG');
  String get hlMetering => _t('HL METERING', 'HL METERING');
  String get hlMeteringSub => _t('-0.9 EV · Deep toe', '-0.9 EV · Deep toe');
  String get rule180 => _t('180° RULE', 'ATURAN 180°');
  String get appleLog => _t('APPLE LOG', 'APPLE LOG');
  String get appleLogSub => _t('Rec.709 IDT', 'Rec.709 IDT');
  String get proRes422 => _t('PRORES 422', 'PRORES 422');
  String get proRes422Sub => _t('10-bit Master', 'Master 10-bit');
  String get directLutRec => _t('DIRECT LUT REC', 'REKAM LUT LANGSUNG');
  String get directLutRecSub => _t('Zero-wait HEVC', 'HEVC tanpa tunggu');
  String get liveMetalLut => _t('LIVE METAL LUT', 'PRATINJAU METAL LUT');
  String get liveMetalLutSub => _t('WYSIWYG 3D GPU', '3D GPU WYSIWYG');
  String get stockEffects => _t('STOCK EFFECTS', 'EFEK BAWAAN STOK');
  String get stockEffectsSub => _t('Authentic halation & grain', 'Halation & grain asli');
  String get bakeProRes => _t('BAKE PRORES LUT', 'BAKAR LUT PRORES');
  String get bakeProResSub => _t('Burn look to master', 'Bakar look ke master');
  String get importCube => _t('IMPORT .CUBE', 'IMPOR .CUBE');
  String get deepShadow => _t('DEEP SHADOW', 'DEEP SHADOW');
  String get acutance => _t('ACUTANCE', 'KETAJAMAN');
  String get grain => _t('GRAIN', 'GRAIN');
  String get grainSize => _t('GRAIN SIZE', 'UKURAN GRAIN');
  String get halation => _t('HALATION', 'HALATION');
  String get bloom => _t('BLOOM', 'BLOOM');
  String get vignette => _t('VIGNETTE', 'VIGNETTE');

  // Optics & Vintage Frame Ratios
  String get frameFormat => _t('FRAME FORMAT', 'FORMAT FRAME');
  String get trueCrop => _t('TRUE CROP', 'CROP ASLI');
  String get trueCropSub => _t('No black bars', 'Tanpa bar hitam');
  String get desqueeze => _t('DESQUEEZE', 'DESQUEEZE');
  String get grid => _t('GRID', 'GRID');
  String get resolution => _t('RESOLUTION', 'RESOLUSI');
  String get frameRate => _t('FRAME RATE', 'FRAME RATE');

  // DOP Monitoring Overlays (Tahap 2)
  String get dopMonitors => _t('DOP MONITORS', 'MONITOR DOP');
  String get focusPeaking => _t('PEAKING', 'PEAKING');
  String get zebraStripes => _t('ZEBRA 95', 'ZEBRA 95');
  String get falseColor => _t('FALSE COLOR', 'FALSE COLOR');
  String get horizonLevel => _t('HORIZON', 'HORIZON');
  String get audioMeter => _t('AUDIO dB', 'AUDIO dB');
  String get liveScope => _t('LIVE SCOPE', 'SCOPE');
  String get haptics => _t('HAPTICS', 'HAPTIK');
  String get presetLibrary => _t('PRESETS', 'PRESET');
  String get aboutApp => _t('ABOUT', 'TENTANG');

  // Gallery
  String get gallery => _t('GALLERY', 'GALERI');
  String get allMedia => _t('ALL', 'SEMUA');
  String get importedMedia => _t('IMPORTED', 'IMPOR');
  String get emptyGalleryTitle => _t('No Media Yet', 'Belum Ada Media');
  String get emptyGallerySub => _t(
        'Capture with CineLens or import from Apple Photos.',
        'Ambil foto/video atau impor dari Apple Photos.',
      );
  String selectedCount(int count) =>
      isId ? '$count dipilih' : '$count selected';
  String deleteItemsTitle(int count) =>
      isId ? 'Hapus $count item?' : 'Delete $count items?';
  String deleteItemsBody(int count) => isId
      ? '$count foto/video akan dihapus permanen dari galeri CineLens.'
      : '$count items will be permanently removed from the CineLens gallery.';
  String savedToPhotosCount(int count) => isId
      ? '$count item disimpan ke Apple Photos.'
      : '$count items saved to Apple Photos.';
  String deletedCount(int count) =>
      isId ? '$count item dihapus.' : '$count items deleted.';
  String get editMedia => _t('Edit', 'Edit');
  String get saveToPhotos => _t('Save to Apple Photos', 'Simpan ke Apple Photos');
  String get deleteFromGallery => _t('Delete', 'Hapus');

  // Photo & Video Editor
  String get editPhoto => _t('EDIT PHOTO', 'EDIT FOTO');
  String get editVideo => _t('EDIT VIDEO', 'EDIT VIDEO');
  String get tabLight => _t('Light', 'Cahaya');
  String get tabCurve => _t('Curve', 'Kurva');
  String get tabColor => _t('Color', 'Warna');
  String get tabMix => _t('Mix', 'Campur');
  String get tabGrade => _t('Grade', 'Grade');
  String get tabFilm => _t('Film', 'Film');
  String get tabFx => _t('FX', 'Efek');
  String get tabDetail => _t('Detail', 'Detail');
  String get tabBlur => _t('Blur', 'Blur');
  String get tabMask => _t('Mask', 'Mask');
  String get tabCrop => _t('Crop', 'Crop');

  String get inputLogProfile => _t('INPUT LOG PROFILE', 'PROFIL LOG INPUT');
  String get matchReference => _t('MATCH REF', 'MATCH REF');
  String get colorMatched => _t('Color matched to reference.', 'Warna dicocokkan ke referensi.');
  String get pickReferenceTitle => _t('Pick Reference Photo', 'Pilih Foto Referensi');
  String get noReferencePhotos => _t('No photos available in gallery.', 'Belum ada foto di galeri.');
  String get wheelsMode => _t('WHEELS', 'WHEELS');
  String get cdlMode => _t('ASC CDL', 'ASC CDL');
  String get normalizeAudio => _t('Normalize Audio (-14 LUFS)', 'Normalisasi Audio (-14 LUFS)');
  String get videoTrim => _t('VIDEO TRIM', 'POTONG VIDEO');
  String get copySettings => _t('Copy Settings', 'Salin Setelan');
  String get pasteSettings => _t('Paste Settings', 'Tempel Setelan');
  String get savePreset => _t('Save as Preset...', 'Simpan Preset...');
  String get cycleScope => _t('Switch Scope', 'Ganti Scope');
  String get toggleSplit => _t('Split Compare', 'Split Banding');
  String get saveToGalleryOnly => _t('CineLens Gallery', 'Galeri CineLens');
  String get saveToGalleryAndPhotos =>
      _t('CineLens + Apple Photos', 'Galeri + Apple Photos');
  String get renderingPhoto => _t('Rendering photo...', 'Merender foto...');
  String get renderingVideo => _t('Rendering video...', 'Merender video...');

  // v2.3.0 Output Engine, Hardware, AI Mask, Borders & About
  String get heif10Bit => _t('10-BIT P3 HEIF', 'HEIF 10-BIT P3');
  String get heif10BitSub => _t('Wide color master', 'Master warna lebar');
  String get nightStack => _t('NIGHT STACK', 'NIGHT STACK');
  String get nightStackSub => _t('3× Bayer RAW fusion', 'Fusi 3× Bayer RAW');
  String get filmicRollOff => _t('FILMIC ROLL-OFF', 'ROLL-OFF FILMIK');
  String get colorDensity => _t('Color Density', 'Densitas Film');
  String get skinProtect => _t('Skin Protection', 'Pelindung Kulit');
  String get volumeShutter => _t('VOLUME SHUTTER', 'SHUTTER VOLUME');
  String get volumeShutterSub => _t('Buttons & BT remote', 'Tombol & remote BT');
  String get selfTimer => _t('TIMER', 'TIMER');
  String get audioInput => _t('MIC INPUT', 'INPUT MIKROFON');
  String get subjectAi => _t('+ SUBJECT AI', '+ SUBJEK AI');
  String get skyBgAi => _t('+ SKY / BG AI', '+ LANGIT / BG AI');
  String get generatingMask => _t('Detecting subject...', 'Mendeteksi subjek...');
  String get exportCubeLut => _t('Export .cube LUT', 'Ekspor LUT .cube');
  String get useLutInCamera => _t('Add to Camera LUTs', 'Tambah ke LUT Kamera');
  String get shareCubeFile => _t('Share .cube File', 'Bagikan File .cube');
  String get lutAddedToCamera => _t('3D LUT added to Camera!', 'LUT 3D masuk ke Kamera!');
  String get frameBorder => _t('FRAME & STAMP', 'BINGKAI & TANGGAL');
  String get exifCaption => _t('EXIF Caption', 'Keterangan EXIF');
  String get dateStamp => _t("Date Stamp ('YY MM DD)", "Cap Tanggal ('YY MM DD)");
  String get batchEdit => _t('Batch Edit', 'Edit Massal');
  String get applyClipboard => _t('Paste Copied Edit', 'Tempel Edit Tersalin');
  String batchRendering(int done, int total) =>
      isId ? 'Memproses $done / $total...' : 'Processing $done / $total...';
  String batchDone(int count) =>
      isId ? '$count item selesai diedit.' : '$count items processed.';
  String get mediaInfo => _t('MEDIA SPECS', 'INFO TEKNIS');
  String get changelogBtn => _t('View Changelog', 'Lihat Riwayat Versi');
  String get changelogTitle => _t('VERSION HISTORY', 'RIWAYAT VERSI');
  String get supportTitle => _t('SUPPORT & FEEDBACK', 'DUKUNGAN & MASUKAN');
  String get copyEmail => _t('Copy Email', 'Salin Email');
  String get sendFeedback => _t('Send Feedback', 'Kirim Masukan');
  String get emailCopied => _t('Email copied', 'Email disalin');

  // v2.4.0 48MP ProRAW, Portrait Photo & Cinematic Video Rack Focus
  String get portrait => _t('PORTRAIT', 'POTRET');
  String get cinematic => _t('CINEMATIC', 'SINEMATIK');
  String get hiRes48MP => _t('48MP HI-RES', '48MP PENUH');
  String get hiRes48MPSub => _t('Quad-Bayer / ProRAW', 'Sensor penuh 48MP');
  String get aperture => _t('DEPTH', 'BUKAAN');
  String get rackSubject => _t('SUBJECT', 'SUBJEK');
  String get rackBackground => _t('BG RACK', 'FOKUS BG');
}
