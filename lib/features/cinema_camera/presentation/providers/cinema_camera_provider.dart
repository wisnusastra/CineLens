import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../data/repositories/cinema_camera_repository_impl.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/services/color_matrix_builder.dart';
import 'cinema_camera_state.dart';

/// Outcome of stopping a 24fps recording.
///
/// [path] always points at a playable file; [warning] is non-null when the LUT
/// export or the Apple Photos upload failed but the raw footage survived.
class VideoStopResult {
  final String path;
  final String? warning;

  const VideoStopResult({required this.path, this.warning});
}

final cinemaCameraRepositoryProvider = Provider<CinemaCameraRepository>((ref) {
  return CinemaCameraRepository();
});

final cinemaCameraProvider =
    AsyncNotifierProvider<CinemaCameraNotifier, CinemaCameraState>(
  CinemaCameraNotifier.new,
);

class CinemaCameraNotifier extends AsyncNotifier<CinemaCameraState>
    with WidgetsBindingObserver {
  CameraController? _controller;
  CameraDescription? _activeCamera;
  List<CameraDescription> _availableCameras = [];
  Timer? _focusIndicatorTimer;
  Timer? _recordingTimer;
  bool _disposed = false;

  CameraController? get controller => _controller;

  @override
  Future<CinemaCameraState> build() async {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      WidgetsBinding.instance.removeObserver(this);
      _focusIndicatorTimer?.cancel();
      _recordingTimer?.cancel();
      _controller?.dispose();
      _controller = null;
    });

    final repository = ref.read(cinemaCameraRepositoryProvider);
    final tones = await repository.getAllTones();
    final savedPrefs = await repository.loadSavedPreferences();

    final selectedTone = tones.firstWhere(
      (t) => t.id == savedPrefs.toneId,
      orElse: () => tones.first,
    );

    _availableCameras = await availableCameras();
    if (_availableCameras.isEmpty) {
      throw Exception('Kamera tidak ditemukan pada perangkat iOS ini.');
    }

    final backCamera = _availableCameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => _availableCameras.first,
    );

    final exposureBounds = await _initializeCameraController(backCamera);

    return CinemaCameraState(
      tones: tones,
      selectedTone: selectedTone,
      intensity: savedPrefs.intensity,
      minExposure: exposureBounds.min,
      maxExposure: exposureBounds.max,
      lensDirection: backCamera.lensDirection,
    );
  }

  Future<({double min, double max})> _initializeCameraController(
    CameraDescription cameraDescription,
  ) async {
    final previousController = _controller;
    _controller = null;
    if (previousController != null) {
      try {
        await previousController.dispose();
      } catch (_) {
        // The controller can already be torn down after an interruption.
      }
    }

    final newController = CameraController(
      cameraDescription,
      ResolutionPreset.veryHigh,
      enableAudio: true,
      fps: AppConstants.cinemaTargetFps,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    await newController.initialize();
    await newController.setFlashMode(FlashMode.off);

    final minExp = await newController.getMinExposureOffset();
    final maxExp = await newController.getMaxExposureOffset();

    _controller = newController;
    _activeCamera = cameraDescription;
    return (min: minExp, max: maxExp);
  }

  void setCaptureMode(CinemaCaptureMode mode) {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    state = AsyncData(current.copyWith(captureMode: mode));
  }

  void selectTone(CinemaTone tone) {
    final current = state.valueOrNull;
    if (current == null) return;

    state = AsyncData(
      current.copyWith(selectedTone: tone, clearLiveDraft: true),
    );
    ref.read(cinemaCameraRepositoryProvider).savePreferences(
          toneId: tone.id,
          intensity: current.intensity,
        );
  }

  void setIntensity(double value) {
    final current = state.valueOrNull;
    if (current == null) return;

    final clamped = value.clamp(0.0, 1.0);
    state = AsyncData(current.copyWith(intensity: clamped));
    ref.read(cinemaCameraRepositoryProvider).savePreferences(
          toneId: current.selectedTone.id,
          intensity: clamped,
        );
  }

  void updateLiveCustomDraft(CustomGradeParameters? draft) {
    final current = state.valueOrNull;
    if (current == null) return;
    if (draft == null) {
      state = AsyncData(current.copyWith(clearLiveDraft: true));
    } else {
      state = AsyncData(current.copyWith(liveDraftParameters: draft));
    }
  }

  Future<void> createAndSelectCustomTone({
    required String name,
    required String filmReference,
    required int accentColorHex,
    required CustomGradeParameters parameters,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final newTone = CinemaTone(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().toUpperCase(),
      filmReference: filmReference.trim().isEmpty
          ? 'Custom 24fps LUT'
          : filmReference.trim(),
      description:
          'Custom preset (Exp ${parameters.exposure.toStringAsFixed(1)}, Con ${parameters.contrast.toStringAsFixed(2)}, Sat ${parameters.saturation.toStringAsFixed(2)})',
      accentColorHex: accentColorHex,
      matrix: ColorMatrixBuilder.build(parameters),
      isCustom: true,
    );

    final repository = ref.read(cinemaCameraRepositoryProvider);
    await repository.saveCustomTone(newTone);
    final updatedTones = await repository.getAllTones();

    state = AsyncData(
      current.copyWith(
        tones: updatedTones,
        selectedTone: newTone,
        intensity: 1.0,
        clearLiveDraft: true,
      ),
    );

    await repository.savePreferences(toneId: newTone.id, intensity: 1.0);
  }

  Future<void> deleteCustomTone(String toneId) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final repository = ref.read(cinemaCameraRepositoryProvider);
    await repository.deleteCustomTone(toneId);
    final updatedTones = await repository.getAllTones();

    final fallbackTone = current.selectedTone.id == toneId
        ? updatedTones.first
        : current.selectedTone;

    state = AsyncData(
      current.copyWith(
        tones: updatedTones,
        selectedTone: fallbackTone,
      ),
    );
  }

  String getToneJsonString(CinemaTone tone) {
    return ref.read(cinemaCameraRepositoryProvider).buildPresetJsonString([tone]);
  }

  Future<void> exportSingleTone(CinemaTone tone, {Rect? shareOriginRect}) async {
    await ref.read(cinemaCameraRepositoryProvider).exportTonesViaShareSheet(
          [tone],
          shareOriginRect: shareOriginRect,
        );
  }

  Future<void> exportAllCustomTones({Rect? shareOriginRect}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final customTones = current.tones.where((t) => t.isCustom).toList();
    await ref.read(cinemaCameraRepositoryProvider).exportTonesViaShareSheet(
          customTones,
          shareOriginRect: shareOriginRect,
        );
  }

  Future<int> importTonesFromFile() async {
    final current = state.valueOrNull;
    if (current == null) return 0;

    final repository = ref.read(cinemaCameraRepositoryProvider);
    final imported = await repository.importTonesFromFilePicker();
    if (imported.isEmpty) return 0;

    final updatedTones = await repository.getAllTones();
    final newlySelected = imported.first;

    state = AsyncData(
      current.copyWith(
        tones: updatedTones,
        selectedTone: newlySelected,
        intensity: 1.0,
        clearLiveDraft: true,
      ),
    );
    await repository.savePreferences(toneId: newlySelected.id, intensity: 1.0);
    return imported.length;
  }

  Future<int> importTonesFromJsonText(String rawJson) async {
    final current = state.valueOrNull;
    if (current == null) return 0;

    final repository = ref.read(cinemaCameraRepositoryProvider);
    final imported = await repository.importTonesFromJsonString(rawJson);
    if (imported.isEmpty) return 0;

    final updatedTones = await repository.getAllTones();
    final newlySelected = imported.first;

    state = AsyncData(
      current.copyWith(
        tones: updatedTones,
        selectedTone: newlySelected,
        intensity: 1.0,
        clearLiveDraft: true,
      ),
    );
    await repository.savePreferences(toneId: newlySelected.id, intensity: 1.0);
    return imported.length;
  }

  void toggleAnamorphicRatio() {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    state = AsyncData(
      current.copyWith(isAnamorphicRatio: !current.isAnamorphicRatio),
    );
  }

  void toggleGrid() {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(showGrid: !current.showGrid));
  }

  Future<void> cycleFlashMode() async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null || cam == null || !cam.value.isInitialized) return;

    final nextMode = switch (current.flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };

    await cam.setFlashMode(nextMode);
    state = AsyncData(current.copyWith(flashMode: nextMode));
  }

  Future<void> setExposureOffset(double offset) async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null || cam == null || !cam.value.isInitialized) return;

    final clamped = offset.clamp(current.minExposure, current.maxExposure);
    await cam.setExposureOffset(clamped);
    state = AsyncData(current.copyWith(exposureOffset: clamped));
  }

  Future<void> setFocusPoint(Offset normalizedPoint, Offset screenTapPosition) async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null || cam == null || !cam.value.isInitialized) return;

    try {
      await cam.setFocusPoint(normalizedPoint);
      await cam.setExposurePoint(normalizedPoint);
    } catch (_) {}

    state = AsyncData(current.copyWith(focusPoint: screenTapPosition));
    _focusIndicatorTimer?.cancel();
    _focusIndicatorTimer = Timer(const Duration(milliseconds: 1400), () {
      final latest = state.valueOrNull;
      if (latest != null) {
        state = AsyncData(latest.copyWith(clearFocusPoint: true));
      }
    });
  }

  Future<void> switchCamera() async {
    final current = state.valueOrNull;
    if (current == null ||
        current.isRecordingVideo ||
        _availableCameras.length < 2) {
      return;
    }

    final targetDirection = current.lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    final targetCamera = _availableCameras.firstWhere(
      (cam) => cam.lensDirection == targetDirection,
      orElse: () => _availableCameras.first,
    );

    final bounds = await _initializeCameraController(targetCamera);
    state = AsyncData(
      current.copyWith(
        lensDirection: targetDirection,
        flashMode: FlashMode.off,
        exposureOffset: 0.0,
        minExposure: bounds.min,
        maxExposure: bounds.max,
        clearFocusPoint: true,
      ),
    );
  }

  Future<Uint8List?> captureAndSavePhoto() async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null ||
        cam == null ||
        !cam.value.isInitialized ||
        current.isCapturing) {
      return null;
    }

    state = AsyncData(current.copyWith(isCapturing: true));

    try {
      final XFile rawFile = await cam.takePicture();
      final Uint8List rawBytes = await rawFile.readAsBytes();

      final repository = ref.read(cinemaCameraRepositoryProvider);
      final Uint8List gradedBytes = await repository.renderGradedImage(
        rawBytes: rawBytes,
        colorMatrix: current.activeColorMatrix,
        applyAnamorphicBars: current.isAnamorphicRatio,
      );

      await repository.saveImageToIosGallery(gradedBytes);

      state = AsyncData(current.copyWith(isCapturing: false));
      return gradedBytes;
    } catch (e) {
      state = AsyncData(current.copyWith(isCapturing: false));
      rethrow;
    }
  }

  // ------------------------------------------------------- video recording

  /// Forces the platform controller back into a clean, non-recording state.
  ///
  /// When iOS aborts a recording on its own (incoming call, app sent to the
  /// background, memory pressure) it never tells Dart, so
  /// `controller.value.isRecordingVideo` stays `true` forever. From then on
  /// every `startVideoRecording()` throws "A video recording is already
  /// started." and every `stopVideoRecording()` throws "Video is not
  /// recording!". That is the "cannot stop the video + error" dead end, so we
  /// clear the stale flag — rebuilding the controller when it is stuck.
  Future<CameraController?> _ensureControllerIdle() async {
    var cam = _controller;
    if (cam == null || !cam.value.isInitialized) return cam;
    if (!cam.value.isRecordingVideo) return cam;

    try {
      await cam.stopVideoRecording();
    } catch (_) {
      // Already finalised by the system; nothing to salvage.
    }
    if (!cam.value.isRecordingVideo) return cam;

    final description = _activeCamera;
    if (description == null) return null;

    try {
      await _initializeCameraController(description);
      cam = _controller;
      return cam;
    } catch (_) {
      return null;
    }
  }

  Future<void> startVideo24fpsRecording() async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;

    final cam = await _ensureControllerIdle();
    if (cam == null || !cam.value.isInitialized) {
      throw Exception('Kamera belum siap. Tutup lalu buka lagi aplikasinya.');
    }

    try {
      await cam.prepareForVideoRecording();
      await cam.startVideoRecording();
    } catch (error) {
      _recordingTimer?.cancel();
      _writeRecordingStopped();
      rethrow;
    }

    if (_disposed) return;
    state = AsyncData(
      current.copyWith(
        isRecordingVideo: true,
        isProcessingVideo: false,
        recordingDuration: Duration.zero,
      ),
    );

    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final latest = state.valueOrNull;
      if (latest != null && latest.isRecordingVideo) {
        state = AsyncData(
          latest.copyWith(
            recordingDuration:
                latest.recordingDuration + const Duration(seconds: 1),
          ),
        );
      }
    });
  }

  /// Stops the 24fps recording and always leaves the UI in a usable state.
  ///
  /// Returns `null` only when no usable file exists (the system already
  /// dropped the recording); otherwise the returned path is always playable,
  /// with [VideoStopResult.warning] set when the LUT export or the Photos
  /// upload failed.
  Future<VideoStopResult?> stopVideo24fpsRecording() async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null || cam == null) return null;
    if (!current.isRecordingVideo && !cam.value.isRecordingVideo) return null;

    _recordingTimer?.cancel();
    if (!_disposed) {
      state = AsyncData(
        current.copyWith(
          isRecordingVideo: false,
          isProcessingVideo: true,
          recordingDuration: Duration.zero,
        ),
      );
    }

    String? rawPath;
    try {
      if (cam.value.isInitialized) {
        final rawVideo = await cam.stopVideoRecording();
        rawPath = rawVideo.path;
      }
    } catch (_) {
      // The system already closed the file; handled below.
    }

    if (rawPath == null) {
      _writeRecordingStopped();
      return null;
    }

    final repository = ref.read(cinemaCameraRepositoryProvider);
    var finalPath = rawPath;
    String? warning;

    try {
      finalPath = await repository.renderGradedVideo(
        rawVideoPath: rawPath,
        colorMatrix: current.activeColorMatrix,
        applyAnamorphicBars: current.isAnamorphicRatio,
      );
    } catch (error) {
      finalPath = rawPath;
      warning = 'LUT gagal diterapkan: ${_describeError(error)}';
    }

    try {
      await repository.saveVideoToGallery(finalPath);
    } catch (error) {
      warning = warning == null
          ? 'Tidak tersimpan ke Apple Photos: ${_describeError(error)}'
          : '$warning · tidak tersimpan ke Apple Photos';
    }

    _writeRecordingStopped();
    return VideoStopResult(path: finalPath, warning: warning);
  }

  void _writeRecordingStopped() {
    final latest = state.valueOrNull;
    if (_disposed || latest == null) return;
    state = AsyncData(
      latest.copyWith(
        isRecordingVideo: false,
        isProcessingVideo: false,
        recordingDuration: Duration.zero,
      ),
    );
  }

  /// A recording cannot survive the app leaving the foreground: iOS tears the
  /// capture session down without notifying Dart. Finalise what is on disk so
  /// the shutter never stays locked on "REC".
  ///
  /// `inactive` is deliberately ignored — on iOS it also fires for a Control
  /// Center swipe or a system alert, where the recording keeps running.
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    switch (lifecycleState) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_abandonInterruptedRecording());
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _abandonInterruptedRecording() async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null || !current.isRecordingVideo) return;

    _recordingTimer?.cancel();
    _writeRecordingStopped();

    if (cam == null || !cam.value.isInitialized) return;

    try {
      final file = await cam.stopVideoRecording();
      final repository = ref.read(cinemaCameraRepositoryProvider);
      await repository.saveVideoToGallery(file.path);
    } catch (_) {
      // Nothing was written, or the system already aborted the file.
    }
  }

  String _describeError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}
