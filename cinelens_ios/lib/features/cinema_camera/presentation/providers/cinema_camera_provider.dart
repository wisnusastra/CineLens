import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../data/repositories/cinema_camera_repository_impl.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/services/color_matrix_builder.dart';
import 'cinema_camera_state.dart';

final cinemaCameraRepositoryProvider = Provider<CinemaCameraRepository>((ref) {
  return CinemaCameraRepository();
});

final cinemaCameraProvider =
    AsyncNotifierProvider<CinemaCameraNotifier, CinemaCameraState>(
  CinemaCameraNotifier.new,
);

class CinemaCameraNotifier extends AsyncNotifier<CinemaCameraState> {
  CameraController? _controller;
  List<CameraDescription> _availableCameras = [];
  Timer? _focusIndicatorTimer;
  Timer? _recordingTimer;

  CameraController? get controller => _controller;

  @override
  Future<CinemaCameraState> build() async {
    ref.onDispose(() {
      _focusIndicatorTimer?.cancel();
      _recordingTimer?.cancel();
      _controller?.dispose();
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
    if (previousController != null) {
      await previousController.dispose();
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

  Future<void> startVideo24fpsRecording() async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null ||
        cam == null ||
        !cam.value.isInitialized ||
        current.isRecordingVideo) {
      return;
    }

    await cam.prepareForVideoRecording();
    await cam.startVideoRecording();

    state = AsyncData(
      current.copyWith(
        isRecordingVideo: true,
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

  Future<String?> stopVideo24fpsRecording() async {
    final current = state.valueOrNull;
    final cam = _controller;
    if (current == null ||
        cam == null ||
        !cam.value.isInitialized ||
        !current.isRecordingVideo) {
      return null;
    }

    _recordingTimer?.cancel();
    state = AsyncData(
      current.copyWith(
        isRecordingVideo: false,
        isProcessingVideo: true,
      ),
    );

    try {
      final XFile rawVideo = await cam.stopVideoRecording();
      final repository = ref.read(cinemaCameraRepositoryProvider);

      final savedPath = await repository.renderAndSaveGradedVideo(
        rawVideoPath: rawVideo.path,
        colorMatrix: current.activeColorMatrix,
        applyAnamorphicBars: current.isAnamorphicRatio,
      );

      state = AsyncData(
        current.copyWith(
          isProcessingVideo: false,
          recordingDuration: Duration.zero,
        ),
      );
      return savedPath;
    } catch (e) {
      state = AsyncData(
        current.copyWith(
          isProcessingVideo: false,
          recordingDuration: Duration.zero,
        ),
      );
      rethrow;
    }
  }
}
