import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../data/repositories/cinema_camera_repository_impl.dart';
import '../../domain/entities/captured_media.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/services/color_matrix_builder.dart';
import 'cinema_camera_state.dart';

/// Outcome of stopping a recording.
///
/// [path] always points at a playable file; [warning] is non-null when the LUT
/// export or the Apple Photos upload failed but the raw footage survived.
class VideoStopResult {
  final String path;
  final String? warning;

  const VideoStopResult({required this.path, this.warning});
}

/// Outcome of a still capture. [bytes] is always safe to preview.
class PhotoCaptureResult {
  final Uint8List bytes;
  final String? warning;

  const PhotoCaptureResult({required this.bytes, this.warning});
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

  /// Profile the live controller was created with, used to skip needless
  /// rebuilds when the user re-selects the same quality.
  ResolutionPreset? _profilePreset;
  int? _profileFps;
  bool _isSwitchingProfile = false;
  double _lastAppliedZoom = 1.0;

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
    final captureSettings = await repository.loadCaptureSettings();

    final selectedTone = tones.firstWhere(
      (t) => t.id == savedPrefs.toneId,
      orElse: () => tones.first,
    );

    final resolution = CaptureResolution.values.firstWhere(
      (value) => value.name == captureSettings.resolution,
      orElse: () => CaptureResolution.maxSensor,
    );
    final frameRate = CaptureFrameRate.fromValue(
      captureSettings.frameRate ?? AppConstants.cinemaTargetFps,
    );

    _availableCameras = await availableCameras();
    if (_availableCameras.isEmpty) {
      throw Exception('Kamera tidak ditemukan pada perangkat iOS ini.');
    }

    final backCamera = _availableCameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => _availableCameras.first,
    );

    final bounds = await _initializeCameraController(
      backCamera,
      resolution: resolution,
      frameRate: frameRate,
      mode: CinemaCaptureMode.photo,
    );

    return CinemaCameraState(
      tones: tones,
      selectedTone: selectedTone,
      intensity: savedPrefs.intensity,
      minExposure: bounds.minExposure,
      maxExposure: bounds.maxExposure,
      lensDirection: backCamera.lensDirection,
      resolution: resolution,
      frameRate: frameRate,
      zoomLevel: bounds.minZoom,
      minZoom: bounds.minZoom,
      maxZoom: bounds.maxZoom,
    );
  }

  // -------------------------------------------------------------- profiles

  /// Highest bitrate the encoder can be pushed to without refusing the file.
  /// The stock plugin writes a very conservative stream, which is why 4K
  /// footage looked soft once you zoomed.
  int _videoBitrateFor(
    CaptureResolution resolution,
    CaptureFrameRate frameRate,
  ) {
    final base = resolution == CaptureResolution.fullHD ? 30000000 : 60000000;
    return frameRate == CaptureFrameRate.fps60 ? base * 3 ~/ 2 : base;
  }

  ResolutionPreset _presetFor(
    CaptureResolution resolution,
    CinemaCaptureMode mode,
  ) {
    return mode == CinemaCaptureMode.photo
        ? resolution.photoPreset
        : resolution.videoPreset;
  }

  Future<
      ({
        double minExposure,
        double maxExposure,
        double minZoom,
        double maxZoom,
      })> _initializeCameraController(
    CameraDescription cameraDescription, {
    required CaptureResolution resolution,
    required CaptureFrameRate frameRate,
    required CinemaCaptureMode mode,
  }) async {
    final preset = _presetFor(resolution, mode);
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
      preset,
      enableAudio: true,
      fps: frameRate.value,
      videoBitrate: _videoBitrateFor(resolution, frameRate),
      audioBitrate: 192000,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    await newController.initialize();
    await newController.setFlashMode(FlashMode.off);

    final minExp = await newController.getMinExposureOffset();
    final maxExp = await newController.getMaxExposureOffset();

    var minZoom = 1.0;
    var maxZoom = 1.0;
    try {
      minZoom = await newController.getMinZoomLevel();
      maxZoom = await newController.getMaxZoomLevel();
    } catch (_) {
      // Some front cameras report no zoom support.
    }

    _controller = newController;
    _activeCamera = cameraDescription;
    _profilePreset = preset;
    _profileFps = frameRate.value;
    _lastAppliedZoom = minZoom;
    return (
      minExposure: minExp,
      maxExposure: maxExp,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
  }

  /// Switches mode, resolution or frame rate and rebuilds the capture session
  /// only when the underlying profile actually changes.
  ///
  /// Photo mode runs at [ResolutionPreset.max] so the still output keeps the
  /// full sensor, video mode is kept at 4K where the writer is reliable.
  Future<void> applyCaptureProfile({
    CinemaCaptureMode? mode,
    CaptureResolution? resolution,
    CaptureFrameRate? frameRate,
  }) async {
    final current = state.valueOrNull;
    final description = _activeCamera;
    if (current == null || description == null || _isSwitchingProfile) return;
    if (current.isRecordingVideo || current.isCapturing) return;

    final nextMode = mode ?? current.captureMode;
    final nextResolution = resolution ?? current.resolution;
    final nextFrameRate = frameRate ?? current.frameRate;
    final nextPreset = _presetFor(nextResolution, nextMode);

    final needsRebuild = _controller == null ||
        _profilePreset != nextPreset ||
        _profileFps != nextFrameRate.value;

    _isSwitchingProfile = true;
    state = AsyncData(
      current.copyWith(
        captureMode: nextMode,
        resolution: nextResolution,
        frameRate: nextFrameRate,
      ),
    );

    if (!needsRebuild) {
      _isSwitchingProfile = false;
      await _persistCaptureSettings(nextResolution, nextFrameRate);
      return;
    }

    try {
      final bounds = await _initializeCameraController(
        description,
        resolution: nextResolution,
        frameRate: nextFrameRate,
        mode: nextMode,
      );
      if (_disposed) return;

      final latest = state.valueOrNull ?? current;
      state = AsyncData(
        latest.copyWith(
          captureMode: nextMode,
          resolution: nextResolution,
          frameRate: nextFrameRate,
          exposureOffset: 0.0,
          minExposure: bounds.minExposure,
          maxExposure: bounds.maxExposure,
          zoomLevel: bounds.minZoom,
          minZoom: bounds.minZoom,
          maxZoom: bounds.maxZoom,
          clearFocusPoint: true,
        ),
      );
      await _persistCaptureSettings(nextResolution, nextFrameRate);
    } catch (error) {
      final latest = state.valueOrNull ?? current;
      state = AsyncData(
        latest.copyWith(
          captureMode: current.captureMode,
          resolution: current.resolution,
          frameRate: current.frameRate,
        ),
      );
      rethrow;
    } finally {
      _isSwitchingProfile = false;
    }
  }

  Future<void> _persistCaptureSettings(
    CaptureResolution resolution,
    CaptureFrameRate frameRate,
  ) async {
    try {
      await ref.read(cinemaCameraRepositoryProvider).saveCaptureSettings(
            resolution: resolution.name,
            frameRate: frameRate.value,
          );
    } catch (_) {
      // Preferences are best effort; the session already runs correctly.
    }
  }

  Future<void> setCaptureMode(CinemaCaptureMode mode) {
    return applyCaptureProfile(mode: mode);
  }

  Future<void> setResolution(CaptureResolution resolution) {
    return applyCaptureProfile(resolution: resolution);
  }

  Future<void> setFrameRate(CaptureFrameRate frameRate) {
    return applyCaptureProfile(frameRate: frameRate);
  }

  // ------------------------------------------------------------------ zoom

  Future<void> setZoomLevel(double target) async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null || cam == null || !cam.value.isInitialized) return;

    final clamped = target.clamp(current.minZoom, current.maxZoom);
    if ((clamped - current.zoomLevel).abs() > 0.001) {
      state = AsyncData(current.copyWith(zoomLevel: clamped));
    }
    if ((clamped - _lastAppliedZoom).abs() < 0.004) return;

    _lastAppliedZoom = clamped;
    try {
      await cam.setZoomLevel(clamped);
    } catch (_) {
      // Zoom can be rejected while the session is reconfiguring.
    }
  }

  Future<void> resetZoom() =>
      setZoomLevel(state.valueOrNull?.minZoom ?? 1.0);

  // ------------------------------------------------------------ tones etc.

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

  Future<void> setFocusPoint(
    Offset normalizedPoint,
    Offset screenTapPosition,
  ) async {
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
        _isSwitchingProfile ||
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

    _isSwitchingProfile = true;
    try {
      final bounds = await _initializeCameraController(
        targetCamera,
        resolution: current.resolution,
        frameRate: current.frameRate,
        mode: current.captureMode,
      );
      if (_disposed) return;
      final latest = state.valueOrNull ?? current;
      state = AsyncData(
        latest.copyWith(
          lensDirection: targetDirection,
          flashMode: FlashMode.off,
          exposureOffset: 0.0,
          minExposure: bounds.minExposure,
          maxExposure: bounds.maxExposure,
          zoomLevel: bounds.minZoom,
          minZoom: bounds.minZoom,
          maxZoom: bounds.maxZoom,
          clearFocusPoint: true,
        ),
      );
    } finally {
      _isSwitchingProfile = false;
    }
  }

  Future<PhotoCaptureResult?> captureAndSavePhoto() async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null ||
        cam == null ||
        !cam.value.isInitialized ||
        current.isCapturing ||
        _isSwitchingProfile) {
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

      String? warning;
      try {
        await repository.storePhoto(
          jpegBytes: gradedBytes,
          toneId: current.selectedTone.id,
          toneName: current.selectedTone.name,
          intensity: current.intensity,
          isAnamorphic: current.isAnamorphicRatio,
        );
      } catch (error) {
        warning = 'Foto tidak masuk galeri CineLens: ${_describeError(error)}';
      }

      try {
        await repository.saveImageToIosGallery(gradedBytes);
      } catch (error) {
        final message =
            'Gagal menyimpan ke Apple Photos: ${_describeError(error)}';
        warning = warning == null ? message : '$warning · $message';
      }

      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(isCapturing: false));
      return PhotoCaptureResult(bytes: gradedBytes, warning: warning);
    } catch (e) {
      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(isCapturing: false));
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
    final current = state.valueOrNull;
    if (description == null || current == null) return null;

    try {
      await _initializeCameraController(
        description,
        resolution: current.resolution,
        frameRate: current.frameRate,
        mode: current.captureMode,
      );
      cam = _controller;
      return cam;
    } catch (_) {
      return null;
    }
  }

  Future<void> startVideo24fpsRecording() async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo || _isSwitchingProfile) {
      return;
    }

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

  /// Stops the recording and always leaves the UI in a usable state.
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
        fps: current.frameRate.value,
      );
    } catch (error) {
      finalPath = rawPath;
      warning = 'LUT gagal diterapkan: ${_describeError(error)}';
    }

    try {
      await repository.storeVideo(
        sourcePath: finalPath,
        toneId: current.selectedTone.id,
        toneName: current.selectedTone.name,
        intensity: current.intensity,
        isAnamorphic: current.isAnamorphicRatio,
      );
    } catch (error) {
      final message = 'Video tidak masuk galeri CineLens: '
          '${_describeError(error)}';
      warning = warning == null ? message : '$warning · $message';
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
      try {
        await repository.storeVideo(
          sourcePath: file.path,
          toneId: current.selectedTone.id,
          toneName: current.selectedTone.name,
          intensity: current.intensity,
          isAnamorphic: current.isAnamorphicRatio,
        );
      } catch (_) {
        // The gallery index is best effort here.
      }
      await repository.saveVideoToGallery(file.path);
    } catch (_) {
      // Nothing was written, or the system already aborted the file.
    }
  }

  /// Loads the local gallery index. Used by the gallery screen.
  Future<List<CapturedMedia>> loadCapturedMedia() {
    return ref.read(cinemaCameraRepositoryProvider).loadCapturedMedia();
  }

  Future<void> deleteCapturedMedia(CapturedMedia media) {
    return ref.read(cinemaCameraRepositoryProvider).deleteCapturedMedia(media);
  }

  String _describeError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}
