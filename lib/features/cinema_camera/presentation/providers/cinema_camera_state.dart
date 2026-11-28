import 'dart:ui';
import '../../domain/entities/camera_recipe.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/film_look.dart';
import '../../domain/entities/frame_format.dart';
import '../../domain/entities/pro_capture_capabilities.dart';
import '../../domain/services/color_matrix_builder.dart';

/// Camera lens facing direction (native Swift engine, zero plugin dependency).
enum CameraLensDirection { back, front }

/// Flash / torch control mode.
enum FlashMode { off, auto, always, torch }

enum CinemaCaptureMode {
  photo,
  video24fps;

  bool get isVideo => this == CinemaCaptureMode.video24fps;

  bool get isPhoto => this == CinemaCaptureMode.photo;
}

/// One back camera focal-length choice (`0.5×`, `1×`, `2×` 48mm optical crop,
/// `3×`). Switching optical lenses keeps full sensor sharpness & real optical
/// compression instead of blurry digital crop.
class OpticalLensOption {
  final String id;
  final String label;
  final double initialZoom;
  final int focalMm;

  const OpticalLensOption({
    required this.id,
    required this.label,
    this.initialZoom = 1.0,
    this.focalMm = 24,
  });

  String get focalLabel => '${focalMm}mm';
}

/// Output resolution offered to the user.
enum CaptureResolution {
  fullHD('1080p', 'Full HD 1920×1080'),
  uhd4K('4K', 'Ultra HD 3840×2160'),
  maxSensor('MAX', 'Sensor penuh (foto)');

  const CaptureResolution(this.label, this.description);

  final String label;
  final String description;

  bool get isMaxSensor => this == CaptureResolution.maxSensor;
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

  /// Records Apple ProRes 422 masters through the native recorder instead of
  /// the plugin's H.264/HEVC encoder. Only meaningful when
  /// [ProCaptureCapabilities.supportsProRes] is true.
  final bool proResEnabled;

  /// Film emulation (grain, halation, bloom, vignette) applied to stills and
  /// clips. Imported `.cube` LUTs use [FilmLook.lutMix] from here too.
  final FilmLook filmLook;

  /// When on, a ProRes take is re-encoded with the tone + effects burned in.
  /// Off by default: a ProRes master is normally kept flat for grading.
  final bool bakeLookIntoProRes;

  /// Process Zero Bayer RAW still capture (bypasses Apple Smart HDR shadow
  /// lifting so directional shadows stay velvety ink-black & organic).
  final bool processZeroEnabled;

  /// Highlight-weighted exposure metering (biases exposure to protect sunlit
  /// highlights & deepen shadows like Leica/Ricoh chiaroscuro mode).
  final bool highlightMeteringEnabled;

  /// True when anamorphic mode crops output to real 2.39:1 instead of baking
  /// dead black letterbox bars.
  final bool anamorphicCrop;

  /// Horizontal desqueeze factor for external anamorphic lenses (1.0, 1.33, 1.55).
  final double anamorphicDesqueeze;

  /// Physical back camera lenses discovered on this device (0.5x, 1x, 2x/3x).
  final List<OpticalLensOption> backLenses;

  /// Index inside [backLenses] currently active when using the rear camera.
  final int activeBackLensIndex;

  /// Vintage / cinema frame aspect ratio (FULL, 1:1, 4:5, 6:7, 3:2, 16:9, 2.39:1, 65:24).
  final CameraFrameFormat frameFormat;

  /// Also writes original 12-bit Bayer `.dng` negative when shooting Process Zero RAW.
  final bool saveDngRaw;
  final bool nightStack;
  final bool heif10Bit;
  final bool hiRes48MP;
  final double apertureFStop;
  final bool cinematicRackedToBg;
  final Offset lastFocusNormalized;
  final bool volumeShutterEnabled;
  final int timerSeconds;
  final int hardwareShutterTick;

  /// Tahap 2 Cinema Pro: Live Metal 3D LUT Viewfinder (`FlutterTexture`),
  /// Direct-to-Disk HEVC Video LUT Recording, and Real-Time DOP Overlays.
  final bool liveMetalEnabled;
  final int? liveMetalTextureId;
  final double previewWidth;
  final double previewHeight;
  final bool hasHardwareDepth;
  final bool directLutRecordingEnabled;
  final bool focusPeakingEnabled;
  final bool zebraEnabled;
  final bool falseColorEnabled;
  final bool horizonLevelEnabled;
  final bool audioMeterEnabled;
  final bool liveScopeEnabled;
  final double horizonDegrees;
  final double audioPeakDb;
  final Map<String, dynamic>? liveScopeData;
  final String? latestGalleryThumbPath;

  /// Text under the processing spinner, e.g. "Membakar look ke ProRes...".
  final String? videoProcessingLabel;

  /// Native export progress (0…1), or null while it is still unknown. Kept as a
  /// real percentage so a long save never looks like an endless spinner.
  final double? videoProcessingProgress;

  /// Last refusal from the native controls, shown inside the pro panel so a
  /// rejected setting is never silent.
  final String? proControlError;

  // v3.4 Pro Camera Ergonomics & Controls
  final bool isAeAfLocked;
  final bool isRecordingPaused;
  final double timelapseInterval;
  final double freeStorageMB;
  final bool splitCompareEnabled;
  final bool zenModeEnabled;
  final Set<String> favoriteToneIds;
  final List<CameraRecipe> recipes;
  final int? activeRecipeSlot;

  // v3.5 Camera Auto-Watermark Frame (with auto iPhone device detection + EXIF)
  final String watermarkStyle;
  final String watermarkTheme;
  final bool watermarkDateStamp;
  final String photographerSignature;

  // v3.8 Anti-Flicker Shutter-Priority Auto-ISO (`'50hz'` | `'60hz'` | `'off'`)
  final String antiFlickerMode;

  const CinemaCameraState({
    required this.tones,
    required this.selectedTone,
    this.intensity = 1.0,
    this.captureMode = CinemaCaptureMode.photo,
    this.isAnamorphicRatio = false,
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
    this.proResEnabled = false,
    this.filmLook = const FilmLook(),
    this.bakeLookIntoProRes = false,
    this.processZeroEnabled = false,
    this.highlightMeteringEnabled = false,
    this.anamorphicCrop = false,
    this.anamorphicDesqueeze = 1.0,
    this.backLenses = const <OpticalLensOption>[],
    this.activeBackLensIndex = 0,
    this.frameFormat = CameraFrameFormat.full,
    this.saveDngRaw = false,
    this.nightStack = false,
    this.heif10Bit = false,
    this.hiRes48MP = false,
    this.apertureFStop = 2.2,
    this.cinematicRackedToBg = false,
    this.lastFocusNormalized = const Offset(0.5, 0.5),
    this.volumeShutterEnabled = true,
    this.timerSeconds = 0,
    this.hardwareShutterTick = 0,
    this.liveMetalEnabled = false,
    this.liveMetalTextureId,
    this.previewWidth = 1080.0,
    this.previewHeight = 1920.0,
    this.hasHardwareDepth = false,
    this.directLutRecordingEnabled = false,
    this.focusPeakingEnabled = false,
    this.zebraEnabled = false,
    this.falseColorEnabled = false,
    this.horizonLevelEnabled = true,
    this.audioMeterEnabled = true,
    this.liveScopeEnabled = false,
    this.horizonDegrees = 0.0,
    this.audioPeakDb = -60.0,
    this.liveScopeData,
    this.latestGalleryThumbPath,
    this.videoProcessingLabel,
    this.videoProcessingProgress,
    this.proControlError,
    this.isAeAfLocked = false,
    this.isRecordingPaused = false,
    this.timelapseInterval = 0.0,
    this.freeStorageMB = 0.0,
    this.splitCompareEnabled = false,
    this.zenModeEnabled = false,
    this.favoriteToneIds = const <String>{},
    this.recipes = CameraRecipe.defaults,
    this.activeRecipeSlot,
    this.watermarkStyle = 'none',
    this.watermarkTheme = 'white',
    this.watermarkDateStamp = false,
    this.photographerSignature = '',
    this.antiFlickerMode = '50hz',
  });

  /// Matrix the live preview uses.
  ///
  /// For an imported `.cube` tone this is the least-squares approximation, so
  /// the viewfinder keeps moving in real time while exports use the exact LUT.
  List<double> get activeColorMatrix {
    if (liveDraftParameters != null) {
      return ColorMatrixBuilder.build(liveDraftParameters!);
    }
    return selectedTone.blendedMatrix(intensity);
  }

  /// Matrix handed to the native renderer.
  ///
  /// An imported LUT must not be approximated on export: the cube is applied
  /// there, so the matrix is neutral.
  List<double> get captureColorMatrix {
    if (selectedTone.isLutTone) return CinemaTone.identityMatrix;
    if (liveDraftParameters != null) {
      return ColorMatrixBuilder.build(liveDraftParameters!);
    }
    return selectedTone.blendedMatrix(intensity);
  }

  /// Active framing aspect ratio (`0.0` = full native sensor).
  double get effectiveFrameAspectRatio => frameFormat.isFramed
      ? frameFormat.aspectRatio
      : (isAnamorphicRatio ? 2.39 : 0.0);

  /// Target shutter speed for the 180° cinema rule (`1/50s` = 172.8° when
  /// shooting 24fps under 50Hz AC mains to eliminate indoor LED flicker!).
  double get target180ShutterSeconds {
    if (antiFlickerMode == '50hz' && frameRate.value == 24) {
      return 1.0 / 50.0;
    }
    return 1.0 / (frameRate.value * 2);
  }

  /// True when the shutter speed is locked to the 180° (or 172.8° 50Hz) cinema rule.
  bool get is180ShutterLocked {
    if (!manualExposureEnabled || shutterSeconds <= 0) return false;
    final target = target180ShutterSeconds;
    return (shutterSeconds - target).abs() < target * 0.08;
  }

  String get antiFlickerLabel => switch (antiFlickerMode) {
        '60hz' => '60Hz',
        'off' => 'OFF',
        _ => '50Hz',
      };

  /// Payload for `AppDelegate.FilmEffects.from` & `ImportedLut.from`.
  Map<String, dynamic> get nativeLook {
    final tone = selectedTone;
    final effectiveLook = highlightMeteringEnabled && filmLook.shadowDepth < 0.35
        ? filmLook.copyWith(shadowDepth: 0.42)
        : filmLook;
    return effectiveLook.toNative(
      lutPath: tone.isLutTone ? tone.lutPath : null,
      lutSize: tone.isLutTone ? tone.lutSize : null,
      mix: tone.isLutTone ? intensity.clamp(0.0, 1.0) : 0,
    );
  }

  /// True when the current look is worth baking into a ProRes master.
  bool get hasRenderableLook =>
      selectedTone.isLutTone || !filmLook.isNeutral || intensity > 0.01;

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

  /// True when the native Metal GPU texture already has color grading/DOP
  /// overlays baked into the preview pixels (so Dart skips `ColorFiltered`).
  bool get isGpuGradingActive =>
      liveMetalEnabled ||
      focusPeakingEnabled ||
      zebraEnabled ||
      falseColorEnabled ||
      liveScopeEnabled ||
      appleLogEnabled ||
      splitCompareEnabled;

  bool get isTimelapseArmed => captureMode.isVideo && timelapseInterval > 0.0;

  /// SMPTE timecode formatted as `HH:MM:SS:FF` at the active recording FPS.
  String get smpteTimecode {
    final totalMs = recordingDuration.inMilliseconds;
    final hours = (totalMs ~/ 3600000) % 100;
    final minutes = (totalMs ~/ 60000) % 60;
    final seconds = (totalMs ~/ 1000) % 60;
    final frames = ((totalMs % 1000) * frameRate.value) ~/ 1000;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)}:${two(frames)}';
  }

  /// Estimated remaining video recording time based on free iPhone storage.
  String get remainingStorageLabel {
    if (freeStorageMB <= 0) return '';
    // Active HEVC bitrate MB/min: 4K (~337 MB/min) vs 1080p (~165 MB/min) vs ProRes (~2500 MB/min)
    final double mbPerMin;
    if (proResEnabled) {
      mbPerMin = 2400.0;
    } else if (resolution == CaptureResolution.fullHD) {
      mbPerMin = 165.0;
    } else {
      mbPerMin = 335.0;
    }
    final mins = (freeStorageMB / mbPerMin).floor();
    if (mins < 1) return '<1m';
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return '${h}h${m > 0 ? '${m}m' : ''}';
    }
    return '${mins}m';
  }

  /// Returns tones with `standard` first, then pinned Favorites (`★`), then the rest.
  List<CinemaTone> get orderedTones {
    if (favoriteToneIds.isEmpty) return tones;
    final standard = <CinemaTone>[];
    final favs = <CinemaTone>[];
    final rest = <CinemaTone>[];
    for (final t in tones) {
      if (t.id == 'standard') {
        standard.add(t);
      } else if (favoriteToneIds.contains(t.id)) {
        favs.add(t);
      } else {
        rest.add(t);
      }
    }
    return <CinemaTone>[...standard, ...favs, ...rest];
  }

  Size get previewSize => Size(previewWidth, previewHeight);

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
    bool? proResEnabled,
    FilmLook? filmLook,
    bool? bakeLookIntoProRes,
    bool? processZeroEnabled,
    bool? highlightMeteringEnabled,
    bool? anamorphicCrop,
    double? anamorphicDesqueeze,
    List<OpticalLensOption>? backLenses,
    int? activeBackLensIndex,
    CameraFrameFormat? frameFormat,
    bool? saveDngRaw,
    bool? nightStack,
    bool? heif10Bit,
    bool? hiRes48MP,
    double? apertureFStop,
    bool? cinematicRackedToBg,
    Offset? lastFocusNormalized,
    bool? volumeShutterEnabled,
    int? timerSeconds,
    int? hardwareShutterTick,
    bool? liveMetalEnabled,
    int? liveMetalTextureId,
    bool clearLiveMetalTexture = false,
    double? previewWidth,
    double? previewHeight,
    bool? hasHardwareDepth,
    bool? directLutRecordingEnabled,
    bool? focusPeakingEnabled,
    bool? zebraEnabled,
    bool? falseColorEnabled,
    bool? horizonLevelEnabled,
    bool? audioMeterEnabled,
    bool? liveScopeEnabled,
    double? horizonDegrees,
    double? audioPeakDb,
    Map<String, dynamic>? liveScopeData,
    String? latestGalleryThumbPath,
    String? videoProcessingLabel,
    double? videoProcessingProgress,
    bool clearVideoProcessingProgress = false,
    String? proControlError,
    bool clearProControlError = false,
    bool? isAeAfLocked,
    bool? isRecordingPaused,
    double? timelapseInterval,
    double? freeStorageMB,
    bool? splitCompareEnabled,
    bool? zenModeEnabled,
    Set<String>? favoriteToneIds,
    List<CameraRecipe>? recipes,
    int? activeRecipeSlot,
    bool clearActiveRecipeSlot = false,
    String? watermarkStyle,
    String? watermarkTheme,
    bool? watermarkDateStamp,
    String? photographerSignature,
    String? antiFlickerMode,
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
      proResEnabled: proResEnabled ?? this.proResEnabled,
      filmLook: filmLook ?? this.filmLook,
      bakeLookIntoProRes: bakeLookIntoProRes ?? this.bakeLookIntoProRes,
      processZeroEnabled: processZeroEnabled ?? this.processZeroEnabled,
      highlightMeteringEnabled:
          highlightMeteringEnabled ?? this.highlightMeteringEnabled,
      anamorphicCrop: anamorphicCrop ?? this.anamorphicCrop,
      anamorphicDesqueeze: anamorphicDesqueeze ?? this.anamorphicDesqueeze,
      backLenses: backLenses ?? this.backLenses,
      activeBackLensIndex: activeBackLensIndex ?? this.activeBackLensIndex,
      frameFormat: frameFormat ?? this.frameFormat,
      saveDngRaw: saveDngRaw ?? this.saveDngRaw,
      nightStack: nightStack ?? this.nightStack,
      heif10Bit: heif10Bit ?? this.heif10Bit,
      hiRes48MP: hiRes48MP ?? this.hiRes48MP,
      apertureFStop: apertureFStop ?? this.apertureFStop,
      cinematicRackedToBg: cinematicRackedToBg ?? this.cinematicRackedToBg,
      lastFocusNormalized: lastFocusNormalized ?? this.lastFocusNormalized,
      volumeShutterEnabled: volumeShutterEnabled ?? this.volumeShutterEnabled,
      timerSeconds: timerSeconds ?? this.timerSeconds,
      hardwareShutterTick: hardwareShutterTick ?? this.hardwareShutterTick,
      liveMetalEnabled: liveMetalEnabled ?? this.liveMetalEnabled,
      liveMetalTextureId: clearLiveMetalTexture
          ? null
          : (liveMetalTextureId ?? this.liveMetalTextureId),
      previewWidth: previewWidth ?? this.previewWidth,
      previewHeight: previewHeight ?? this.previewHeight,
      hasHardwareDepth: hasHardwareDepth ?? this.hasHardwareDepth,
      directLutRecordingEnabled:
          directLutRecordingEnabled ?? this.directLutRecordingEnabled,
      focusPeakingEnabled: focusPeakingEnabled ?? this.focusPeakingEnabled,
      zebraEnabled: zebraEnabled ?? this.zebraEnabled,
      falseColorEnabled: falseColorEnabled ?? this.falseColorEnabled,
      horizonLevelEnabled: horizonLevelEnabled ?? this.horizonLevelEnabled,
      audioMeterEnabled: audioMeterEnabled ?? this.audioMeterEnabled,
      liveScopeEnabled: liveScopeEnabled ?? this.liveScopeEnabled,
      horizonDegrees: horizonDegrees ?? this.horizonDegrees,
      audioPeakDb: audioPeakDb ?? this.audioPeakDb,
      liveScopeData: liveScopeData ?? this.liveScopeData,
      latestGalleryThumbPath:
          latestGalleryThumbPath ?? this.latestGalleryThumbPath,
      videoProcessingLabel: videoProcessingLabel ?? this.videoProcessingLabel,
      videoProcessingProgress: clearVideoProcessingProgress
          ? null
          : (videoProcessingProgress ?? this.videoProcessingProgress),
      proControlError: clearProControlError
          ? null
          : (proControlError ?? this.proControlError),
      isAeAfLocked: isAeAfLocked ?? this.isAeAfLocked,
      isRecordingPaused: isRecordingPaused ?? this.isRecordingPaused,
      timelapseInterval: timelapseInterval ?? this.timelapseInterval,
      freeStorageMB: freeStorageMB ?? this.freeStorageMB,
      splitCompareEnabled: splitCompareEnabled ?? this.splitCompareEnabled,
      zenModeEnabled: zenModeEnabled ?? this.zenModeEnabled,
      favoriteToneIds: favoriteToneIds ?? this.favoriteToneIds,
      recipes: recipes ?? this.recipes,
      activeRecipeSlot: clearActiveRecipeSlot
          ? null
          : (activeRecipeSlot ?? this.activeRecipeSlot),
      watermarkStyle: watermarkStyle ?? this.watermarkStyle,
      watermarkTheme: watermarkTheme ?? this.watermarkTheme,
      watermarkDateStamp: watermarkDateStamp ?? this.watermarkDateStamp,
      photographerSignature:
          photographerSignature ?? this.photographerSignature,
      antiFlickerMode: antiFlickerMode ?? this.antiFlickerMode,
    );
  }
}
