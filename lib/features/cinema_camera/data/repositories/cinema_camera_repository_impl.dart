import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/constants/app_constants.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/cinema_tone_preset_package.dart';
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
    final updated = existing.where((t) => t.id != toneId).toList();
    final encoded = jsonEncode(updated.map((t) => t.toJson()).toList());
    await prefs.setString(AppConstants.prefCustomTonesJson, encoded);
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
      throw const FormatException('File JSON tidak dapat dibaca oleh sistem iOS.');
    }

    return importTonesFromJsonString(rawJson);
  }

  Future<List<CinemaTone>> importTonesFromJsonString(String rawJson) async {
    final importedTones = CinemaTonePresetPackage.parseAndValidateTones(rawJson);
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
    final intensity =
        prefs.getDouble(AppConstants.prefToneIntensity) ?? 0.85;
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

  Future<Uint8List> renderGradedImage({
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
        canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), barHeight), barPaint);
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
  }) async {
    try {
      final gradedPath = await _videoChannel.invokeMethod<String>(
        'applyCinemaMatrixToVideo',
        <String, dynamic>{
          'inputPath': rawVideoPath,
          'matrix': colorMatrix,
          'anamorphic': applyAnamorphicBars,
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

  Future<void> saveVideoToGallery(String videoPath) async {
    await _ensureGalleryPermission();
    await Gal.putVideo(videoPath, album: AppConstants.albumName);
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
