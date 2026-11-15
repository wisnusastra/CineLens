import 'dart:ui';
import 'package:camera/camera.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/pro_capture_capabilities.dart';
import '../../domain/services/color_matrix_builder.dart';

enum CinemaCaptureMode { photo, video24fps }

/// Output resolution offered to the user.
///
/// Photos and video are treated differently on purpose:
/// * video is capped at 4K because the plugin's H.264/HEVC writer cannot
///   encode a 12–48 MP sensor format, and
/// * photos only reach the full sensor with [ResolutionPreset.max], because
///   the iOS plugin turns `isHighResolutionPhotoEnabled` on **only** for that
///   preset. That is why every still used to come out at 1080p.
enum CaptureResolution {
  fullHD('1080p', 'Full HD 1920×1080', ResolutionPreset.veryHigh),
  uhd4K('4K', 'Ultra HD 3840×2160', ResolutionPreset.ultraHigh),
  maxSensor('MAX', 'Sensor penuh (foto)', ResolutionPreset.max);

  const CaptureResolution(this.label, this.description, this.preset);

  final String label;
  final String description;
  final ResolutionPreset preset;

  bool get isMaxSensor => this == CaptureResolution.maxSensor;

  ResolutionPreset get photoPreset => preset;

  ResolutionPreset get videoPreset =>
      isMaxSensor ? ResolutionPreset.ultraHigh : preset;
}

/// Recording frame rate. The iOS plugin resolves the closest rate the active
/// format actually supports, so an unsupported combination (for example
/// 4K60 on older hardware) silently falls back instead of failing.
enum CaptureFrameRate {
  fps24(24, '24', 'Cinema'),
  fps30(30, '30', 'Standard'),
  fps60(60, '60', 'Smooth');

  const CaptureFrameRate(this.value, this.label, this.description);

  final int value;
  final String label;
  final String description;

  static CaptureFrameRate fromValue(int? value) {
    return CaptureFrameRate.values.firstWhere(
      (rate) => rate.value == value,
      orElse: () => CaptureFrameRate.fps24,
    );
  }
}

class CinemaCameraState {
  final List<CinemaTone> tones;
  final CinemaTone selectedTone;
  final double intensity;
  final CinemaCaptureMode captureMode;
  final bool isAnamorphicRatio;
  final bool showGrid;
  final FlashMode flashMode;
  final double exposureOffset;
  final double minExposure;
  final double maxExposure;
  final CameraLensDirection lensDirection;
  final bool isCapturing;
  final bool isRecordingVideo;
  final bool isProcessingVideo;
  final Duration recordingDuration;
  final Offset? focusPoint;
  final CustomGradeParameters? liveDraftParameters;
  final CaptureResolution resolution;
  final CaptureFrameRate frameRate;
  final double zoomLevel;
  final double minZoom;
  final double maxZoom;

  /// Whether iOS actually stabilised the current capture session. Filled from
  /// the native side, because a requested mode can be rejected by a format
  /// (for example cinematic stabilisation at 4K).
  final bool videoStabilizationActive;

  /// `AVCaptureVideoStabilizationMode` raw value: 0 off, 1 standard,
  /// 2 cinematic.
  final int videoStabilizationMode;

  /// Hardware limits for the manual controls, reported by the native side.
  final ProCaptureCapabilities proCapabilities;

  /// When these flags are off, iOS keeps running its own automatic exposure,
  /// white balance and focus. Turning one on locks only that subsystem.
  final bool manualExposureEnabled;
  final double shutterSeconds;
  final double iso;
  final bool manualWhiteBalanceEnabled;
  final int whiteBalanceKelvin;
  final int whiteBalanceTint;
  final bool manualFocusEnabled;
  final double focusPosition;

  /// True while the device streams Apple Log instead of tone-mapped sRGB.
  final bool appleLogEnabled;

  /// Last refusal from the native controls, shown inside the pro panel so a
  /// rejected setting is never silent.
  final String? proControlError;

  const CinemaCameraState({
    required this.tones,
    required this.selectedTone,
    this.intensity = 0.85,
    this.captureMode = CinemaCaptureMode.photo,
    this.isAnamorphicRatio = true,
    this.showGrid = true,
    this.flashMode = FlashMode.off,
    this.exposureOffset = 0.0,
    this.minExposure = -2.0,
    this.maxExposure = 2.0,
    this.lensDirection = CameraLensDirection.back,
    this.isCapturing = false,
    this.isRecordingVideo = false,
    this.isProcessingVideo = false,
    this.recordingDuration = Duration.zero,
    this.focusPoint,
    this.liveDraftParameters,
    this.resolution = CaptureResolution.maxSensor,
    this.frameRate = CaptureFrameRate.fps24,
    this.zoomLevel = 1.0,
    this.minZoom = 1.0,
    this.maxZoom = 8.0,
    this.videoStabilizationActive = false,
    this.videoStabilizationMode = 0,
    this.proCapabilities = ProCaptureCapabilities.unavailable,
    this.manualExposureEnabled = false,
    this.shutterSeconds = 1 / 48,
    this.iso = 400,
    this.manualWhiteBalanceEnabled = false,
    this.whiteBalanceKelvin = 5600,
    this.whiteBalanceTint = 0,
    this.manualFocusEnabled = false,
    this.focusPosition = 0.5,
    this.appleLogEnabled = false,
    this.proControlError,
  });

  List<double> get activeColorMatrix {
    if (liveDraftParameters != null) {
      return ColorMatrixBuilder.build(liveDraftParameters!);
    }
    return selectedTone.blendedMatrix(intensity);
  }

  /// Label used by the viewfinder chips, e.g. `4K · 24FPS`.
  String get qualityLabel => '${resolution.label} · ${frameRate.value}FPS';

  /// Human readable stabilisation mode, e.g. `CINEMATIC`.
  String get stabilizationLabel {
    if (!videoStabilizationActive) return 'OFF';
    return videoStabilizationMode == 2 ? 'CINEMATIC' : 'STANDARD';
  }

  /// Shutter speed as photographers read it: `1/48`, or `0.5s` when slow.
  String get shutterLabel {
    if (shutterSeconds <= 0) return '1/48';
    final denominator = 1 / shutterSeconds;
    if (denominator >= 1) return '1/${denominator.round()}';
    return '${shutterSeconds.toStringAsFixed(1)}s';
  }

  /// Compact pro readout for the viewfinder, e.g. `1/48 · ISO 400`.
  String get exposureHudLabel => '$shutterLabel · ISO ${iso.round()}';

  String get whiteBalanceLabel => '$whiteBalanceKelvin K';

  /// Whether any manual subsystem is overriding iOS auto behaviour.
  bool get isManualCaptureActive =>
      manualExposureEnabled ||
      manualWhiteBalanceEnabled ||
      manualFocusEnabled ||
      appleLogEnabled;

  bool get isZoomed => zoomLevel > minZoom + 0.01;

  CinemaCameraState copyWith({
    List<CinemaTone>? tones,
    CinemaTone? selectedTone,
    double? intensity,
    CinemaCaptureMode? captureMode,
    bool? isAnamorphicRatio,
    bool? showGrid,
    FlashMode? flashMode,
    double? exposureOffset,
    double? minExposure,
    double? maxExposure,
    CameraLensDirection? lensDirection,
    bool? isCapturing,
    bool? isRecordingVideo,
    bool? isProcessingVideo,
    Duration? recordingDuration,
    Offset? focusPoint,
    bool clearFocusPoint = false,
    CustomGradeParameters? liveDraftParameters,
    bool clearLiveDraft = false,
    CaptureResolution? resolution,
    CaptureFrameRate? frameRate,
    double? zoomLevel,
    double? minZoom,
    double? maxZoom,
    bool? videoStabilizationActive,
    int? videoStabilizationMode,
    ProCaptureCapabilities? proCapabilities,
    bool? manualExposureEnabled,
    double? shutterSeconds,
    double? iso,
    bool? manualWhiteBalanceEnabled,
    int? whiteBalanceKelvin,
    int? whiteBalanceTint,
    bool? manualFocusEnabled,
    double? focusPosition,
    bool? appleLogEnabled,
    String? proControlError,
    bool clearProControlError = false,
  }) {
    return CinemaCameraState(
      tones: tones ?? this.tones,
      selectedTone: selectedTone ?? this.selectedTone,
      intensity: intensity ?? this.intensity,
      captureMode: captureMode ?? this.captureMode,
      isAnamorphicRatio: isAnamorphicRatio ?? this.isAnamorphicRatio,
      showGrid: showGrid ?? this.showGrid,
      flashMode: flashMode ?? this.flashMode,
      exposureOffset: exposureOffset ?? this.exposureOffset,
      minExposure: minExposure ?? this.minExposure,
      maxExposure: maxExposure ?? this.maxExposure,
      lensDirection: lensDirection ?? this.lensDirection,
      isCapturing: isCapturing ?? this.isCapturing,
      isRecordingVideo: isRecordingVideo ?? this.isRecordingVideo,
      isProcessingVideo: isProcessingVideo ?? this.isProcessingVideo,
      recordingDuration: recordingDuration ?? this.recordingDuration,
      focusPoint: clearFocusPoint ? null : (focusPoint ?? this.focusPoint),
      liveDraftParameters: clearLiveDraft
          ? null
          : (liveDraftParameters ?? this.liveDraftParameters),
      resolution: resolution ?? this.resolution,
      frameRate: frameRate ?? this.frameRate,
      zoomLevel: zoomLevel ?? this.zoomLevel,
      minZoom: minZoom ?? this.minZoom,
      maxZoom: maxZoom ?? this.maxZoom,
      videoStabilizationActive:
          videoStabilizationActive ?? this.videoStabilizationActive,
      videoStabilizationMode:
          videoStabilizationMode ?? this.videoStabilizationMode,
      proCapabilities: proCapabilities ?? this.proCapabilities,
      manualExposureEnabled:
          manualExposureEnabled ?? this.manualExposureEnabled,
      shutterSeconds: shutterSeconds ?? this.shutterSeconds,
      iso: iso ?? this.iso,
      manualWhiteBalanceEnabled:
          manualWhiteBalanceEnabled ?? this.manualWhiteBalanceEnabled,
      whiteBalanceKelvin: whiteBalanceKelvin ?? this.whiteBalanceKelvin,
      whiteBalanceTint: whiteBalanceTint ?? this.whiteBalanceTint,
      manualFocusEnabled: manualFocusEnabled ?? this.manualFocusEnabled,
      focusPosition: focusPosition ?? this.focusPosition,
      appleLogEnabled: appleLogEnabled ?? this.appleLogEnabled,
      proControlError: clearProControlError
          ? null
          : (proControlError ?? this.proControlError),
    );
  }
}
