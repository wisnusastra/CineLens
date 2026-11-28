import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../photo_editor/data/photo_editor_repository.dart';
import '../../data/repositories/cinema_camera_repository_impl.dart';
import '../../domain/entities/camera_recipe.dart';
import '../../domain/entities/captured_media.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/film_look.dart';
import '../../domain/entities/frame_format.dart';
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
  Timer? _focusIndicatorTimer;
  Timer? _recordingTimer;
  bool _disposed = false;

  bool _isSwitchingProfile = false;
  double _lastAppliedZoom = 1.0;
  bool _stabilizationActive = false;
  int _stabilizationMode = 0;

  /// True between a successful `startProRes` and the take being finalised.
  bool _proResRecording = false;

  /// True while the single-session native HEVC+Audio recorder is active.
  bool _nativeRecording = false;

  /// High-frequency DOP telemetry notifiers isolated from `CinemaCameraState`
  /// so 30–60Hz horizon tilt, audio VU meter, and live RGB scopes never trigger
  /// full-screen `CameraScreen` rebuilds (keeps UI locked at 120Hz ProMotion!).
  final ValueNotifier<double> horizonNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<double> audioPeakNotifier = ValueNotifier<double>(-60.0);
  final ValueNotifier<Map<String, dynamic>?> liveScopeNotifier =
      ValueNotifier<Map<String, dynamic>?>(null);
  final ValueNotifier<Duration> recordingDurationNotifier =
      ValueNotifier<Duration>(Duration.zero);

  /// Manual sliders emit dozens of values per second; the native call is
  /// coalesced so the device is not locked for configuration on every tick.
  Timer? _manualSyncTimer;
  Future<void> Function()? _pendingManualSync;

  @override
  Future<CinemaCameraState> build() async {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      WidgetsBinding.instance.removeObserver(this);
      _focusIndicatorTimer?.cancel();
      _recordingTimer?.cancel();
      _manualSyncTimer?.cancel();
      horizonNotifier.dispose();
      audioPeakNotifier.dispose();
      liveScopeNotifier.dispose();
      recordingDurationNotifier.dispose();
      unawaited(ref.read(cinemaCameraRepositoryProvider).nativeCameraDispose());
    });

    final repository = ref.read(cinemaCameraRepositoryProvider);

    // Subscribe before the native session starts so stabilization & DOP
    // telemetry are captured immediately.
    repository.listenToStabilization(
      _handleStabilizationChanged,
      onProResFinished: _handleProResFinished,
      onExportProgress: _handleExportProgress,
      onDopTelemetry: _handleDopTelemetry,
      onLiveScope: _handleLiveScope,
      onHardwareShutter: _handleHardwareShutter,
    );

    // Load all local preferences in parallel for instant cold-launch camera boot
    // (gallery thumbnail is hydrated lazily right after the viewfinder is live).
    final (
      tones,
      savedPrefs,
      captureSettings,
      filmLook,
      bakeLook,
      proImaging,
      (favoriteToneIds, recipes, freeStorageMB, watermarkCfg),
    ) = await (
      repository.getAllTones(),
      repository.loadSavedPreferences(),
      repository.loadCaptureSettings(),
      repository.loadFilmLook(),
      repository.loadBakeLookIntoProRes(),
      repository.loadProImagingSettings(),
      (
        repository.loadFavoriteToneIds(),
        repository.loadCameraRecipes(),
        repository.nativeCameraStorageFreeMB(),
        repository.loadCameraWatermarkSettings(),
      ).wait,
    ).wait;

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
    final frameFormat = CameraFrameFormat.fromName(proImaging.frameFormat);

    final initialMatrix = selectedTone.blendedMatrix(savedPrefs.intensity);
    final initialLook = filmLook.toNative(
      lutPath: selectedTone.isLutTone ? selectedTone.lutPath : null,
      lutSize: selectedTone.isLutTone ? selectedTone.lutSize : null,
      mix: selectedTone.isLutTone ? savedPrefs.intensity.clamp(0.0, 1.0) : 0,
    );

    // Boot our 100% Native Swift Single-Session Cinema Camera Engine.
    final initMap = await repository.nativeCameraInit(<String, dynamic>{
      'mode': CinemaCaptureMode.photo.name,
      'resolution': resolution.name,
      'fps': frameRate.value,
      'position': 'back',
      'hiRes48MP': proImaging.hiRes48MP,
      'antiFlicker': proImaging.antiFlickerMode,
      'grading': <String, dynamic>{
        'liveMetal': proImaging.liveMetalPreview,
        'matrix': initialMatrix,
        'toneId': selectedTone.isCustom ? null : selectedTone.id,
        'intensity': savedPrefs.intensity,
        'look': initialLook,
        'appleLogInput': false,
        'focusPeaking': false,
        'zebraStripes': false,
        'falseColor': false,
        'liveScope': false,
        'frameAspectRatio': frameFormat.aspectRatio,
        'anamorphicCrop': proImaging.anamorphicCrop,
        'apertureFStop': proImaging.apertureFStop,
        'rackToBackground': false,
        'watermarkStyle': watermarkCfg.style,
        'watermarkTheme': watermarkCfg.theme,
        'watermarkDateStamp': watermarkCfg.dateStamp,
        'watermarkText': watermarkCfg.signature.isNotEmpty
            ? watermarkCfg.signature
            : (selectedTone.id == 'standard' ? '' : selectedTone.name),
        'watermarkSpec1':
            '${resolution.isMaxSensor ? '4K' : resolution.label} · ${frameRate.label}FPS',
        'watermarkSpec2': '24mm · ${selectedTone.name.toUpperCase()}',
      },
    });

    final textureId = (initMap['textureId'] as num?)?.toInt();
    final previewWidth = (initMap['previewWidth'] as num?)?.toDouble() ?? 1080.0;
    final previewHeight =
        (initMap['previewHeight'] as num?)?.toDouble() ?? 1920.0;
    final minExposure = (initMap['minExposure'] as num?)?.toDouble() ?? -2.0;
    final maxExposure = (initMap['maxExposure'] as num?)?.toDouble() ?? 2.0;
    final minZoom = (initMap['minZoom'] as num?)?.toDouble() ?? 1.0;
    final maxZoom = (initMap['maxZoom'] as num?)?.toDouble() ?? 8.0;
    final zoomLevel = (initMap['zoomLevel'] as num?)?.toDouble() ?? minZoom;
    final hasHardwareDepth = initMap['hasHardwareDepth'] == true;
    final backLenses = _parseNativeLenses(initMap['lenses']);
    final wideIdx = backLenses.indexWhere((l) => l.label == '1×');
    final initialLensIdx = wideIdx >= 0 ? wideIdx : 0;
    _lastAppliedZoom = zoomLevel;

    var initialExposureOffset = 0.0;
    if (proImaging.highlightMetering) {
      final bias = (-0.9).clamp(minExposure, maxExposure);
      unawaited(repository.nativeCameraSetExposureBias(bias));
      initialExposureOffset = bias;
    }

    final rawCaps = initMap['capabilities'];
    final capabilities = rawCaps is Map
        ? ProCaptureCapabilities.fromMap(rawCaps)
        : await _probeProCapabilities();

    unawaited(repository.setDopTelemetry(horizon: true, audio: false));
    unawaited(repository.setVolumeShutterEnabled(proImaging.volumeShutter));
    unawaited(repository.cleanupStaleTempRecordings());
    // Hydrate gallery thumbnail right after camera viewfinder renders its first frame.
    Future<void>.microtask(refreshLatestThumb);

    return CinemaCameraState(
      tones: tones,
      selectedTone: selectedTone,
      intensity: savedPrefs.intensity,
      exposureOffset: initialExposureOffset,
      minExposure: minExposure,
      maxExposure: maxExposure,
      lensDirection: CameraLensDirection.back,
      resolution: resolution,
      frameRate: frameRate,
      zoomLevel: zoomLevel,
      minZoom: minZoom,
      maxZoom: maxZoom,
      videoStabilizationActive: _stabilizationActive,
      videoStabilizationMode: _stabilizationMode,
      proCapabilities: capabilities,
      filmLook: filmLook,
      bakeLookIntoProRes: bakeLook,
      processZeroEnabled: proImaging.processZero,
      saveDngRaw: proImaging.saveDngRaw,
      nightStack: proImaging.nightStack,
      heif10Bit: proImaging.heif10Bit,
      hiRes48MP: proImaging.hiRes48MP,
      apertureFStop: proImaging.apertureFStop,
      volumeShutterEnabled: proImaging.volumeShutter,
      timerSeconds: proImaging.timerSeconds,
      highlightMeteringEnabled: proImaging.highlightMetering,
      anamorphicCrop: proImaging.anamorphicCrop,
      anamorphicDesqueeze: proImaging.desqueeze,
      frameFormat: frameFormat,
      isAnamorphicRatio: frameFormat == CameraFrameFormat.scope239,
      directLutRecordingEnabled: proImaging.directLutRecording,
      liveMetalEnabled: proImaging.liveMetalPreview,
      liveMetalTextureId: textureId,
      previewWidth: previewWidth,
      previewHeight: previewHeight,
      hasHardwareDepth: hasHardwareDepth,
      latestGalleryThumbPath: null,
      backLenses: backLenses,
      activeBackLensIndex: initialLensIdx,
      favoriteToneIds: favoriteToneIds,
      recipes: recipes,
      freeStorageMB: freeStorageMB,
      watermarkStyle: watermarkCfg.style,
      watermarkTheme: watermarkCfg.theme,
      watermarkDateStamp: watermarkCfg.dateStamp,
      photographerSignature: watermarkCfg.signature,
      antiFlickerMode: proImaging.antiFlickerMode,
      iso: 400.0.clamp(capabilities.minIso, capabilities.maxIso).toDouble(),
      shutterSeconds: (proImaging.antiFlickerMode == '50hz' ? 1 / 50 : 1 / 48)
          .clamp(
            capabilities.minShutterSeconds,
            capabilities.maxShutterSeconds,
          )
          .toDouble(),
    );
  }

  /// Parses the hardware optical lens list reported by `NativeCinemaCameraEngine`
  /// (`0.5×`, `1×`, `2×`, `3×`).
  List<OpticalLensOption> _parseNativeLenses(Object? raw) {
    final options = <OpticalLensOption>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final id = item['id']?.toString() ?? '';
          final label = item['label']?.toString() ?? '1×';
          final initialZoom = (item['initialZoom'] as num?)?.toDouble() ?? 1.0;
          final focalMm = (item['focalMm'] as num?)?.toInt() ??
              (label.startsWith('0.5')
                  ? 13
                  : label == '35mm'
                      ? 35
                      : label.startsWith('2')
                          ? 48
                          : label.startsWith('3')
                              ? 77
                              : 24);
          if (id.isNotEmpty) {
            options.add(
              OpticalLensOption(
                id: id,
                label: label,
                initialZoom: initialZoom,
                focalMm: focalMm,
              ),
            );
          }
        }
      }
    }
    if (options.isEmpty) {
      options.add(const OpticalLensOption(id: 'default', label: '1×', focalMm: 24));
    }
    return options;
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

  void _handleDopTelemetry(double? horizonDegrees, double? audioPeakDb) {
    if (_disposed) return;
    if (horizonDegrees != null &&
        (horizonDegrees - horizonNotifier.value).abs() >= 0.25) {
      horizonNotifier.value = horizonDegrees;
    }
    if (audioPeakDb != null &&
        (audioPeakDb - audioPeakNotifier.value).abs() >= 0.8) {
      audioPeakNotifier.value = audioPeakDb;
    }
  }

  void _handleLiveScope(Map<String, dynamic> scope) {
    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null || !current.liveScopeEnabled) return;
    liveScopeNotifier.value = scope;
  }

  void _handleHardwareShutter() {
    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null || !current.volumeShutterEnabled) return;
    state = AsyncData(
      current.copyWith(hardwareShutterTick: current.hardwareShutterTick + 1),
    );
  }

  Map<String, dynamic> _liveMetalConfigFor(CinemaCameraState s) {
    final activeLensLabel = s.backLenses.isNotEmpty
        ? s.backLenses[s.activeBackLensIndex.clamp(0, s.backLenses.length - 1)]
            .focalLabel
        : '24mm';
    final spec1 = s.captureMode.isVideo
        ? '${s.resolution.isMaxSensor ? '4K' : s.resolution.label} · ${s.frameRate.label}FPS'
        : '${s.hiRes48MP ? '48MP' : '12MP'} · $activeLensLabel';
    final toneTag = s.selectedTone.id == 'standard'
        ? 'CINELENS PRO'
        : s.selectedTone.name.toUpperCase();
    final shortTone =
        toneTag.length > 14 ? toneTag.substring(0, 14).trim() : toneTag;
    final spec2 = '$activeLensLabel · $shortTone';
    return <String, dynamic>{
      'liveMetal': s.liveMetalEnabled,
      'matrix': s.captureColorMatrix,
      'toneId': s.selectedTone.isCustom ? null : s.selectedTone.id,
      'intensity': s.intensity,
      'look': s.nativeLook,
      'appleLogInput': s.appleLogEnabled,
      'focusPeaking': s.focusPeakingEnabled,
      'zebraStripes': s.zebraEnabled,
      'falseColor': s.falseColorEnabled,
      'liveScope': s.liveScopeEnabled,
      'splitCompare': s.splitCompareEnabled,
      'frameAspectRatio': s.effectiveFrameAspectRatio,
      'anamorphicCrop': s.anamorphicCrop,
      'watermarkStyle': s.watermarkStyle,
      'watermarkTheme': s.watermarkTheme,
      'watermarkDateStamp': s.watermarkDateStamp,
      'watermarkText': s.photographerSignature.isNotEmpty
          ? s.photographerSignature
          : (s.selectedTone.id == 'standard' ? '' : s.selectedTone.name),
      'watermarkSpec1': spec1,
      'watermarkSpec2': spec2,
    };
  }

  void _syncLiveMetalIfActive(CinemaCameraState next) {
    unawaited(
      ref
          .read(cinemaCameraRepositoryProvider)
          .nativeCameraUpdateGrading(_liveMetalConfigFor(next)),
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

  /// Replays the locked settings after the native session reconfigured.
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
    final next = current.copyWith(filmLook: look);
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveFilmLook(look),
    );
  }

  void setFrameFormat(CameraFrameFormat format) {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    final next = current.copyWith(
      frameFormat: format,
      isAnamorphicRatio: format == CameraFrameFormat.scope239,
    );
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveFrameFormat(format.name),
    );
  }

  void setSaveDngRaw(bool enabled) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(saveDngRaw: enabled));
    unawaited(ref.read(cinemaCameraRepositoryProvider).saveSaveDngRaw(enabled));
  }

  void setNightStack(bool enabled) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(nightStack: enabled));
    unawaited(ref.read(cinemaCameraRepositoryProvider).saveNightStack(enabled));
  }

  void setHeif10Bit(bool enabled) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(heif10Bit: enabled));
    unawaited(ref.read(cinemaCameraRepositoryProvider).saveHeif10Bit(enabled));
  }

  Future<void> setHiRes48MP(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    state = AsyncData(current.copyWith(hiRes48MP: enabled));
    unawaited(ref.read(cinemaCameraRepositoryProvider).saveHiRes48MP(enabled));
    if (current.captureMode == CinemaCaptureMode.photo) {
      await applyCaptureProfile(mode: current.captureMode);
    }
  }

  void setVolumeShutterEnabled(bool enabled) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(volumeShutterEnabled: enabled));
    final repo = ref.read(cinemaCameraRepositoryProvider);
    unawaited(repo.saveVolumeShutter(enabled));
    unawaited(repo.setVolumeShutterEnabled(enabled));
  }

  void cycleTimerSeconds() {
    final current = state.valueOrNull;
    if (current == null) return;
    final next = switch (current.timerSeconds) {
      0 => 3,
      3 => 10,
      _ => 0,
    };
    state = AsyncData(current.copyWith(timerSeconds: next));
    unawaited(ref.read(cinemaCameraRepositoryProvider).saveTimerSeconds(next));
  }

  Future<bool> importCubeFromPath(String path) async {
    final current = state.valueOrNull;
    if (current == null) return false;
    final repo = ref.read(cinemaCameraRepositoryProvider);
    final added = await repo.importCubeFileFromPath(path);
    if (added == null || _disposed) return false;
    final updatedTones = await repo.getAllTones();
    final latest = state.valueOrNull ?? current;
    state = AsyncData(
      latest.copyWith(
        tones: updatedTones,
        selectedTone: added,
        intensity: 1.0,
        clearLiveDraft: true,
      ),
    );
    await repo.savePreferences(toneId: added.id, intensity: 1.0);
    return true;
  }

  void setDirectLutRecordingEnabled(bool enabled) {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    state = AsyncData(current.copyWith(directLutRecordingEnabled: enabled));
    unawaited(
      ref
          .read(cinemaCameraRepositoryProvider)
          .saveDirectLutRecording(enabled),
    );
  }

  Future<void> setLiveMetalEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    final repo = ref.read(cinemaCameraRepositoryProvider);
    unawaited(repo.saveLiveMetalPreview(enabled));
    final next = current.copyWith(liveMetalEnabled: enabled);
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
  }

  Future<void> setDopOverlay({
    bool? focusPeaking,
    bool? zebra,
    bool? falseColor,
    bool? horizon,
    bool? audioMeter,
    bool? liveScope,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final next = current.copyWith(
      focusPeakingEnabled: focusPeaking ?? current.focusPeakingEnabled,
      zebraEnabled: zebra ?? current.zebraEnabled,
      falseColorEnabled: falseColor ?? current.falseColorEnabled,
      horizonLevelEnabled: horizon ?? current.horizonLevelEnabled,
      audioMeterEnabled: audioMeter ?? current.audioMeterEnabled,
      liveScopeEnabled: liveScope ?? current.liveScopeEnabled,
    );
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);

    final repo = ref.read(cinemaCameraRepositoryProvider);
    unawaited(
      repo.setDopTelemetry(
        horizon: next.horizonLevelEnabled,
        audio: next.audioMeterEnabled && next.captureMode.isVideo,
      ),
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

  void setProcessZeroEnabled(bool enabled) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(processZeroEnabled: enabled));
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveProcessZero(enabled),
    );
  }

  void setAnamorphicCrop(bool enabled) {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    state = AsyncData(current.copyWith(anamorphicCrop: enabled));
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveAnamorphicCrop(enabled),
    );
  }

  void setAnamorphicDesqueeze(double factor) {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    state = AsyncData(current.copyWith(anamorphicDesqueeze: factor));
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveAnamorphicDesqueeze(factor),
    );
  }

  /// Highlight-Weighted Metering (Chiaroscuro / Leica mode): protects bright
  /// sunlit highlights with `-0.9 EV` bias so shadows fall into deep ink-black.
  Future<void> setHighlightMeteringEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null) return;

    var nextOffset = current.exposureOffset;
    final repo = ref.read(cinemaCameraRepositoryProvider);
    if (!current.manualExposureEnabled) {
      final target = enabled
          ? (-0.9).clamp(current.minExposure, current.maxExposure)
          : 0.0;
      await repo.nativeCameraSetExposureBias(target);
      nextOffset = target;
    }

    state = AsyncData(
      current.copyWith(
        highlightMeteringEnabled: enabled,
        exposureOffset: nextOffset,
      ),
    );
    unawaited(repo.saveHighlightMetering(enabled));
  }

  /// Sets Anti-Flicker Shutter-Priority frequency (`'50hz'` | `'60hz'` | `'off'`).
  /// Default `'50hz'` eliminates indoor LED light flicker & rolling-shutter banding
  /// on 50Hz AC power grids (Indonesia/Asia/Europe) by keeping shutter quantized to
  /// `1/50`, `1/100`, `1/200`, `1/400`s while Auto-ISO glides smoothly.
  Future<void> setAntiFlickerMode(String mode) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final normalized = (mode == '60hz' || mode == 'off') ? mode : '50hz';
    if (current.antiFlickerMode == normalized) return;

    final repo = ref.read(cinemaCameraRepositoryProvider);
    state = AsyncData(current.copyWith(antiFlickerMode: normalized));
    await repo.nativeCameraSetAntiFlicker(normalized);
    unawaited(repo.saveAntiFlickerMode(normalized));
  }

  /// Locks shutter to the 180° cinema rule (`1/50s` = 172.8° when shooting
  /// 24fps under 50Hz AC mains to avoid LED flicker, or `1 / 2×fps`).
  Future<void> toggle180DegreeShutter() async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (!current.proCapabilities.available) {
      _setProError('Kontrol shutter manual belum siap.');
      return;
    }

    if (current.is180ShutterLocked) {
      await setManualExposureEnabled(false);
      return;
    }

    final targetShutter = current.target180ShutterSeconds.clamp(
      current.proCapabilities.minShutterSeconds,
      current.proCapabilities.maxShutterSeconds,
    );
    state = AsyncData(
      current.copyWith(
        manualExposureEnabled: true,
        shutterSeconds: targetShutter,
      ),
    );
    await _runProAction(
      () => ref.read(cinemaCameraRepositoryProvider).setManualExposure(
            shutterSeconds: targetShutter,
            iso: current.iso,
          ),
    );
  }

  /// Switches directly to another physical optical back lens (`0.5×` / `1×` /
  /// `2×` / `3×`) on the single owned native `AVCaptureSession`.
  Future<void> switchBackLens(int optionIndex) async {
    final current = state.valueOrNull;
    if (current == null ||
        current.isRecordingVideo ||
        _isSwitchingProfile ||
        optionIndex < 0 ||
        optionIndex >= current.backLenses.length) {
      return;
    }
    if (current.lensDirection == CameraLensDirection.back &&
        current.activeBackLensIndex == optionIndex) {
      return;
    }

    final option = current.backLenses[optionIndex];
    _isSwitchingProfile = true;
    try {
      final repo = ref.read(cinemaCameraRepositoryProvider);
      final cfg = await repo.nativeCameraConfigure(<String, dynamic>{
        'mode': current.captureMode.name,
        'resolution': current.resolution.name,
        'fps': current.frameRate.value,
        'position': 'back',
        'lensId': option.id,
        'initialZoom': option.initialZoom,
        'hiRes48MP': current.hiRes48MP,
        'antiFlicker': current.antiFlickerMode,
        'grading': _liveMetalConfigFor(current),
      });
      if (_disposed) return;

      final minExposure = (cfg['minExposure'] as num?)?.toDouble() ?? -2.0;
      final maxExposure = (cfg['maxExposure'] as num?)?.toDouble() ?? 2.0;
      final minZoom = (cfg['minZoom'] as num?)?.toDouble() ?? 1.0;
      final maxZoom = (cfg['maxZoom'] as num?)?.toDouble() ?? 8.0;
      final zoomLevel = (cfg['zoomLevel'] as num?)?.toDouble() ?? minZoom;
      final previewWidth =
          (cfg['previewWidth'] as num?)?.toDouble() ?? current.previewWidth;
      final previewHeight =
          (cfg['previewHeight'] as num?)?.toDouble() ?? current.previewHeight;
      final hasHardwareDepth = cfg['hasHardwareDepth'] == true;
      final rawCaps = cfg['capabilities'];
      final caps = rawCaps is Map
          ? ProCaptureCapabilities.fromMap(rawCaps)
          : current.proCapabilities;
      _lastAppliedZoom = zoomLevel;

      var nextOffset = 0.0;
      if (current.highlightMeteringEnabled && !current.manualExposureEnabled) {
        final bias = (-0.9).clamp(minExposure, maxExposure);
        unawaited(repo.nativeCameraSetExposureBias(bias));
        nextOffset = bias;
      }

      final latest = state.valueOrNull ?? current;
      state = AsyncData(
        latest.copyWith(
          lensDirection: CameraLensDirection.back,
          activeBackLensIndex: optionIndex,
          flashMode: FlashMode.off,
          exposureOffset: nextOffset,
          minExposure: minExposure,
          maxExposure: maxExposure,
          zoomLevel: zoomLevel,
          minZoom: minZoom,
          maxZoom: maxZoom,
          previewWidth: previewWidth,
          previewHeight: previewHeight,
          hasHardwareDepth: hasHardwareDepth,
          proCapabilities: caps,
          iso: latest.iso.clamp(caps.minIso, caps.maxIso).toDouble(),
          shutterSeconds: latest.shutterSeconds
              .clamp(caps.minShutterSeconds, caps.maxShutterSeconds)
              .toDouble(),
          clearFocusPoint: true,
        ),
      );
      await _reapplyManualControls();
    } finally {
      _isSwitchingProfile = false;
    }
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

  /// Switches mode, resolution, frame rate, or 48MP configuration directly on
  /// our owned single-session `NativeCinemaCameraEngine`.
  Future<void> applyCaptureProfile({
    CinemaCaptureMode? mode,
    CaptureResolution? resolution,
    CaptureFrameRate? frameRate,
  }) async {
    final current = state.valueOrNull;
    if (current == null || _isSwitchingProfile) return;
    if (current.isRecordingVideo || current.isCapturing) return;

    final nextMode = mode ?? current.captureMode;
    final nextResolution = resolution ?? current.resolution;
    final nextFrameRate = frameRate ?? current.frameRate;

    _isSwitchingProfile = true;
    final switched = current.copyWith(
      captureMode: nextMode,
      resolution: nextResolution,
      frameRate: nextFrameRate,
      cinematicRackedToBg: false,
    );
    state = AsyncData(switched);

    try {
      final repo = ref.read(cinemaCameraRepositoryProvider);
      final activeLens = current.backLenses.isNotEmpty
          ? current.backLenses[current.activeBackLensIndex
              .clamp(0, current.backLenses.length - 1)]
          : null;
      final cfg = await repo.nativeCameraConfigure(<String, dynamic>{
        'mode': nextMode.name,
        'resolution': nextResolution.name,
        'fps': nextFrameRate.value,
        'position':
            current.lensDirection == CameraLensDirection.front ? 'front' : 'back',
        if (activeLens != null &&
            current.lensDirection == CameraLensDirection.back) ...<String, dynamic>{
          'lensId': activeLens.id,
          'initialZoom': activeLens.initialZoom,
        },
        'hiRes48MP': current.hiRes48MP,
        'antiFlicker': current.antiFlickerMode,
        'grading': _liveMetalConfigFor(switched),
      });
      if (_disposed) return;

      final minExposure = (cfg['minExposure'] as num?)?.toDouble() ?? -2.0;
      final maxExposure = (cfg['maxExposure'] as num?)?.toDouble() ?? 2.0;
      final minZoom = (cfg['minZoom'] as num?)?.toDouble() ?? 1.0;
      final maxZoom = (cfg['maxZoom'] as num?)?.toDouble() ?? 8.0;
      final zoomLevel = (cfg['zoomLevel'] as num?)?.toDouble() ?? minZoom;
      final previewWidth =
          (cfg['previewWidth'] as num?)?.toDouble() ?? current.previewWidth;
      final previewHeight =
          (cfg['previewHeight'] as num?)?.toDouble() ?? current.previewHeight;
      final hasHardwareDepth = cfg['hasHardwareDepth'] == true;
      final rawCaps = cfg['capabilities'];
      final caps = rawCaps is Map
          ? ProCaptureCapabilities.fromMap(rawCaps)
          : current.proCapabilities;
      _lastAppliedZoom = zoomLevel;

      var nextOffset = 0.0;
      if (current.highlightMeteringEnabled && !current.manualExposureEnabled) {
        final bias = (-0.9).clamp(minExposure, maxExposure);
        unawaited(repo.nativeCameraSetExposureBias(bias));
        nextOffset = bias;
      }

      final latest = state.valueOrNull ?? switched;
      final synced = latest.copyWith(
        captureMode: nextMode,
        resolution: nextResolution,
        frameRate: nextFrameRate,
        exposureOffset: nextOffset,
        minExposure: minExposure,
        maxExposure: maxExposure,
        zoomLevel: zoomLevel,
        minZoom: minZoom,
        maxZoom: maxZoom,
        previewWidth: previewWidth,
        previewHeight: previewHeight,
        hasHardwareDepth: hasHardwareDepth,
        proCapabilities: caps,
        iso: latest.iso.clamp(caps.minIso, caps.maxIso).toDouble(),
        shutterSeconds: latest.shutterSeconds
            .clamp(caps.minShutterSeconds, caps.maxShutterSeconds)
            .toDouble(),
        clearFocusPoint: true,
      );
      state = AsyncData(synced);
      await _persistCaptureSettings(nextResolution, nextFrameRate);
      await _reapplyManualControls();

      unawaited(
        repo.setDopTelemetry(
          horizon: synced.horizonLevelEnabled,
          audio: synced.audioMeterEnabled && synced.captureMode.isVideo,
        ),
      );
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
    if (current == null) return;

    final clamped = target.clamp(current.minZoom, current.maxZoom);
    if ((clamped - current.zoomLevel).abs() > 0.001) {
      state = AsyncData(current.copyWith(zoomLevel: clamped));
    }
    if ((clamped - _lastAppliedZoom).abs() < 0.004) return;

    _lastAppliedZoom = clamped;
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).nativeCameraSetZoom(clamped),
    );
  }

  Future<void> resetZoom() => setZoomLevel(state.valueOrNull?.minZoom ?? 1.0);

  // ------------------------------------------------------------ tones etc.

  void selectTone(CinemaTone tone) {
    final current = state.valueOrNull;
    if (current == null) return;

    final next = current.copyWith(
      selectedTone: tone,
      clearLiveDraft: true,
      clearActiveRecipeSlot: true,
    );
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
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
    final next = current.copyWith(intensity: clamped, clearLiveDraft: true);
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
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
    if (current == null) return;

    final nextMode = switch (current.flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };

    await ref
        .read(cinemaCameraRepositoryProvider)
        .nativeCameraSetFlash(nextMode.name);
    state = AsyncData(current.copyWith(flashMode: nextMode));
  }

  Future<void> setExposureOffset(double offset) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final clamped = offset.clamp(current.minExposure, current.maxExposure);
    await ref
        .read(cinemaCameraRepositoryProvider)
        .nativeCameraSetExposureBias(clamped);
    state = AsyncData(current.copyWith(exposureOffset: clamped));
  }

  Future<void> setFocusPoint(
    Offset normalizedPoint,
    Offset screenTapPosition,
  ) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final wantsFocus = !current.manualFocusEnabled;
    final wantsExposure = !current.manualExposureEnabled;
    if (!wantsFocus && !wantsExposure) return;

    await ref
        .read(cinemaCameraRepositoryProvider)
        .nativeCameraSetFocusPoint(
          x: normalizedPoint.dx,
          y: normalizedPoint.dy,
          focus: wantsFocus,
          exposure: wantsExposure,
        );

    if (_disposed) return;
    final nowState = state.valueOrNull ?? current;
    state = AsyncData(
      nowState.copyWith(
        focusPoint: screenTapPosition,
        lastFocusNormalized: normalizedPoint,
        isAeAfLocked: false,
      ),
    );
    _focusIndicatorTimer?.cancel();
    _focusIndicatorTimer = Timer(const Duration(milliseconds: 1400), () {
      final latest = state.valueOrNull;
      if (latest != null && !latest.isAeAfLocked) {
        state = AsyncData(latest.copyWith(clearFocusPoint: true));
      }
    });
  }

  /// Long-Press AE/AF Lock on the viewfinder: locks focus & exposure solidly
  /// at the tapped subject until the user taps again or taps the lock badge.
  Future<void> lockAeAf(
    Offset normalizedPoint,
    Offset screenTapPosition,
  ) async {
    final current = state.valueOrNull;
    if (current == null) return;
    _focusIndicatorTimer?.cancel();
    await ref.read(cinemaCameraRepositoryProvider).nativeCameraSetAeAfLock(
          locked: true,
          x: normalizedPoint.dx,
          y: normalizedPoint.dy,
        );
    if (_disposed) return;
    final latest = state.valueOrNull ?? current;
    state = AsyncData(
      latest.copyWith(
        isAeAfLocked: true,
        focusPoint: screenTapPosition,
        lastFocusNormalized: normalizedPoint,
      ),
    );
  }

  Future<void> unlockAeAf() async {
    final current = state.valueOrNull;
    if (current == null || !current.isAeAfLocked) return;
    await ref.read(cinemaCameraRepositoryProvider).nativeCameraSetAeAfLock(
          locked: false,
          x: 0.5,
          y: 0.5,
        );
    if (_disposed) return;
    final latest = state.valueOrNull ?? current;
    state = AsyncData(
      latest.copyWith(isAeAfLocked: false, clearFocusPoint: true),
    );
  }

  void toggleFavoriteTone(String toneId) {
    final current = state.valueOrNull;
    if (current == null || toneId == 'standard') return;
    final nextFavs = Set<String>.from(current.favoriteToneIds);
    if (nextFavs.contains(toneId)) {
      nextFavs.remove(toneId);
    } else {
      nextFavs.add(toneId);
    }
    state = AsyncData(current.copyWith(favoriteToneIds: nextFavs));
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveFavoriteToneIds(nextFavs),
    );
  }

  void toggleSplitCompare() {
    final current = state.valueOrNull;
    if (current == null) return;
    final next = current.copyWith(
      splitCompareEnabled: !current.splitCompareEnabled,
    );
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
  }

  void toggleZenMode() {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(zenModeEnabled: !current.zenModeEnabled));
  }

  void cycleTimelapseInterval() {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    const steps = <double>[0.0, 1.0, 2.0, 5.0, 10.0];
    final idx = steps.indexWhere((s) => (s - current.timelapseInterval).abs() < 0.1);
    final next = steps[(idx + 1) % steps.length];
    state = AsyncData(current.copyWith(timelapseInterval: next));
  }

  void setTimelapseInterval(double seconds) {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo) return;
    state = AsyncData(current.copyWith(timelapseInterval: seconds.clamp(0.0, 30.0)));
  }

  void setCameraWatermark({
    String? style,
    String? theme,
    bool? dateStamp,
  }) {
    final current = state.valueOrNull;
    if (current == null) return;
    final next = current.copyWith(
      watermarkStyle: style ?? current.watermarkStyle,
      watermarkTheme: theme ?? current.watermarkTheme,
      watermarkDateStamp: dateStamp ?? current.watermarkDateStamp,
    );
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
    unawaited(
      ref.read(cinemaCameraRepositoryProvider).saveCameraWatermarkSettings(
            style: style,
            theme: theme,
            dateStamp: dateStamp,
          ),
    );
  }

  Future<void> setPhotographerSignature(String signature) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final trimmed = signature.trim();
    final next = current.copyWith(photographerSignature: trimmed);
    state = AsyncData(next);
    _syncLiveMetalIfActive(next);
    await ref
        .read(cinemaCameraRepositoryProvider)
        .savePhotographerSignature(trimmed);
  }

  Future<void> togglePauseVideoRecording() async {
    final current = state.valueOrNull;
    if (current == null || !current.isRecordingVideo) return;
    final repo = ref.read(cinemaCameraRepositoryProvider);
    if (current.isRecordingPaused) {
      await repo.nativeCameraResumeVideo();
      if (_disposed) return;
      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(isRecordingPaused: false));
    } else {
      await repo.nativeCameraPauseVideo();
      if (_disposed) return;
      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(isRecordingPaused: true));
    }
  }

  Future<void> refreshStorageInfo() async {
    final freeMB =
        await ref.read(cinemaCameraRepositoryProvider).nativeCameraStorageFreeMB();
    final current = state.valueOrNull;
    if (_disposed || current == null || freeMB <= 0) return;
    state = AsyncData(current.copyWith(freeStorageMB: freeMB));
  }

  /// Resets any active `C1`–`C4` recipe cleanly back to Standard Photo/Video defaults.
  Future<void> resetRecipeToStandard() async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo || _isSwitchingProfile) {
      return;
    }
    final stdTone = current.tones.firstWhere(
      (t) => t.id == 'standard',
      orElse: () => current.tones.first,
    );
    selectTone(stdTone);
    setIntensity(1.0);
    setFrameFormat(CameraFrameFormat.full);
    setProcessZeroEnabled(false);
    setNightStack(false);
    await setHiRes48MP(false);
    setHeif10Bit(false);
    await setHighlightMeteringEnabled(false);
    await setExposureOffset(0.0);
    final latest = state.valueOrNull;
    if (!_disposed && latest != null) {
      state = AsyncData(latest.copyWith(clearActiveRecipeSlot: true));
    }
  }

  /// Recalls a saved Fujifilm-style recipe (`C1`–`C4`) in 1 tap.
  /// Tapping the already-active recipe slot toggles it OFF back to Standard!
  /// Returns `true` when activated, `false` when toggled off.
  Future<bool> applyRecipe(int slot) async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo || _isSwitchingProfile) {
      return false;
    }
    if (current.activeRecipeSlot == slot) {
      await resetRecipeToStandard();
      return false;
    }
    final recipe = current.recipes.firstWhere(
      (r) => r.slot == slot,
      orElse: () => CameraRecipe.defaults.first,
    );
    final targetTone = current.tones.firstWhere(
      (t) => t.id == recipe.toneId,
      orElse: () => current.selectedTone,
    );
    final targetMode =
        recipe.isVideo ? CinemaCaptureMode.video24fps : CinemaCaptureMode.photo;
    final targetRes = CaptureResolution.values.firstWhere(
      (r) => r.name == recipe.resolutionName,
      orElse: () =>
          recipe.isVideo ? CaptureResolution.uhd4K : CaptureResolution.maxSensor,
    );
    final targetFps = CaptureFrameRate.fromValue(recipe.fps);
    final targetFrame = recipe.frameFormat;

    selectTone(targetTone);
    setIntensity(recipe.intensity);
    setFrameFormat(targetFrame);
    setProcessZeroEnabled(recipe.processZero);
    setNightStack(recipe.nightStack);
    await setHiRes48MP(recipe.hiRes48MP);
    setHeif10Bit(recipe.heif10Bit);
    await setHighlightMeteringEnabled(recipe.highlightMetering);
    if (targetMode != current.captureMode) {
      await setCaptureMode(targetMode);
    }
    if (recipe.isVideo) {
      await setResolution(targetRes);
      await setFrameRate(targetFps);
    }
    final latest = state.valueOrNull;
    if (!_disposed && latest != null) {
      state = AsyncData(latest.copyWith(activeRecipeSlot: slot));
    }
    return true;
  }

  /// Overwrites recipe slot `C1`–`C4` with the current camera configuration.
  Future<CameraRecipe?> saveCurrentToRecipe(int slot, {String? name}) async {
    final current = state.valueOrNull;
    if (current == null) return null;
    final cleanName = (name != null && name.trim().isNotEmpty)
        ? name.trim().toUpperCase()
        : current.selectedTone.name.toUpperCase().split(' ').take(2).join(' ');
    final updatedRecipe = CameraRecipe(
      slot: slot,
      name: cleanName,
      isVideo: current.captureMode.isVideo,
      toneId: current.selectedTone.id,
      intensity: current.intensity,
      frameFormatName: current.frameFormat.name,
      resolutionName: current.resolution.name,
      fps: current.frameRate.value,
      processZero: current.processZeroEnabled,
      nightStack: current.nightStack,
      hiRes48MP: current.hiRes48MP,
      heif10Bit: current.heif10Bit,
      highlightMetering: current.highlightMeteringEnabled,
    );
    final nextList = current.recipes
        .map((r) => r.slot == slot ? updatedRecipe : r)
        .toList(growable: false);
    state = AsyncData(
      current.copyWith(recipes: nextList, activeRecipeSlot: slot),
    );
    await ref.read(cinemaCameraRepositoryProvider).saveCameraRecipes(nextList);
    return updatedRecipe;
  }

  Future<void> switchCamera() async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo || _isSwitchingProfile) {
      return;
    }

    final targetDirection = current.lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    _isSwitchingProfile = true;
    try {
      final repo = ref.read(cinemaCameraRepositoryProvider);
      final activeLens = current.backLenses.isNotEmpty
          ? current.backLenses[current.activeBackLensIndex
              .clamp(0, current.backLenses.length - 1)]
          : null;
      final cfg = await repo.nativeCameraConfigure(<String, dynamic>{
        'mode': current.captureMode.name,
        'resolution': current.resolution.name,
        'fps': current.frameRate.value,
        'position':
            targetDirection == CameraLensDirection.front ? 'front' : 'back',
        if (targetDirection == CameraLensDirection.back &&
            activeLens != null) ...<String, dynamic>{
          'lensId': activeLens.id,
          'initialZoom': activeLens.initialZoom,
        },
        'hiRes48MP': current.hiRes48MP,
        'antiFlicker': current.antiFlickerMode,
        'grading': _liveMetalConfigFor(current),
      });
      if (_disposed) return;

      final minExposure = (cfg['minExposure'] as num?)?.toDouble() ?? -2.0;
      final maxExposure = (cfg['maxExposure'] as num?)?.toDouble() ?? 2.0;
      final minZoom = (cfg['minZoom'] as num?)?.toDouble() ?? 1.0;
      final maxZoom = (cfg['maxZoom'] as num?)?.toDouble() ?? 8.0;
      final zoomLevel = (cfg['zoomLevel'] as num?)?.toDouble() ?? minZoom;
      final previewWidth =
          (cfg['previewWidth'] as num?)?.toDouble() ?? current.previewWidth;
      final previewHeight =
          (cfg['previewHeight'] as num?)?.toDouble() ?? current.previewHeight;
      final hasHardwareDepth = cfg['hasHardwareDepth'] == true;
      final rawCaps = cfg['capabilities'];
      final caps = rawCaps is Map
          ? ProCaptureCapabilities.fromMap(rawCaps)
          : current.proCapabilities;
      _lastAppliedZoom = zoomLevel;

      var nextOffset = 0.0;
      if (current.highlightMeteringEnabled && !current.manualExposureEnabled) {
        final bias = (-0.9).clamp(minExposure, maxExposure);
        unawaited(repo.nativeCameraSetExposureBias(bias));
        nextOffset = bias;
      }

      final latest = state.valueOrNull ?? current;
      state = AsyncData(
        latest.copyWith(
          lensDirection: targetDirection,
          flashMode: FlashMode.off,
          exposureOffset: nextOffset,
          minExposure: minExposure,
          maxExposure: maxExposure,
          zoomLevel: zoomLevel,
          minZoom: minZoom,
          maxZoom: maxZoom,
          previewWidth: previewWidth,
          previewHeight: previewHeight,
          hasHardwareDepth: hasHardwareDepth,
          proCapabilities: caps,
          iso: latest.iso.clamp(caps.minIso, caps.maxIso).toDouble(),
          shutterSeconds: latest.shutterSeconds
              .clamp(caps.minShutterSeconds, caps.maxShutterSeconds)
              .toDouble(),
          clearFocusPoint: true,
        ),
      );
      await _reapplyManualControls();
    } finally {
      _isSwitchingProfile = false;
    }
  }

  Future<PhotoCaptureResult?> captureAndSavePhoto() async {
    final current = state.valueOrNull;
    if (current == null || current.isCapturing || _isSwitchingProfile) {
      return null;
    }

    state = AsyncData(current.copyWith(isCapturing: true));

    try {
      final repository = ref.read(cinemaCameraRepositoryProvider);
      final toneId =
          current.selectedTone.isCustom ? null : current.selectedTone.id;

      final gradedBytes = await repository.nativeCameraCapturePhoto(
        <String, dynamic>{
          'matrix': current.captureColorMatrix,
          'toneId': toneId,
          'intensity': current.intensity,
          'look': current.nativeLook,
          'anamorphic': current.isAnamorphicRatio,
          'anamorphicCrop': current.anamorphicCrop,
          'frameAspectRatio': current.effectiveFrameAspectRatio,
          'desqueeze': current.anamorphicDesqueeze,
          'appleLogInput': current.appleLogEnabled,
          'processZero': current.processZeroEnabled,
          'saveDngRaw': current.saveDngRaw,
          'nightStack': current.nightStack,
          'heif10Bit': current.heif10Bit,
          'hiRes48MP': current.hiRes48MP,
          'portraitMode': false,
          'watermarkStyle': current.watermarkStyle,
          'watermarkTheme': current.watermarkTheme,
          'watermarkDateStamp': current.watermarkDateStamp,
          'watermarkText': current.photographerSignature.isNotEmpty
              ? current.photographerSignature
              : (current.selectedTone.id == 'standard'
                  ? ''
                  : current.selectedTone.name),
          'quality': 0.96,
        },
      );

      String? warning;
      String? storedPath;
      try {
        final stored = await repository.storePhoto(
          jpegBytes: gradedBytes,
          toneId: current.selectedTone.id,
          toneName: current.selectedTone.name,
          intensity: current.intensity,
          isAnamorphic: current.isAnamorphicRatio,
        );
        storedPath = stored.path;
      } catch (error) {
        warning = 'Foto tidak masuk galeri CineLens: ${_describeError(error)}';
      }

      // When 10-bit HEIF is enabled, native Swift (`renderGradedStill`) already
      // saves the single true 10-bit Display P3 `.heic` master (with automatic
      // JPEG fallback) directly to Apple Photos — skip the duplicate 8-bit JPEG
      // copy so Apple Photos never receives 2 copies of the same shot!
      if (!current.heif10Bit) {
        try {
          await repository.saveImageToIosGallery(gradedBytes);
        } catch (error) {
          final message =
              'Gagal menyimpan ke Apple Photos: ${_describeError(error)}';
          warning = warning == null ? message : '$warning · $message';
        }
      }

      final latest = state.valueOrNull ?? current;
      state = AsyncData(
        latest.copyWith(
          isCapturing: false,
          latestGalleryThumbPath: storedPath ?? latest.latestGalleryThumbPath,
        ),
      );
      return PhotoCaptureResult(bytes: gradedBytes, warning: warning);
    } catch (e) {
      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(isCapturing: false));
      rethrow;
    }
  }

  // ------------------------------------------------------- video recording

  Future<void> startVideo24fpsRecording() async {
    final current = state.valueOrNull;
    if (current == null || current.isRecordingVideo || _isSwitchingProfile) {
      return;
    }

    // Unified single-session Native Swift recorder for BOTH HEVC Display P3 AND
    // ProRes 422 `.mov` — eliminates dual AVCaptureSession audio collisions,
    // delegate hijacking, and unstoppable ProRes hangs!
    final useProRes =
        current.proResEnabled && current.proCapabilities.supportsProRes;
    final burnLut = useProRes
        ? (current.bakeLookIntoProRes && current.hasRenderableLook)
        : (current.directLutRecordingEnabled || current.hasRenderableLook);

    final repo = ref.read(cinemaCameraRepositoryProvider);
    _proResRecording = false;
    _nativeRecording = true;
    recordingDurationNotifier.value = Duration.zero;
    try {
      await repo.nativeCameraStartVideo(<String, dynamic>{
        'fps': current.frameRate.value,
        'bitrate': _videoBitrateFor(current.resolution, current.frameRate),
        'proRes': useProRes,
        'burnLut': burnLut,
        'timelapseInterval': current.timelapseInterval,
        'grading': _liveMetalConfigFor(current),
      });
    } catch (error) {
      _nativeRecording = false;
      _recordingTimer?.cancel();
      recordingDurationNotifier.value = Duration.zero;
      _writeRecordingStopped();
      rethrow;
    }

    if (_disposed || !_nativeRecording) return;
    final latest = state.valueOrNull ?? current;
    state = AsyncData(
      latest.copyWith(
        isRecordingVideo: true,
        isRecordingPaused: false,
        isProcessingVideo: false,
        recordingDuration: Duration.zero,
      ),
    );
    _startRecordingClock();
    unawaited(refreshStorageInfo());
  }

  void _startRecordingClock() {
    _recordingTimer?.cancel();
    recordingDurationNotifier.value = Duration.zero;
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final latest = state.valueOrNull;
      if (latest != null &&
          latest.isRecordingVideo &&
          !latest.isRecordingPaused) {
        recordingDurationNotifier.value =
            recordingDurationNotifier.value + const Duration(milliseconds: 100);
      }
    });
  }

  /// Stops the active recording cleanly and indexes/saves the file.
  Future<VideoStopResult?> stopVideo24fpsRecording() async {
    final current = state.valueOrNull;
    if (current == null) return null;

    final isProResTake = _proResRecording;
    final isNativeTake = _nativeRecording;
    if (!current.isRecordingVideo && !isProResTake && !isNativeTake) {
      return null;
    }

    _recordingTimer?.cancel();
    recordingDurationNotifier.value = Duration.zero;
    if (!_disposed) {
      final wasProRes =
          isProResTake || (current.proResEnabled && current.proCapabilities.supportsProRes);
      state = AsyncData(
        current.copyWith(
          isRecordingVideo: false,
          isRecordingPaused: false,
          isProcessingVideo: true,
          recordingDuration: Duration.zero,
          videoProcessingLabel:
              wasProRes ? 'Finalizing ProRes...' : 'Saving HEVC...',
          clearVideoProcessingProgress: true,
        ),
      );
    }

    if (isProResTake) return _finishProResTake(current);
    return _finishNativeVideoTake(current);
  }

  /// Stops the native ProRes take and indexes the ungraded `.mov` master.
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
          appleLogInput: current.appleLogEnabled,
          desqueeze: current.anamorphicDesqueeze,
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
        isRecordingPaused: false,
        isProcessingVideo: false,
        recordingDuration: Duration.zero,
        videoProcessingLabel: 'Memproses video 24fps...',
        clearVideoProcessingProgress: true,
      ),
    );
    unawaited(refreshStorageInfo());
  }

  void resumeCameraSession() {
    if (_disposed) return;
    unawaited(ref.read(cinemaCameraRepositoryProvider).nativeCameraResume());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    switch (lifecycleState) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_abandonInterruptedRecording());
        unawaited(ref.read(cinemaCameraRepositoryProvider).nativeCameraPause());
      case AppLifecycleState.resumed:
        unawaited(
          ref.read(cinemaCameraRepositoryProvider).nativeCameraResume(),
        );
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _abandonInterruptedRecording() async {
    final current = state.valueOrNull;
    if (current == null || !current.isRecordingVideo) return;

    _recordingTimer?.cancel();
    _writeRecordingStopped();

    if (_proResRecording) {
      _proResRecording = false;
      try {
        final path = await ref
            .read(cinemaCameraRepositoryProvider)
            .stopProResRecording();
        if (path != null && path.isNotEmpty) {
          await _persistProResTake(path);
        }
      } catch (_) {}
      return;
    }

    if (_nativeRecording) {
      _nativeRecording = false;
      try {
        final path = await ref
            .read(cinemaCameraRepositoryProvider)
            .nativeCameraStopVideo();
        if (path.isNotEmpty) {
          await _persistProResTake(path);
        }
      } catch (_) {}
    }
  }

  Future<VideoStopResult?> _finishNativeVideoTake(
    CinemaCameraState current,
  ) async {
    _nativeRecording = false;
    final repository = ref.read(cinemaCameraRepositoryProvider);
    String path;
    try {
      path = await repository.nativeCameraStopVideo();
    } catch (error) {
      _writeRecordingStopped();
      _setProError(_describeError(error));
      return null;
    }
    if (path.isEmpty) {
      _writeRecordingStopped();
      return null;
    }

    String? warning;
    try {
      await repository.storeVideo(
        sourcePath: path,
        toneId: current.selectedTone.id,
        toneName: current.selectedTone.name,
        intensity: current.intensity,
        isAnamorphic: current.isAnamorphicRatio,
      );
    } catch (error) {
      warning = 'Gallery save failed: ${_describeError(error)}';
    }
    try {
      await repository.saveVideoToGallery(path);
    } catch (error) {
      warning = warning == null
          ? 'Apple Photos save failed: ${_describeError(error)}'
          : '$warning · Apple Photos failed';
    }
    _writeRecordingStopped();
    return VideoStopResult(path: path, warning: warning);
  }

  /// Loads the local gallery index. Used by the gallery screen.
  Future<List<CapturedMedia>> loadCapturedMedia() {
    return ref.read(cinemaCameraRepositoryProvider).loadCapturedMedia();
  }

  Future<void> deleteCapturedMedia(CapturedMedia media) async {
    await ref.read(cinemaCameraRepositoryProvider).deleteCapturedMedia(media);
    await refreshLatestThumb();
  }

  Future<void> deleteCapturedMediaBatch(List<CapturedMedia> items) async {
    await ref
        .read(cinemaCameraRepositoryProvider)
        .deleteCapturedMediaBatch(items);
    await refreshLatestThumb();
  }

  Future<void> refreshLatestThumb() async {
    final items = await loadCapturedMedia();
    if (_disposed) return;
    final current = state.valueOrNull;
    if (current == null) return;
    final thumb = items.where((m) => !m.isVideo).map((m) => m.path).firstOrNull;
    state = AsyncData(current.copyWith(latestGalleryThumbPath: thumb ?? ''));
  }

  /// Opens the iOS photo picker and indexes everything the user selected.
  ///
  /// The native side copies the files into the app media folder, so this works
  /// without photo-library permission (PHPicker runs out of process). Returns
  /// the entries that were added, newest first.
  Future<List<CapturedMedia>> importFromPhotoLibrary({int limit = 40}) async {
    final picker = ref.read(photoEditorRepositoryProvider);
    final files = await picker.importFromPhotoLibrary(limit: limit);
    if (files.isEmpty) return const <CapturedMedia>[];

    final repository = ref.read(cinemaCameraRepositoryProvider);
    final imported = <CapturedMedia>[];
    for (final file in files) {
      try {
        imported.add(
          await repository.indexImportedMedia(
            path: file.path,
            isVideo: file.isVideo,
          ),
        );
      } catch (_) {
        // A single unreadable item must not abort the whole import.
      }
    }
    return imported;
  }

  /// Saves an existing gallery entry back to Apple Photos.
  Future<void> saveMediaToPhotos(CapturedMedia media) async {
    final repository = ref.read(cinemaCameraRepositoryProvider);
    if (media.isVideo) {
      await repository.saveVideoToGallery(media.path);
      return;
    }
    final bytes = await File(media.path).readAsBytes();
    await repository.saveImageToIosGallery(bytes);
  }

  String _describeError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}
