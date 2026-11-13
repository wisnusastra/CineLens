import 'dart:ui';
import 'package:camera/camera.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/services/color_matrix_builder.dart';

enum CinemaCaptureMode { photo, video24fps }

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
  });

  List<double> get activeColorMatrix {
    if (liveDraftParameters != null) {
      return ColorMatrixBuilder.build(liveDraftParameters!);
    }
    return selectedTone.blendedMatrix(intensity);
  }

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
    );
  }
}
