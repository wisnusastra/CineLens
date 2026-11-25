import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/constants/app_constants.dart';
import '../../domain/entities/captured_media.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/cinema_tone_preset_package.dart';
import '../../domain/entities/film_look.dart';
import '../../domain/entities/pro_capture_capabilities.dart';
import '../../domain/services/cube_lut.dart';
import '../datasources/cinema_tones_preset_source.dart';

class CinemaCameraRepository {
  final CinemaTonesPresetSource _presetSource;
  static const MethodChannel _videoChannel =
      MethodChannel(AppConstants.videoGraderChannel);

  CinemaCameraRepository({CinemaTonesPresetSource? presetSource})
      : _presetSource = presetSource ?? const CinemaTonesPresetSource();

  Future<List<CinemaTone>> getAllTones() async {
    final builtIn = _presetSource.getHollywoodTones();
    final custom = await loadCustomTones();
    return [...builtIn, ...custom];
  }

  Future<List<CinemaTone>> loadCustomTones() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = prefs.getString(AppConstants.prefCustomTonesJson);
    if (rawJson == null || rawJson.isEmpty) return [];

    final List<dynamic> decoded = jsonDecode(rawJson) as List<dynamic>;
    return decoded
        .map((item) => CinemaTone.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveCustomTone(CinemaTone newTone) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadCustomTones();
    final updated = [...existing, newTone.copyWith(isCustom: true)];
    final encoded = jsonEncode(updated.map((t) => t.toJson()).toList());
    await prefs.setString(AppConstants.prefCustomTonesJson, encoded);
  }

  Future<void> deleteCustomTone(String toneId) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadCustomTones();
    final removed = existing.where((t) => t.id == toneId).toList();
    final updated = existing.where((t) => t.id != toneId).toList();
    final encoded = jsonEncode(updated.map((t) => t.toJson()).toList());
    await prefs.setString(AppConstants.prefCustomTonesJson, encoded);

    for (final tone in removed) {
      await deleteLutPayload(tone.lutPath);
    }
  }

  String buildPresetJsonString(List<CinemaTone> tones) {
    final package = CinemaTonePresetPackage(
      exportedAt: DateTime.now(),
      presets: tones,
    );
    return package.toPrettyJson();
  }

  Future<void> exportTonesViaShareSheet(
    List<CinemaTone> tones, {
    Rect? shareOriginRect,
  }) async {
    if (tones.isEmpty) {
      throw Exception('Tidak ada preset custom untuk dibagikan.');
    }

    final jsonString = buildPresetJsonString(tones);
    final tempDir = await getTemporaryDirectory();

    final baseName = tones.length == 1
        ? tones.first.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        : 'cinelens_custom_pack_${tones.length}_presets';

    final file = File('${tempDir.path}/$baseName.json');
    await file.writeAsString(jsonString, flush: true);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: 'CineLens iOS Cinema Preset ($baseName)',
      text:
          'Preset tone sinematik CineLens iOS (${tones.length} LUT). Impor file .json ini di dalam aplikasi CineLens.',
      sharePositionOrigin: shareOriginRect,
    );
  }

  Future<List<CinemaTone>> importTonesFromFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) {
      return [];
    }

    final pickedFile = result.files.single;
    String rawJson;

    if (pickedFile.bytes != null) {
      rawJson = utf8.decode(pickedFile.bytes!);
    } else if (pickedFile.path != null) {
      rawJson = await File(pickedFile.path!).readAsString();
    } else {
      throw const FormatException(
          'File JSON tidak dapat dibaca oleh sistem iOS.');
    }

    return importTonesFromJsonString(rawJson);
  }

  // ------------------------------------------------------------- .cube LUTs

  /// Picks one or more `.cube` files and registers them as custom tones.
  ///
  /// The cube is converted to a raw RGBA float payload that Core Image can read
  /// directly, so the exported photo/video uses the exact LUT. `matrix` on the
  /// resulting tone is a least-squares approximation for the live preview,
  /// because Flutter can only filter with a colour matrix.
  Future<List<CinemaTone>> importCubeLutsFromFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['cube'],
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return [];

    final directory = await _lutDirectory();
    final imported = <CinemaTone>[];
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadCustomTones();
    final existingNames = existing.map((t) => t.name.toUpperCase()).toSet();

    for (final file in result.files) {
      try {
        final String text;
        if (file.bytes != null) {
          text = utf8.decode(file.bytes!, allowMalformed: true);
        } else if (file.path != null) {
          text = await File(file.path!).readAsString();
        } else {
          continue;
        }

        final cube = parseCubeLut(text);
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final id = 'cube_${stamp}_${imported.length}';
        final payload = File('${directory.path}/$id.rgba');
        await payload.writeAsBytes(cube.toRgbaCube().buffer.asUint8List(),
            flush: true);

        var name = (cube.title ?? _baseName(file.name)).toUpperCase();
        if (existingNames.contains(name)) name = '$name (IMP)';
        existingNames.add(name);

        imported.add(
          CinemaTone(
            id: id,
            name: name,
            filmReference: 'LUT 3D ${cube.size}³',
            description: 'LUT impor dari ${file.name}',
            accentColorHex: 0xFFE5A93B,
            matrix: fitCubeToMatrix(cube),
            isCustom: true,
            lutPath: payload.path,
            lutSize: cube.size,
          ),
        );
      } catch (_) {
        // A broken file must not abort the whole import; the caller reports how
        // many actually landed.
        continue;
      }
    }

    if (imported.isEmpty) return [];

    final merged = [...existing, ...imported];
    await prefs.setString(
      AppConstants.prefCustomTonesJson,
      jsonEncode(merged.map((t) => t.toJson()).toList()),
    );
    return imported;
  }

  /// Registers a `.cube` file generated on-device (e.g. from the Gallery Editor)
  /// directly into the Camera custom LUT list.
  Future<CinemaTone?> importCubeFileFromPath(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final text = await file.readAsString();
    final cube = parseCubeLut(text);
    final directory = await _lutDirectory();
    final id = 'cube_${DateTime.now().microsecondsSinceEpoch}';
    final payload = File('${directory.path}/$id.rgba');
    await payload.writeAsBytes(cube.toRgbaCube().buffer.asUint8List(),
        flush: true);

    final prefs = await SharedPreferences.getInstance();
    final existing = await loadCustomTones();
    final existingNames = existing.map((t) => t.name.toUpperCase()).toSet();
    var name =
        (cube.title ?? _baseName(file.uri.pathSegments.last)).toUpperCase();
    if (existingNames.contains(name)) name = '$name (EDIT)';

    final tone = CinemaTone(
      id: id,
      name: name,
      filmReference: 'LUT 3D ${cube.size}³',
      description: ' CineLens 3D LUT',
      accentColorHex: 0xFFE5A93B,
      matrix: fitCubeToMatrix(cube),
      isCustom: true,
      lutPath: payload.path,
      lutSize: cube.size,
    );
    final merged = [...existing, tone];
    await prefs.setString(
      AppConstants.prefCustomTonesJson,
      jsonEncode(merged.map((t) => t.toJson()).toList()),
    );
    return tone;
  }

  Future<Directory> _lutDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory =
        Directory('${documents.path}/${AppConstants.lutFolderName}');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  String _baseName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /// Removes the backing file of an imported LUT once its tone is deleted.
  Future<void> deleteLutPayload(String? path) async {
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Best effort: a stale file only wastes a few hundred kilobytes.
      }
    }
  }

  // ------------------------------------------------------------- film look

  Future<FilmLook> loadFilmLook() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppConstants.prefFilmLookJson);
    if (raw == null || raw.isEmpty) return const FilmLook();
    try {
      return FilmLook.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const FilmLook();
    }
  }

  Future<void> saveFilmLook(FilmLook look) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConstants.prefFilmLookJson,
      jsonEncode(look.toJson()),
    );
  }

  Future<bool> loadBakeLookIntoProRes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppConstants.prefBakeLookIntoProRes) ?? false;
  }

  Future<void> saveBakeLookIntoProRes(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefBakeLookIntoProRes, enabled);
  }

  Future<
      ({
        bool processZero,
        bool saveDngRaw,
        bool nightStack,
        bool heif10Bit,
        bool hiRes48MP,
        double apertureFStop,
        bool volumeShutter,
        int timerSeconds,
        bool anamorphicCrop,
        double desqueeze,
        bool highlightMetering,
        String? frameFormat,
        bool directLutRecording,
        bool liveMetalPreview,
      })> loadProImagingSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      processZero: prefs.getBool(AppConstants.prefProcessZeroRaw) ?? false,
      saveDngRaw: prefs.getBool(AppConstants.prefSaveDngRaw) ?? false,
      nightStack: prefs.getBool(AppConstants.prefNightStack) ?? false,
      heif10Bit: prefs.getBool(AppConstants.prefHeif10Bit) ?? false,
      hiRes48MP: prefs.getBool(AppConstants.prefHiRes48MP) ?? false,
      apertureFStop: prefs.getDouble(AppConstants.prefApertureFStop) ?? 2.2,
      volumeShutter: prefs.getBool(AppConstants.prefVolumeShutter) ?? true,
      timerSeconds: prefs.getInt(AppConstants.prefTimerSeconds) ?? 0,
      anamorphicCrop: prefs.getBool(AppConstants.prefAnamorphicCrop) ?? false,
      desqueeze: prefs.getDouble(AppConstants.prefAnamorphicDesqueeze) ?? 1.0,
      highlightMetering:
          prefs.getBool(AppConstants.prefHighlightMetering) ?? false,
      frameFormat: prefs.getString(AppConstants.prefFrameFormat),
      directLutRecording:
          prefs.getBool(AppConstants.prefDirectLutRecording) ?? false,
      liveMetalPreview:
          prefs.getBool(AppConstants.prefLiveMetalPreview) ?? false,
    );
  }

  Future<void> saveHeif10Bit(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefHeif10Bit, enabled);
  }

  Future<void> saveHiRes48MP(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefHiRes48MP, enabled);
  }

  Future<void> saveApertureFStop(double fStop) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(AppConstants.prefApertureFStop, fStop);
  }

  Future<bool> triggerCinematicRackFocus({
    required double x,
    required double y,
    bool? rackToBackground,
  }) async {
    try {
      return (await _videoChannel.invokeMethod<bool>(
            'triggerCinematicRackFocus',
            <String, dynamic>{
              'x': x,
              'y': y,
              if (rackToBackground != null)
                'rackToBackground': rackToBackground,
            },
          )) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> saveNightStack(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefNightStack, enabled);
  }

  Future<void> saveVolumeShutter(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefVolumeShutter, enabled);
  }

  Future<void> saveTimerSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.prefTimerSeconds, seconds);
  }

  Future<void> saveFrameFormat(String formatName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefFrameFormat, formatName);
  }

  Future<void> saveSaveDngRaw(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefSaveDngRaw, enabled);
  }

  Future<void> saveDirectLutRecording(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefDirectLutRecording, enabled);
  }

  Future<void> saveLiveMetalPreview(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefLiveMetalPreview, enabled);
  }

  Future<void> saveProcessZero(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefProcessZeroRaw, enabled);
  }

  Future<void> saveAnamorphicCrop(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefAnamorphicCrop, enabled);
  }

  Future<void> saveAnamorphicDesqueeze(double factor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(AppConstants.prefAnamorphicDesqueeze, factor);
  }

  Future<void> saveHighlightMetering(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefHighlightMetering, enabled);
  }

  /// Captures a true Process Zero Bayer RAW photo natively (bypassing Apple
  /// Smart HDR shadow-lifting) and grades it through the 16-bit FilmEngine.
  /// Returns `null` when Bayer RAW isn't available so caller falls back cleanly.
  Future<Uint8List?> captureProcessZeroPhoto({
    required List<double> colorMatrix,
    required bool applyAnamorphicBars,
    bool anamorphicCrop = false,
    double frameAspectRatio = 0.0,
    bool saveDngRaw = false,
    bool nightStack = false,
    bool heif10Bit = false,
    bool hiRes48MP = false,
    bool portraitMode = false,
    double apertureFStop = 2.4,
    double focusX = 0.5,
    double focusY = 0.5,
    double desqueeze = 1.0,
    String? toneId,
    double intensity = 1.0,
    Map<String, dynamic>? look,
  }) async {
    try {
      final graded = await _videoChannel.invokeMethod<Uint8List>(
        'captureProcessZeroPhoto',
        <String, dynamic>{
          'matrix': colorMatrix,
          'toneId': toneId,
          'intensity': intensity,
          'anamorphic': applyAnamorphicBars,
          'anamorphicCrop': anamorphicCrop,
          'frameAspectRatio': frameAspectRatio,
          'saveDngRaw': saveDngRaw,
          'nightStack': nightStack,
          'heif10Bit': heif10Bit,
          'hiRes48MP': hiRes48MP,
          'portraitMode': portraitMode,
          'apertureFStop': apertureFStop,
          'focusX': focusX,
          'focusY': focusY,
          'desqueeze': desqueeze,
          'quality': 0.98,
          if (look != null) 'look': look,
        },
      ).timeout(const Duration(seconds: 24));
      if (graded != null && graded.isNotEmpty) return graded;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
    return null;
  }

  Future<List<CinemaTone>> importTonesFromJsonString(String rawJson) async {
    final importedTones =
        CinemaTonePresetPackage.parseAndValidateTones(rawJson);
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadCustomTones();

    final existingNames = existing.map((e) => e.name.toUpperCase()).toSet();
    final normalizedImported = <CinemaTone>[];

    for (final tone in importedTones) {
      String finalName = tone.name;
      if (existingNames.contains(finalName)) {
        finalName = '$finalName (IMP)';
      }
      existingNames.add(finalName);
      normalizedImported.add(tone.copyWith(name: finalName, isCustom: true));
    }

    final merged = [...existing, ...normalizedImported];
    final encoded = jsonEncode(merged.map((t) => t.toJson()).toList());
    await prefs.setString(AppConstants.prefCustomTonesJson, encoded);

    return normalizedImported;
  }

  Future<({String toneId, double intensity})> loadSavedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final toneId =
        prefs.getString(AppConstants.prefSelectedToneId) ?? 'teal_orange';
    var intensity = prefs.getDouble(AppConstants.prefToneIntensity) ?? 1.0;
    // Older builds started every tone at 85%, which made the stronger presets
    // read as washed out. Lift that legacy value once; whatever the user picks
    // afterwards is kept.
    if (prefs.getBool(AppConstants.prefToneIntensityFullV2) != true) {
      if (intensity < 1.0) intensity = 1.0;
      await prefs.setBool(AppConstants.prefToneIntensityFullV2, true);
    }
    return (toneId: toneId, intensity: intensity);
  }

  Future<void> savePreferences({
    required String toneId,
    required double intensity,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefSelectedToneId, toneId);
    await prefs.setDouble(AppConstants.prefToneIntensity, intensity);
  }

  /// Applies the cinematic LUT to a still and returns JPEG bytes.
  ///
  /// The native path keeps the full sensor resolution and encodes lossless
  /// JPEG without ever materialising a PNG, which is what made large stills
  /// slow and blurry. If the channel is unavailable the Dart renderer below
  /// is used instead.
  ///
  /// [toneId] and [intensity] select the native film emulation (colour cube,
  /// halation, bloom and grain) for the built-in tones. Without a [toneId]
  /// (custom tones, imported presets) the plain [colorMatrix] grade is used.
  Future<Uint8List> renderGradedImage({
    required Uint8List rawBytes,
    required List<double> colorMatrix,
    required bool applyAnamorphicBars,
    bool anamorphicCrop = false,
    double frameAspectRatio = 0.0,
    double desqueeze = 1.0,
    bool appleLogInput = false,
    bool heif10Bit = false,
    bool portraitMode = false,
    double apertureFStop = 2.4,
    double focusX = 0.5,
    double focusY = 0.5,
    String? toneId,
    double intensity = 1.0,
    Map<String, dynamic>? look,
  }) async {
    try {
      final graded = await _videoChannel.invokeMethod<Uint8List>(
        'applyCinemaMatrixToPhoto',
        <String, dynamic>{
          'inputBytes': rawBytes,
          'matrix': colorMatrix,
          'toneId': toneId,
          'intensity': intensity,
          'anamorphic': applyAnamorphicBars,
          'anamorphicCrop': anamorphicCrop,
          'frameAspectRatio': frameAspectRatio,
          'desqueeze': desqueeze,
          'appleLogInput': appleLogInput,
          'heif10Bit': heif10Bit,
          'portraitMode': portraitMode,
          'apertureFStop': apertureFStop,
          'focusX': focusX,
          'focusY': focusY,
          'quality': 0.98,
          if (look != null) 'look': look,
        },
      );
      if (graded != null && graded.isNotEmpty) return graded;
    } on MissingPluginException {
      // No native grader on this platform.
    } on PlatformException {
      // Fall through to the Dart renderer.
    }

    return _renderGradedImageInDart(
      rawBytes: rawBytes,
      colorMatrix: colorMatrix,
      applyAnamorphicBars: applyAnamorphicBars,
    );
  }

  Future<Uint8List> _renderGradedImageInDart({
    required Uint8List rawBytes,
    required List<double> colorMatrix,
    required bool applyAnamorphicBars,
  }) async {
    final codec = await ui.instantiateImageCodec(rawBytes);
    final frame = await codec.getNextFrame();
    final sourceImage = frame.image;

    final int width = sourceImage.width;
    final int height = sourceImage.height;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final paint = Paint()
      ..colorFilter = ColorFilter.matrix(colorMatrix)
      ..filterQuality = FilterQuality.high;

    canvas.drawImage(sourceImage, Offset.zero, paint);

    if (applyAnamorphicBars) {
      final double targetHeight = width / AppConstants.anamorphicAspectRatio;
      if (height > targetHeight) {
        final double barHeight = (height - targetHeight) / 2.0;
        final barPaint = Paint()..color = Colors.black;
        canvas.drawRect(
            Rect.fromLTWH(0, 0, width.toDouble(), barHeight), barPaint);
        canvas.drawRect(
          Rect.fromLTWH(0, height - barHeight, width.toDouble(), barHeight),
          barPaint,
        );
      }
    }

    final picture = recorder.endRecording();
    final gradedImage = await picture.toImage(width, height);
    final byteData =
        await gradedImage.toByteData(format: ui.ImageByteFormat.png);

    sourceImage.dispose();
    gradedImage.dispose();

    if (byteData == null) {
      throw Exception('Gagal mengonversi hasil render foto sinematik.');
    }
    return byteData.buffer.asUint8List();
  }

  Future<void> saveImageToIosGallery(Uint8List imageBytes) async {
    await _ensureGalleryPermission();
    await Gal.putImageBytes(
      imageBytes,
      album: AppConstants.albumName,
      name: 'CINELENS_STILL_${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  /// Exports a LUT-graded copy of [rawVideoPath] and returns its path.
  ///
  /// Falls back to [rawVideoPath] when the native grader is unavailable
  /// (for example a simulator build or a platform without the channel).
  Future<String> renderGradedVideo({
    required String rawVideoPath,
    required List<double> colorMatrix,
    required bool applyAnamorphicBars,
    bool anamorphicCrop = false,
    double frameAspectRatio = 0.0,
    double desqueeze = 1.0,
    bool appleLogInput = false,
    required int fps,
    String? toneId,
    double intensity = 1.0,
    Map<String, dynamic>? look,
  }) async {
    try {
      final gradedPath = await _videoChannel.invokeMethod<String>(
        'applyCinemaMatrixToVideo',
        <String, dynamic>{
          'inputPath': rawVideoPath,
          'matrix': colorMatrix,
          'toneId': toneId,
          'intensity': intensity,
          'anamorphic': applyAnamorphicBars,
          'anamorphicCrop': anamorphicCrop,
          'frameAspectRatio': frameAspectRatio,
          'desqueeze': desqueeze,
          'appleLogInput': appleLogInput,
          'fps': fps,
          if (look != null) 'look': look,
        },
      ).timeout(const Duration(minutes: 20));
      if (gradedPath != null && gradedPath.isNotEmpty) {
        return gradedPath;
      }
    } on MissingPluginException {
      // No native grader on this platform.
    } on TimeoutException {
      // The native watchdog normally answers first; this only fires if the
      // platform channel itself wedged. The raw take is still usable.
    }
    return rawVideoPath;
  }

  /// Burns the tone + film look into a ProRes master.
  ///
  /// The native side re-encodes to ProRes 422, so the result is still a 10-bit
  /// master and only the look changes. Returns [path] unchanged when the export
  /// is unavailable, because the flat master is better than no file.
  Future<String> bakeLookIntoProRes({
    required String path,
    required List<double> colorMatrix,
    required Map<String, dynamic> look,
    bool appleLogInput = false,
    double desqueeze = 1.0,
    String? toneId,
    double intensity = 1.0,
  }) async {
    try {
      final baked = await _videoChannel.invokeMethod<String>(
        'bakeLookIntoProRes',
        <String, dynamic>{
          'inputPath': path,
          'matrix': colorMatrix,
          'toneId': toneId,
          'intensity': intensity,
          'appleLogInput': appleLogInput,
          'desqueeze': desqueeze,
          'look': look,
        },
      ).timeout(const Duration(minutes: 35));
      if (baked != null && baked.isNotEmpty) return baked;
    } on MissingPluginException {
      // Not on this platform.
    } on TimeoutException {
      // Safety net only: the native export has its own watchdog.
    }
    return path;
  }

  Future<void> saveVideoToGallery(String videoPath) async {
    await _ensureGalleryPermission();
    await Gal.putVideo(videoPath, album: AppConstants.albumName);
  }

  /// Receives the stabilisation status that the native capture pipeline
  /// reports every time a session starts.
  ///
  /// The `camera` plugin does not expose `AVCaptureConnection`, so the status
  /// arrives through the same method channel that does the grading.
  void listenToStabilization(
    void Function(bool active, int mode) onChanged, {
    void Function(String path)? onProResFinished,
    void Function(double progress)? onExportProgress,
    void Function(double? horizonDegrees, double? audioPeakDb)? onDopTelemetry,
    void Function(Map<String, dynamic> scope)? onLiveScope,
    VoidCallback? onHardwareShutter,
  }) {
    _videoChannel.setMethodCallHandler((call) async {
      if (call.method == 'hardwareShutterPressed') {
        onHardwareShutter?.call();
        return null;
      }

      if (call.method == 'dopTelemetry') {
        final map = call.arguments is Map
            ? call.arguments as Map<Object?, Object?>
            : const <Object?, Object?>{};
        final h = map['horizonDegrees'];
        final a = map['audioPeakDb'];
        if (onDopTelemetry != null) {
          onDopTelemetry(
            h is num ? h.toDouble() : null,
            a is num ? a.toDouble() : null,
          );
        }
        return null;
      }

      if (call.method == 'liveCameraScope') {
        final raw = call.arguments;
        if (raw is Map && onLiveScope != null) {
          final parsed = <String, dynamic>{};
          raw.forEach((k, v) {
            if (k is String) parsed[k] = v;
          });
          onLiveScope(parsed);
        }
        return null;
      }

      // Native exports report how far they are so the spinner can show a real
      // percentage instead of looking stuck.
      if (call.method == 'exportProgress') {
        final arguments = call.arguments;
        final map = arguments is Map ? arguments : const <Object?, Object?>{};
        final value = map['progress'];
        if (value is num && onExportProgress != null) {
          onExportProgress(value.toDouble().clamp(0.0, 1.0));
        }
        return null;
      }

      // The native recorder closes the `.mov` on its own when iOS interrupts a
      // take (call, background, thermal stop). Dart never called stopProRes in
      // that case, so the path is pushed back here to be saved.
      if (call.method == 'proResFinished') {
        final arguments = call.arguments;
        final map = arguments is Map ? arguments : const <Object?, Object?>{};
        final path = map['path'];
        if (path is String && path.isNotEmpty && onProResFinished != null) {
          onProResFinished(path);
        }
        return null;
      }

      if (call.method != 'stabilizationChanged') return null;

      final arguments = call.arguments;
      final map = arguments is Map ? arguments : const <Object?, Object?>{};
      final rawMode = map['mode'];
      onChanged(
        map['active'] == true,
        rawMode is num ? rawMode.toInt() : 0,
      );
      return null;
    });
  }

  // ------------------------------------------------------------ manual controls

  /// Current device limits for the pro controls.
  ///
  /// Returns [ProCaptureCapabilities.unavailable] on a simulator, before the
  /// session started, or on platforms without the channel.
  Future<ProCaptureCapabilities> loadProCapabilities() async {
    try {
      final map = await _videoChannel.invokeMapMethod<Object?, Object?>(
        'cameraCapabilities',
      );
      if (map != null) return ProCaptureCapabilities.fromMap(map);
    } on MissingPluginException {
      // No native camera control on this platform.
    } on PlatformException {
      // Treated as unavailable; the pro panel stays hidden.
    }
    return ProCaptureCapabilities.unavailable;
  }

  /// Locks exposure to a real shutter/ISO pair.
  Future<void> setManualExposure({
    required double shutterSeconds,
    required double iso,
  }) {
    return _invokeOrThrow('setManualExposure', <String, dynamic>{
      'seconds': shutterSeconds,
      'iso': iso,
    });
  }

  Future<void> setAutoExposure() => _invokeOrThrow('setAutoExposure');

  Future<void> setManualWhiteBalance({
    required int kelvin,
    required int tint,
  }) {
    return _invokeOrThrow('setManualWhiteBalance', <String, dynamic>{
      'kelvin': kelvin,
      'tint': tint,
    });
  }

  Future<void> setAutoWhiteBalance() => _invokeOrThrow('setAutoWhiteBalance');

  /// `position` follows `AVCaptureDevice` lens position: 0.0 far, 1.0 near.
  Future<void> setManualFocus(double position) {
    return _invokeOrThrow('setManualFocus', <String, dynamic>{
      'position': position,
    });
  }

  Future<void> setAutoFocus() => _invokeOrThrow('setAutoFocus');

  /// Starts an Apple ProRes 422 take through the native recorder.
  ///
  /// The native side swaps the sensor into a 10-bit 4:2:2 format and only
  /// answers once `AVCaptureFileOutput` actually began writing, so a thrown
  /// [PlatformException] means no file was produced.
  Future<void> startProResRecording({
    required int width,
    required int height,
    required int fps,
  }) {
    return _invokeOrThrow('startProRes', <String, dynamic>{
      'width': width,
      'height': height,
      'fps': fps,
    });
  }

  /// Stops the ProRes take and returns the `.mov` master on disk.
  Future<String?> stopProResRecording() async {
    try {
      return await _videoChannel.invokeMethod<String>('stopProRes');
    } on MissingPluginException {
      throw PlatformException(
        code: 'unsupported',
        message: 'Perekam ProRes hanya tersedia di aplikasi iOS.',
      );
    }
  }

  /// Turns Apple Log on/off and returns the state the device really applied.
  Future<bool> setAppleLog(bool enabled) async {
    try {
      final applied = await _videoChannel.invokeMethod<bool>(
        'setAppleLog',
        <String, dynamic>{'enabled': enabled},
      );
      return applied ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  // ------------------------------------------------ Tahap 2 Metal & DOP

  Future<int?> enableLiveMetalPreview(Map<String, dynamic> config) async {
    try {
      final id = await _videoChannel.invokeMethod<int>(
        'enableLiveMetalPreview',
        config,
      );
      return (id != null && id >= 0) ? id : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> updateLiveMetalConfig(Map<String, dynamic> config) async {
    try {
      await _videoChannel.invokeMethod<Object?>(
        'updateLiveMetalConfig',
        config,
      );
    } catch (_) {}
  }

  Future<void> disableLiveMetalPreview() async {
    try {
      await _videoChannel.invokeMethod<Object?>('disableLiveMetalPreview');
    } catch (_) {}
  }

  Future<void> startDirectLutRecording(Map<String, dynamic> args) {
    return _invokeOrThrow('startDirectLutRecording', args);
  }

  Future<String?> stopDirectLutRecording() async {
    try {
      return await _videoChannel.invokeMethod<String>('stopDirectLutRecording');
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> setDopTelemetry({
    required bool horizon,
    required bool audio,
  }) async {
    try {
      await _videoChannel.invokeMethod<Object?>(
        'setDopTelemetry',
        <String, dynamic>{'horizon': horizon, 'audio': audio},
      );
    } catch (_) {}
  }

  /// Throws [PlatformException] (with the native message) so the UI can tell the
  /// operator when the device refused a setting.
  Future<void> _invokeOrThrow(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      await _videoChannel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw PlatformException(
        code: 'unsupported',
        message: 'Kontrol manual hanya tersedia di aplikasi iOS.',
      );
    }
  }

  // ------------------------------------------------------------ app gallery

  /// Copies a capture into the app private library and indexes it.
  ///
  /// The gallery never depends on Apple Photos permissions: the bytes are
  /// written under the documents directory and the metadata goes into
  /// SharedPreferences.
  Future<CapturedMedia> storePhoto({
    required Uint8List jpegBytes,
    required String toneId,
    required String toneName,
    required double intensity,
    required bool isAnamorphic,
  }) async {
    final directory = await _mediaDirectory();
    final createdAt = DateTime.now();
    final id = 'photo_${createdAt.millisecondsSinceEpoch}';
    final file = File('${directory.path}${Platform.pathSeparator}$id.jpg');
    await file.writeAsBytes(jpegBytes, flush: true);

    final media = CapturedMedia(
      id: id,
      type: CapturedMediaType.photo,
      path: file.path,
      createdAt: createdAt,
      toneId: toneId,
      toneName: toneName,
      intensity: intensity,
      isAnamorphic: isAnamorphic,
      source: CapturedMediaSource.capture,
    );
    await _prependToLibrary(media);
    return media;
  }

  Future<CapturedMedia> storeVideo({
    required String sourcePath,
    required String toneId,
    required String toneName,
    required double intensity,
    required bool isAnamorphic,
  }) async {
    final directory = await _mediaDirectory();
    final createdAt = DateTime.now();
    final id = 'video_${createdAt.millisecondsSinceEpoch}';
    final extension = sourcePath.toLowerCase().endsWith('.mov') ? 'mov' : 'mp4';
    final target =
        File('${directory.path}${Platform.pathSeparator}$id.$extension');

    final source = File(sourcePath);
    if (await source.exists()) {
      if (source.absolute.path != target.absolute.path) {
        await source.copy(target.path);
      }
    }

    final media = CapturedMedia(
      id: id,
      type: CapturedMediaType.video,
      path: target.path,
      createdAt: createdAt,
      toneId: toneId,
      toneName: toneName,
      intensity: intensity,
      isAnamorphic: isAnamorphic,
      source: CapturedMediaSource.capture,
    );
    await _prependToLibrary(media);
    return media;
  }

  /// Indexes a photo or clip that was already copied into the app media folder
  /// by the Photos importer.
  ///
  /// No copy is made: the importer writes a uniquely named file straight into
  /// [AppConstants.mediaFolderName], which is exactly where the gallery keeps
  /// its own captures, so storage stays single-copy.
  Future<CapturedMedia> indexImportedMedia({
    required String path,
    required bool isVideo,
    String toneId = 'standard',
    String toneName = 'Standard',
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('File impor tidak ditemukan.');
    }

    final createdAt = DateTime.now();
    final media = CapturedMedia(
      id: '${isVideo ? 'video' : 'photo'}_import_'
          '${createdAt.microsecondsSinceEpoch}',
      type: isVideo ? CapturedMediaType.video : CapturedMediaType.photo,
      path: path,
      createdAt: createdAt,
      toneId: toneId,
      toneName: toneName,
      intensity: 1.0,
      isAnamorphic: false,
      source: CapturedMediaSource.imported,
    );
    await _prependToLibrary(media);
    return media;
  }

  Future<List<CapturedMedia>> loadCapturedMedia() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = prefs.getString(AppConstants.prefMediaLibraryJson);
    if (rawJson == null || rawJson.isEmpty) return [];

    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) return [];

      final entries = decoded
          .whereType<Map<String, dynamic>>()
          .map(CapturedMedia.tryParse)
          .whereType<CapturedMedia>()
          .toList();

      // Drop entries whose file disappeared (for example after iOS cleaned
      // the temporaries up).
      final alive = <CapturedMedia>[];
      for (final media in entries) {
        if (await File(media.path).exists()) alive.add(media);
      }
      return alive;
    } catch (_) {
      return [];
    }
  }

  Future<void> deleteCapturedMedia(CapturedMedia media) async {
    await deleteCapturedMediaBatch(<CapturedMedia>[media]);
  }

  /// Removes multiple gallery items in one atomic preference write + file cleanup.
  Future<void> deleteCapturedMediaBatch(List<CapturedMedia> items) async {
    if (items.isEmpty) return;
    final ids = items.map((e) => e.id).toSet();
    final entries = await loadCapturedMedia();
    final remaining = entries.where((entry) => !ids.contains(entry.id)).toList();
    await _writeLibrary(remaining);

    for (final media in items) {
      try {
        final file = File(media.path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best effort cleanup.
      }
    }
  }

  Future<Directory> _mediaDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}${AppConstants.mediaFolderName}',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> _prependToLibrary(CapturedMedia media) async {
    final entries = await loadCapturedMedia();
    final updated = <CapturedMedia>[media, ...entries];

    final dropped = updated.length > AppConstants.maxGalleryEntries
        ? updated.sublist(AppConstants.maxGalleryEntries)
        : const <CapturedMedia>[];

    await _writeLibrary(
      updated.take(AppConstants.maxGalleryEntries).toList(),
    );

    for (final old in dropped) {
      try {
        final file = File(old.path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best effort cleanup.
      }
    }
  }

  Future<void> _writeLibrary(List<CapturedMedia> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(entries.map((entry) => entry.toJson()).toList());
    await prefs.setString(AppConstants.prefMediaLibraryJson, encoded);
  }

  // -------------------------------------------------------- capture settings

  Future<({String? resolution, int? frameRate})> loadCaptureSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      resolution: prefs.getString(AppConstants.prefCaptureResolution),
      frameRate: prefs.getInt(AppConstants.prefCaptureFrameRate),
    );
  }

  Future<void> saveCaptureSettings({
    required String resolution,
    required int frameRate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefCaptureResolution, resolution);
    await prefs.setInt(AppConstants.prefCaptureFrameRate, frameRate);
  }

  Future<Map<String, dynamic>> generateVideoThumbnail(String path) async {
    try {
      final raw = await _videoChannel.invokeMapMethod<Object?, Object?>(
        'generateVideoThumbnail',
        <String, dynamic>{'path': path},
      );
      if (raw == null) return const <String, dynamic>{};
      final out = <String, dynamic>{};
      raw.forEach((k, v) {
        if (k is String) out[k] = v;
      });
      return out;
    } on MissingPluginException {
      return const <String, dynamic>{};
    }
  }

  Future<Map<String, dynamic>> inspectMediaMetadata(
    String path, {
    required bool isVideo,
  }) async {
    try {
      final raw = await _videoChannel.invokeMapMethod<Object?, Object?>(
        'inspectMediaMetadata',
        <String, dynamic>{'path': path, 'isVideo': isVideo},
      );
      if (raw == null) return const <String, dynamic>{};
      final out = <String, dynamic>{};
      raw.forEach((k, v) {
        if (k is String) out[k] = v;
      });
      return out;
    } on MissingPluginException {
      return const <String, dynamic>{};
    }
  }

  Future<void> setVolumeShutterEnabled(bool enabled) async {
    try {
      await _videoChannel.invokeMethod<bool>(
        'setVolumeShutterEnabled',
        <String, dynamic>{'enabled': enabled},
      );
    } on MissingPluginException {
      // Ignored off iOS.
    }
  }

  Future<List<Map<String, dynamic>>> listAudioInputs() async {
    try {
      final raw = await _videoChannel.invokeListMethod<Object?>('listAudioInputs');
      if (raw == null) return const <Map<String, dynamic>>[];
      return raw.whereType<Map>().map((m) {
        final out = <String, dynamic>{};
        m.forEach((k, v) {
          if (k is String) out[k] = v;
        });
        return out;
      }).toList();
    } on MissingPluginException {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<bool> selectAudioInput(String? portUID) async {
    try {
      return (await _videoChannel.invokeMethod<bool>(
            'selectAudioInput',
            <String, dynamic>{'portUID': portUID},
          )) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  // ----------------------------------------- v3.0 Native Swift Camera Engine

  Future<Map<String, dynamic>> nativeCameraInit(
    Map<String, dynamic> args,
  ) async {
    final raw = await _videoChannel.invokeMapMethod<Object?, Object?>(
      'nativeCameraInit',
      args,
    );
    if (raw == null) return const <String, dynamic>{};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<Map<String, dynamic>> nativeCameraConfigure(
    Map<String, dynamic> args,
  ) async {
    final raw = await _videoChannel.invokeMapMethod<Object?, Object?>(
      'nativeCameraConfigure',
      args,
    );
    if (raw == null) return const <String, dynamic>{};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<void> nativeCameraSetZoom(double zoom) async {
    try {
      await _videoChannel.invokeMethod<bool>(
        'nativeCameraSetZoom',
        <String, dynamic>{'zoom': zoom},
      );
    } catch (_) {}
  }

  Future<void> nativeCameraSetExposureBias(double ev) async {
    try {
      await _videoChannel.invokeMethod<bool>(
        'nativeCameraSetExposureBias',
        <String, dynamic>{'ev': ev},
      );
    } catch (_) {}
  }

  Future<void> nativeCameraSetFlash(String mode) async {
    try {
      await _videoChannel.invokeMethod<bool>(
        'nativeCameraSetFlash',
        <String, dynamic>{'mode': mode},
      );
    } catch (_) {}
  }

  Future<bool> nativeCameraSetFocusPoint({
    required double x,
    required double y,
    required bool focus,
    required bool exposure,
  }) async {
    try {
      return (await _videoChannel.invokeMethod<bool>(
            'nativeCameraSetFocusPoint',
            <String, dynamic>{
              'x': x,
              'y': y,
              'focus': focus,
              'exposure': exposure,
            },
          )) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> nativeCameraUpdateGrading(Map<String, dynamic> args) async {
    try {
      await _videoChannel.invokeMethod<bool>(
        'nativeCameraUpdateGrading',
        args,
      );
    } catch (_) {}
  }

  Future<Uint8List> nativeCameraCapturePhoto(
    Map<String, dynamic> args,
  ) async {
    final bytes = await _videoChannel
        .invokeMethod<Uint8List>('nativeCameraCapturePhoto', args)
        .timeout(const Duration(seconds: 26));
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Foto gagal diambil oleh mesin kamera native.');
    }
    return bytes;
  }

  Future<void> nativeCameraStartVideo(Map<String, dynamic> args) async {
    await _videoChannel
        .invokeMethod<bool>('nativeCameraStartVideo', args)
        .timeout(const Duration(seconds: 10));
  }

  Future<String> nativeCameraStopVideo() async {
    final path = await _videoChannel
        .invokeMethod<String>('nativeCameraStopVideo')
        .timeout(const Duration(seconds: 30));
    if (path == null || path.isEmpty) {
      throw Exception('Video tidak berhasil disimpan.');
    }
    return path;
  }

  Future<void> nativeCameraPause() async {
    try {
      await _videoChannel.invokeMethod<bool>('nativeCameraPause');
    } catch (_) {}
  }

  Future<void> nativeCameraResume() async {
    try {
      await _videoChannel.invokeMethod<bool>('nativeCameraResume');
    } catch (_) {}
  }

  Future<void> nativeCameraDispose() async {
    try {
      await _videoChannel.invokeMethod<bool>('nativeCameraDispose');
    } catch (_) {}
  }

  Future<void> _ensureGalleryPermission() async {
    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        throw Exception('Izin akses Galeri iOS ditolak.');
      }
    }
  }
}
