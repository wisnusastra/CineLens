import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../data/repositories/cinema_camera_repository_impl.dart';
import '../../domain/entities/captured_media.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/film_look.dart';
import '../../domain/entities/pro_capture_capabilities.dart';
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
  bool _stabilizationActive = false;
  int _stabilizationMode = 0;

  /// True between a successful `startProRes` and the take being finalised.
  /// Kept off the UI state because it must survive the state being replaced
  /// while the native recorder is still writing.
  bool _proResRecording = false;

  /// Manual sliders emit dozens of values per second; the native call is
  /// coalesced so the device is not locked for configuration on every tick.
  Timer? _manualSyncTimer;
  Future<void> Function()? _pendingManualSync;

  CameraController? get controller => _controller;

  @override
  Future<CinemaCameraState> build() async {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      WidgetsBinding.instance.removeObserver(this);
      _focusIndicatorTimer?.cancel();
      _recordingTimer?.cancel();
      _manualSyncTimer?.cancel();
      _controller?.dispose();
      _controller = null;
    });

    final repository = ref.read(cinemaCameraRepositoryProvider);
    final tones = await repository.getAllTones();
    final savedPrefs = await repository.loadSavedPreferences();
    final captureSettings = await repository.loadCaptureSettings();
    final filmLook = await repository.loadFilmLook();
    final bakeLook = await repository.loadBakeLookIntoProRes();

    // Subscribe before the session starts: the native side reports the active
    // stabilisation mode as soon as `AVCaptureSession` starts running.
    repository.listenToStabilization(
      _handleStabilizationChanged,
      onProResFinished: _handleProResFinished,
      onExportProgress: _handleExportProgress,
    );

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

    // The plugin does not expose the device, so the manual limits (ISO range,
    // shutter range, Apple Log/ProRes support) are read from the running
    // session. This is retried because the session starts asynchronously.
    final capabilities = await _probeProCapabilities();

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
      videoStabilizationActive: _stabilizationActive,
      videoStabilizationMode: _stabilizationMode,
      proCapabilities: capabilities,
      filmLook: filmLook,
      bakeLookIntoProRes: bakeLook,
      iso: 400.0.clamp(capabilities.minIso, capabilities.maxIso).toDouble(),
      shutterSeconds: (1 / 48)
          .clamp(
            capabilities.minShutterSeconds,
            capabilities.maxShutterSeconds,
          )
          .toDouble(),
    );
  }

  /// Native export progress (0…1) from `AppDelegate.finishExport`.
  void _handleExportProgress(double progress) {
    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null || !current.isProcessingVideo) return;
    if (current.videoProcessingProgress != null &&
        (current.videoProcessingProgress! - progress).abs() < 0.005) {
      return;
    }
    state = AsyncData(
      current.copyWith(videoProcessingProgress: progress),
    );
  }

  void _handleStabilizationChanged(bool active, int mode) {
    _stabilizationActive = active;
    _stabilizationMode = mode;

    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.videoStabilizationActive == active &&
        current.videoStabilizationMode == mode) {
      return;
    }

    state = AsyncData(
      current.copyWith(
        videoStabilizationActive: active,
        videoStabilizationMode: mode,
      ),
    );
  }

  /// Called when the native recorder finished a take Dart did not stop.
  ///
  /// iOS interrupts ProRes when the app leaves the foreground or a call comes
  /// in; the master is already closed on disk, so it is just indexed and copied
  /// into the gallery instead of being lost. No LUT is baked into the master.
  Future<void> _handleProResFinished(String path) async {
    if (!_proResRecording) return;
    _proResRecording = false;
    _recordingTimer?.cancel();
    _writeRecordingStopped();
    await _persistProResTake(path);
  }

  /// Indexes a ProRes `.mov` master and copies it to Apple Photos.
  Future<void> _persistProResTake(String path) async {
    final current = state.valueOrNull;
    final repository = ref.read(cinemaCameraRepositoryProvider);

    if (current != null) {
      try {
        await repository.storeVideo(
          sourcePath: path,
          toneId: current.selectedTone.id,
          toneName: current.selectedTone.name,
          intensity: current.intensity,
          isAnamorphic: current.isAnamorphicRatio,
        );
      } catch (_) {
        // The gallery index is best effort; the file still exists.
      }
    }

    try {
      await repository.saveVideoToGallery(path);
    } catch (_) {
      // Apple Photos permission can be denied; the app gallery still has it.
    }
  }

  /// Frame size requested from the ProRes recorder.
  ///
  /// `MAX` is a photo-only preset, so its video path is the same 4K the plugin
  /// records with (see [CaptureResolution.videoPreset]).
  ({int width, int height}) _proResFrameSize(CaptureResolution resolution) {
    return switch (resolution) {
      CaptureResolution.fullHD => (width: 1920, height: 1080),
      CaptureResolution.uhd4K || CaptureResolution.maxSensor => (
          width: 3840,
          height: 2160
        ),
    };
  }

  // ------------------------------------------------------- manual controls

  Future<ProCaptureCapabilities> _probeProCapabilities() async {
    final repository = ref.read(cinemaCameraRepositoryProvider);
    var capabilities = ProCaptureCapabilities.unavailable;
    for (var attempt = 0; attempt < 6; attempt++) {
      capabilities = await repository.loadProCapabilities();
      if (capabilities.available) return capabilities;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return capabilities;
  }

  /// Re-reads the limits after the session was rebuilt with another format.
  Future<void> _refreshProCapabilities() async {
    final capabilities = await _probeProCapabilities();
    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null) return;

    state = AsyncData(
      current.copyWith(
        proCapabilities: capabilities,
        iso: current.iso
            .clamp(capabilities.minIso, capabilities.maxIso)
            .toDouble(),
        shutterSeconds: current.shutterSeconds
            .clamp(
              capabilities.minShutterSeconds,
              capabilities.maxShutterSeconds,
            )
            .toDouble(),
      ),
    );
    await _reapplyManualControls();
  }

  /// Replays the locked settings after the plugin rebuilt its capture session.
  Future<void> _reapplyManualControls() async {
    final current = state.valueOrNull;
    if (current == null) return;
    final repository = ref.read(cinemaCameraRepositoryProvider);

    try {
      if (current.appleLogEnabled) {
        await repository.setAppleLog(true);
      }
      if (current.manualExposureEnabled) {
        await repository.setManualExposure(
          shutterSeconds: current.shutterSeconds,
          iso: current.iso,
        );
      }
      if (current.manualWhiteBalanceEnabled) {
        await repository.setManualWhiteBalance(
          kelvin: current.whiteBalanceKelvin,
          tint: current.whiteBalanceTint,
        );
      }
      if (current.manualFocusEnabled) {
        await repository.setManualFocus(current.focusPosition);
      }
    } catch (_) {
      // The new session may still be starting; the native side replays the
      // stored values on its own `didStartRunning` notification too.
    }
  }

  Future<void> setManualExposureEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (enabled && !current.proCapabilities.available) {
      _setProError(
          'Kontrol manual belum siap. Coba lagi setelah pratinjau hidup.');
      return;
    }

    state = AsyncData(current.copyWith(manualExposureEnabled: enabled));
    if (!enabled) {
      await _runProAction(
        () => ref.read(cinemaCameraRepositoryProvider).setAutoExposure(),
      );
      return;
    }

    await _runProAction(
      () => ref.read(cinemaCameraRepositoryProvider).setManualExposure(
            shutterSeconds: current.shutterSeconds,
            iso: current.iso,
          ),
    );
  }

  /// Updates the shutter/ISO readout while the slider is dragged.
  ///
  /// The device is only reconfigured by [commitManualExposure] on release:
  /// locking an `AVCaptureDevice` ten times per second makes the preview stutter,
  /// and exposure changes are not something the operator can judge mid-drag.
  void previewManualExposure({double? shutterSeconds, double? iso}) {
    final current = state.valueOrNull;
    if (current == null) return;
    final capabilities = current.proCapabilities;

    final nextShutter = (shutterSeconds ?? current.shutterSeconds)
        .clamp(capabilities.minShutterSeconds, capabilities.maxShutterSeconds)
        .toDouble();
    final nextIso = (iso ?? current.iso)
        .clamp(capabilities.minIso, capabilities.maxIso)
        .toDouble();
    if (nextShutter == current.shutterSeconds && nextIso == current.iso) return;

    state = AsyncData(
      current.copyWith(
        manualExposureEnabled: true,
        shutterSeconds: nextShutter,
        iso: nextIso,
      ),
    );
  }

  /// Pushes the previewed shutter/ISO pair to the sensor.
  Future<void> commitManualExposure() async {
    final current = state.valueOrNull;
    if (current == null) return;

    await _runProAction(
      () => ref.read(cinemaCameraRepositoryProvider).setManualExposure(
            shutterSeconds: current.shutterSeconds,
            iso: current.iso,
          ),
    );
  }

  Future<void> setManualWhiteBalanceEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (enabled && !current.proCapabilities.available) {
      _setProError(
          'Kontrol manual belum siap. Coba lagi setelah pratinjau hidup.');
      return;
    }

    state = AsyncData(current.copyWith(manualWhiteBalanceEnabled: enabled));
    if (!enabled) {
      await _runProAction(
        () => ref.read(cinemaCameraRepositoryProvider).setAutoWhiteBalance(),
      );
      return;
    }

    await _runProAction(
      () => ref.read(cinemaCameraRepositoryProvider).setManualWhiteBalance(
            kelvin: current.whiteBalanceKelvin,
            tint: current.whiteBalanceTint,
          ),
    );
  }

  void previewManualWhiteBalance({int? kelvin, int? tint}) {
    final current = state.valueOrNull;
    if (current == null) return;

    final nextKelvin =
        (kelvin ?? current.whiteBalanceKelvin).clamp(1000, 14000);
    final nextTint = (tint ?? current.whiteBalanceTint).clamp(-150, 150);
    if (nextKelvin == current.whiteBalanceKelvin &&
        nextTint == current.whiteBalanceTint) {
      return;
    }

    state = AsyncData(
      current.copyWith(
        manualWhiteBalanceEnabled: true,
        whiteBalanceKelvin: nextKelvin,
        whiteBalanceTint: nextTint,
      ),
    );
  }

  /// Pushes the previewed Kelvin/tint pair to the sensor.
  Future<void> commitManualWhiteBalance() async {
    final current = state.valueOrNull;
    if (current == null) return;

    await _runProAction(
      () => ref.read(cinemaCameraRepositoryProvider).setManualWhiteBalance(
            kelvin: current.whiteBalanceKelvin,
            tint: current.whiteBalanceTint,
          ),
    );
  }

  Future<void> setManualFocusEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (enabled && !current.proCapabilities.available) {
      _setProError(
          'Kontrol manual belum siap. Coba lagi setelah pratinjau hidup.');
      return;
    }

    state = AsyncData(current.copyWith(manualFocusEnabled: enabled));
    if (!enabled) {
      await _runProAction(
        () => ref.read(cinemaCameraRepositoryProvider).setAutoFocus(),
      );
      return;
    }

    await _runProAction(
      () => ref
          .read(cinemaCameraRepositoryProvider)
          .setManualFocus(current.focusPosition),
    );
  }

  void previewManualFocus(double position) {
    final current = state.valueOrNull;
    if (current == null) return;

    final next = position.clamp(0.0, 1.0);
    if (next == current.focusPosition) return;

    state = AsyncData(
      current.copyWith(manualFocusEnabled: true, focusPosition: next),
    );
    _queueManualSync(
      () => _runProAction(
        () => ref.read(cinemaCameraRepositoryProvider).setManualFocus(next),
      ),
    );
  }

  Future<void> setAppleLog(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (enabled && !current.proCapabilities.supportsAppleLog) {
      _setProError('Perangkat ini belum mendukung Apple Log.');
      return;
    }

    try {
      final applied =
          await ref.read(cinemaCameraRepositoryProvider).setAppleLog(enabled);
      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(appleLogEnabled: applied));

      if (enabled && !applied) {
        _setProError('Apple Log ditolak format aktif. Pilih 4K/30 atau 1080p.');
      } else {
        _clearProError();
      }
    } on PlatformException catch (error) {
      _setProError(error.message ?? 'Apple Log tidak dapat diaktifkan.');
    }
  }

  /// Turns the native ProRes 422 recorder on/off for the next take.
  ///
  /// ProRes needs a 10-bit 4:2:2 sensor format, so the native side swaps the
  /// format only while recording. Toggling is refused mid-take because that
  /// would renegotiate the session under the writer.
  void setProResEnabled(bool enabled) {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.isRecordingVideo) {
      _setProError('ProRes tidak bisa diubah saat merekam.');
      return;
    }
    if (enabled && !current.proCapabilities.supportsProRes) {
      _setProError(
        'Perangkat ini tidak mendukung ProRes 422 (butuh iPhone 13 Pro ke atas).',
      );
      return;
    }

    state = AsyncData(current.copyWith(proResEnabled: enabled));
    _clearProError();
  }

  // ------------------------------------------------------------- film look

  /// Updates the film emulation strengths (grain, halation, bloom, vignette).
  ///
  /// Nothing is sent to the native side here: the parameters ride along with
  /// the next capture, so dragging a slider never reconfigures the camera.
  void setFilmLook(FilmLook look) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(filmLook: look));
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveFilmLook(look),
    );
  }

  void setBakeLookIntoProRes(bool enabled) {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.isRecordingVideo) {
      _setProError('Opsi LUT ProRes tidak bisa diubah saat merekam.');
      return;
    }
    state = AsyncData(current.copyWith(bakeLookIntoProRes: enabled));
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveBakeLookIntoProRes(enabled),
    );
  }

  /// Imports `.cube` files and selects the first one.
  ///
  /// Returns how many LUTs were added. The imported tone's matrix is only the
  /// preview approximation; the exact cube is used for photo, video and ProRes.
  Future<int> importCubeLuts() async {
    final current = state.valueOrNull;
    if (current == null) return 0;

    final repository = ref.read(cinemaCameraRepositoryProvider);
    final imported = await repository.importCubeLutsFromFilePicker();
    if (imported.isEmpty) return 0;

    final updatedTones = await repository.getAllTones();
    final selected = imported.first;

    state = AsyncData(
      current.copyWith(
        tones: updatedTones,
        selectedTone: selected,
        intensity: 1.0,
        clearLiveDraft: true,
      ),
    );
    await repository.savePreferences(toneId: selected.id, intensity: 1.0);
    return imported.length;
  }

  /// Coalesces slider callbacks into a single native call.
  void _queueManualSync(Future<void> Function() action) {
    _pendingManualSync = action;
    if (_manualSyncTimer != null) return;

    _manualSyncTimer = Timer(const Duration(milliseconds: 90), () {
      _manualSyncTimer = null;
      final pending = _pendingManualSync;
      _pendingManualSync = null;
      if (pending != null) unawaited(pending());
    });
  }

  Future<void> _runProAction(Future<void> Function() action) async {
    try {
      await action();
      _clearProError();
    } on PlatformException catch (error) {
      _setProError(error.message ?? 'Kamera menolak pengaturan manual ini.');
    } catch (error) {
      _setProError(_describeError(error));
    }
  }

  void _setProError(String message) {
    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(proControlError: message));
  }

  void _clearProError() {
    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null || current.proControlError == null) return;
    state = AsyncData(current.copyWith(clearProControlError: true));
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

      // A new format changes the ISO/shutter range and can enable or lose
      // Apple Log (it needs a specific 4K/1080p format), so the pro panel has to
      // re-read the device before the operator touches a slider.
      await _refreshProCapabilities();
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

  Future<void> resetZoom() => setZoomLevel(state.valueOrNull?.minZoom ?? 1.0);

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
    // A leftover custom-tone draft would otherwise keep the viewfinder on the
    // draft matrix, making the intensity slider look dead.
    state = AsyncData(
      current.copyWith(intensity: clamped, clearLiveDraft: true),
    );
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
    return ref
        .read(cinemaCameraRepositoryProvider)
        .buildPresetJsonString([tone]);
  }

  Future<void> exportSingleTone(CinemaTone tone,
      {Rect? shareOriginRect}) async {
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

    // The plugin implements tap-to-focus by switching the device back to
    // automatic, which would silently break a manual lock. Tap-tracking only
    // the subsystems the operator has not locked keeps the pro controls honest.
    final wantsFocus = !current.manualFocusEnabled;
    final wantsExposure = !current.manualExposureEnabled;
    if (!wantsFocus && !wantsExposure) return;

    try {
      if (wantsFocus) await cam.setFocusPoint(normalizedPoint);
      if (wantsExposure) await cam.setExposurePoint(normalizedPoint);
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
      await _refreshProCapabilities();
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
        colorMatrix: current.captureColorMatrix,
        applyAnamorphicBars: current.isAnamorphicRatio,
        look: current.nativeLook,
        toneId: current.selectedTone.isCustom ? null : current.selectedTone.id,
        intensity: current.intensity,
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

    // ProRes writes a 10-bit 4:2:2 `.mov` master through the native recorder.
    // The plugin's own writer is bypassed entirely for that take.
    if (current.proResEnabled && current.proCapabilities.supportsProRes) {
      await _startProResTake(current);
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
    _startRecordingClock();
  }

  /// Starts the native ProRes take and marks the UI as recording.
  ///
  /// Bubbles the [PlatformException] up so the shutter handler can toast the
  /// native reason (unsupported format, session not ready) instead of silently
  /// falling back to H.264 while the ProRes switch is on.
  Future<void> _startProResTake(CinemaCameraState current) async {
    final frame = _proResFrameSize(current.resolution);

    // Claim the take before awaiting: iOS can finish the recording on its own
    // (call, background) before this call returns, and that path reads the flag
    // to decide whether the file has been persisted already.
    _proResRecording = true;

    try {
      await ref.read(cinemaCameraRepositoryProvider).startProResRecording(
            width: frame.width,
            height: frame.height,
            fps: current.frameRate.value,
          );
    } catch (error) {
      _proResRecording = false;
      _recordingTimer?.cancel();
      _writeRecordingStopped();
      _setProError(_describeError(error));
      rethrow;
    }

    // A native interruption may have already finalised the take while this call
    // was in flight; `_handleProResFinished` cleared the flag for us.
    if (_disposed || !_proResRecording) return;

    final latest = state.valueOrNull ?? current;
    state = AsyncData(
      latest.copyWith(
        isRecordingVideo: true,
        isProcessingVideo: false,
        recordingDuration: Duration.zero,
      ),
    );
    _startRecordingClock();
  }

  void _startRecordingClock() {
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
    if (current == null) return null;

    final isProResTake = _proResRecording;
    final pluginRecording = cam?.value.isRecordingVideo ?? false;
    if (!current.isRecordingVideo && !isProResTake && !pluginRecording) {
      return null;
    }

    _recordingTimer?.cancel();
    if (!_disposed) {
      final bakingProRes = isProResTake && current.bakeLookIntoProRes;
      state = AsyncData(
        current.copyWith(
          isRecordingVideo: false,
          isProcessingVideo: true,
          recordingDuration: Duration.zero,
          videoProcessingLabel: bakingProRes
              ? 'Membakar look ke ProRes...'
              : isProResTake
                  ? 'Menyelesaikan ProRes...'
                  : 'Memproses video 24fps...',
          clearVideoProcessingProgress: true,
        ),
      );
    }

    if (isProResTake) return _finishProResTake(current);

    String? rawPath;
    try {
      if (cam != null && cam.value.isInitialized) {
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
        colorMatrix: current.captureColorMatrix,
        applyAnamorphicBars: current.isAnamorphicRatio,
        fps: current.frameRate.value,
        look: current.nativeLook,
        toneId: current.selectedTone.isCustom ? null : current.selectedTone.id,
        intensity: current.intensity,
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

  /// Stops the native ProRes take and indexes the ungraded `.mov` master.
  ///
  /// The master stays ungraded unless the user explicitly turns on
  /// "Sertakan look di ProRes": a flat master survives several grades, so the
  /// default only shows the tone in the live preview.
  Future<VideoStopResult?> _finishProResTake(CinemaCameraState current) async {
    _proResRecording = false;

    final repository = ref.read(cinemaCameraRepositoryProvider);
    String? path;
    try {
      path = await repository.stopProResRecording();
    } catch (error) {
      _writeRecordingStopped();
      _setProError(_describeError(error));
      return null;
    }

    if (path == null || path.isEmpty) {
      _writeRecordingStopped();
      return null;
    }

    String finalPath = path;
    String? warning;
    if (current.bakeLookIntoProRes && current.hasRenderableLook) {
      try {
        finalPath = await repository.bakeLookIntoProRes(
          path: finalPath,
          colorMatrix: current.captureColorMatrix,
          look: current.nativeLook,
          toneId:
              current.selectedTone.isCustom ? null : current.selectedTone.id,
          intensity: current.intensity,
        );
      } catch (error) {
        warning = 'Look gagal dibakar ke ProRes: ${_describeError(error)}';
      }
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
      warning = 'ProRes tidak masuk galeri CineLens: ${_describeError(error)}';
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
        videoProcessingLabel: 'Memproses video 24fps...',
        clearVideoProcessingProgress: true,
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
    if (current == null || !current.isRecordingVideo) return;

    _recordingTimer?.cancel();
    _writeRecordingStopped();

    // A ProRes take is closed by the native recorder; stop it explicitly so
    // the `.mov` gets finalised, then index whatever reached the disk.
    if (_proResRecording) {
      _proResRecording = false;
      try {
        final path = await ref
            .read(cinemaCameraRepositoryProvider)
            .stopProResRecording();
        if (path != null && path.isNotEmpty) {
          await _persistProResTake(path);
        }
      } catch (_) {
        // The recorder already finalised (and reported) the file.
      }
      return;
    }

    final cam = _controller;
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
