// lib/features/photo_editor/data/photo_editor_repository.dart

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';

/// Result of one native Photos-library import.
class ImportedMediaFile {
  final String path;
  final bool isVideo;

  const ImportedMediaFile({required this.path, required this.isVideo});

  static ImportedMediaFile? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    return ImportedMediaFile(
      path: path,
      isVideo: raw['type'] == 'video',
    );
  }
}

/// Bridge to the native Core Image editor and the iOS Photos picker.
///
/// Every render happens natively so the gallery editor can offer real curves,
/// HSL bands and the same film emulation cubes the camera uses, instead of the
/// 4×5 colour-matrix approximation of the live viewfinder.
class PhotoEditorRepository {
  const PhotoEditorRepository();

  static const MethodChannel _channel =
      MethodChannel(AppConstants.videoGraderChannel);

  /// A downscaled JPEG of the untouched media, used as the editor backdrop and
  /// as the "before" image while comparing.
  Future<Uint8List> loadPreview({
    required String path,
    required bool isVideo,
    int maxDimension = 1600,
    double timestampSeconds = 0.0,
  }) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'editorLoadPreview',
        <String, dynamic>{
          'path': path,
          'isVideo': isVideo,
          'maxDimension': maxDimension,
          'timestampSeconds': timestampSeconds,
        },
      ).timeout(const Duration(seconds: 90));
      if (bytes == null || bytes.isEmpty) {
        throw PlatformException(
          code: 'preview_failed',
          message: 'Pratinjau editor tidak dapat dibuat.',
        );
      }
      return bytes;
    } on MissingPluginException {
      throw PlatformException(
        code: 'unsupported',
        message: 'Editor hanya tersedia di aplikasi iOS.',
      );
    }
  }

  /// Renders the current adjustment set at preview resolution.
  Future<Uint8List> renderPreview({
    required String path,
    required bool isVideo,
    required Map<String, dynamic> payload,
    int maxDimension = 1600,
    double timestampSeconds = 0.0,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'editorRenderPreview',
      <String, dynamic>{
        'path': path,
        'isVideo': isVideo,
        'maxDimension': maxDimension,
        'timestampSeconds': timestampSeconds,
        ...payload,
      },
    ).timeout(const Duration(seconds: 60));
    if (bytes == null || bytes.isEmpty) {
      throw PlatformException(
        code: 'preview_failed',
        message: 'Render pratinjau gagal.',
      );
    }
    return bytes;
  }

  /// Renders the edit at full resolution and returns JPEG bytes.
  Future<Uint8List> exportPhoto({
    required String path,
    required Map<String, dynamic> payload,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'editorExportPhoto',
      <String, dynamic>{
        'path': path,
        ...payload,
        'quality': 0.95,
      },
    ).timeout(const Duration(minutes: 3));
    if (bytes == null || bytes.isEmpty) {
      throw PlatformException(
        code: 'export_failed',
        message: 'Foto hasil edit tidak dapat dirender.',
      );
    }
    return bytes;
  }

  /// Re-encodes a clip with the edit + tone burned in and returns its path.
  Future<String> exportVideo({
    required String path,
    required Map<String, dynamic> payload,
    int fps = 30,
  }) async {
    final exported = await _channel.invokeMethod<String>(
      'editorExportVideo',
      <String, dynamic>{
        'path': path,
        ...payload,
        'fps': fps,
      },
    ).timeout(const Duration(minutes: 40));
    if (exported == null || exported.isEmpty) {
      throw PlatformException(
        code: 'export_failed',
        message: 'Video hasil edit tidak dapat diekspor.',
      );
    }
    return exported;
  }

  /// Computes a Lightroom-style 1-tap Auto Tone recommendation natively from
  /// the image histogram (exposure, contrast, highlights, shadows, whites,
  /// blacks, temperature, tint, vibrance).
  Future<Map<String, double>> autoTone({
    required String path,
    required bool isVideo,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'editorAutoTone',
        <String, dynamic>{
          'path': path,
          'isVideo': isVideo,
        },
      ).timeout(const Duration(seconds: 30));
      if (raw == null) return const <String, double>{};
      final out = <String, double>{};
      raw.forEach((key, value) {
        if (key is String && value is num) {
          out[key] = value.toDouble();
        }
      });
      return out;
    } on MissingPluginException {
      return const <String, double>{};
    }
  }

  /// Computes a 64-bin RGB + Luminance histogram from the given rendered JPEG
  /// bytes natively via Core Image (`CIAreaHistogram`).
  Future<Map<String, List<double>>> computeHistogram(Uint8List jpegBytes) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'editorHistogram',
        <String, dynamic>{'bytes': jpegBytes},
      ).timeout(const Duration(seconds: 15));
      if (raw == null) return const <String, List<double>>{};
      final out = <String, List<double>>{};
      for (final channel in const <String>['r', 'g', 'b', 'luma']) {
        final list = raw[channel];
        if (list is List) {
          out[channel] = list
              .whereType<num>()
              .map((v) => v.toDouble().clamp(0.0, 1.0))
              .toList();
        }
      }
      return out;
    } on MissingPluginException {
      return const <String, List<double>>{};
    }
  }

  /// Computes RGB+Luma Histogram, 2D Luma Waveform (0–100 IRE), Vectorscope
  /// `(cb, cr)` points, and clipped/crushed percentages natively on iOS.
  Future<Map<String, dynamic>> computeScopes(Uint8List jpegBytes) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'editorScopes',
        <String, dynamic>{'bytes': jpegBytes},
      ).timeout(const Duration(seconds: 15));
      if (raw == null || raw.isEmpty) {
        final fallback = await computeHistogram(jpegBytes);
        return fallback;
      }
      final out = <String, dynamic>{};
      raw.forEach((k, v) {
        if (k is String) out[k] = v;
      });
      return out;
    } on MissingPluginException {
      return const <String, dynamic>{};
    }
  }

  /// Shot-to-Shot Color Match: analyses [sourcePath] vs [referencePath] and
  /// returns an ASC CDL (`cdlSlope`, `cdlOffset`, `cdlPower`, `cdlSaturation`)
  /// matching exposure, contrast, white balance and colour palette.
  Future<Map<String, dynamic>> matchColor({
    required String sourcePath,
    required bool isVideo,
    required String referencePath,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'editorMatchColor',
        <String, dynamic>{
          'sourcePath': sourcePath,
          'isVideo': isVideo,
          'referencePath': referencePath,
        },
      ).timeout(const Duration(seconds: 30));
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

  /// Offline Vision Neural Engine segmentation (`target`: `'subject'` or `'sky'`).
  /// Returns the generated PNG matte file path, or `null` if unavailable.
  Future<String?> generateAiMask({
    required String path,
    required bool isVideo,
    required String target,
  }) async {
    try {
      final maskPath = await _channel.invokeMethod<String>(
        'editorGenerateAiMask',
        <String, dynamic>{
          'path': path,
          'isVideo': isVideo,
          'target': target,
        },
      ).timeout(const Duration(seconds: 45));
      return (maskPath != null && maskPath.isNotEmpty) ? maskPath : null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Bakes the active editor color grade into a standard 33×33×33 `.cube` 3D LUT
  /// file and returns its local file path.
  Future<String?> exportCubeLut({
    required Map<String, dynamic> payload,
    String title = 'CineLens_Grade',
  }) async {
    try {
      final path = await _channel.invokeMethod<String>(
        'editorExportCubeLut',
        <String, dynamic>{
          ...payload,
          'title': title,
        },
      ).timeout(const Duration(seconds: 45));
      return (path != null && path.isNotEmpty) ? path : null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the system Photos picker (no permission prompt: PHPicker runs out
  /// of process) and copies the chosen photos/videos into the app.
  Future<List<ImportedMediaFile>> importFromPhotoLibrary({
    int limit = 40,
  }) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>(
        'importMediaFromPhotos',
        <String, dynamic>{'limit': limit},
      );
      if (raw == null) return const <ImportedMediaFile>[];
      return raw
          .map(ImportedMediaFile.tryParse)
          .whereType<ImportedMediaFile>()
          .toList();
    } on MissingPluginException {
      throw PlatformException(
        code: 'unsupported',
        message: 'Impor Apple Photos hanya tersedia di aplikasi iOS.',
      );
    }
  }
}

final Provider<PhotoEditorRepository> photoEditorRepositoryProvider =
    Provider<PhotoEditorRepository>((ref) => const PhotoEditorRepository());
