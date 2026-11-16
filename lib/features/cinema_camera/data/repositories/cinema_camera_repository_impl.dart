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
    final intensity = prefs.getDouble(AppConstants.prefToneIntensity) ?? 0.85;
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
          'fps': fps,
          if (look != null) 'look': look,
        },
      );
      if (gradedPath != null && gradedPath.isNotEmpty) {
        return gradedPath;
      }
    } on MissingPluginException {
      // No native grader on this platform.
    } on PlatformException {
      // Native export failed; the raw footage is still usable.
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
          'look': look,
        },
      );
      if (baked != null && baked.isNotEmpty) return baked;
    } on MissingPluginException {
      // Not on this platform.
    } on PlatformException {
      // Fall back to the ungraded master.
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
  }) {
    _videoChannel.setMethodCallHandler((call) async {
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
    final entries = await loadCapturedMedia();
    final remaining = entries.where((entry) => entry.id != media.id).toList();
    await _writeLibrary(remaining);

    try {
      final file = File(media.path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The index is already updated; a stale file is harmless.
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
