// lib/features/options/domain/entities/camera_options_state.dart

enum GridOverlayType {
  none('Off'),
  ruleOfThirds('Rule of Thirds'),
  goldenRatio('Golden Ratio'),
  crosshair('Center Crosshair');

  final String label;
  const GridOverlayType(this.label);
}

enum CinemaAspectRatio {
  full('Full Sensor', null),
  widescreen16x9('16:9 Widescreen', 16 / 9),
  anamorphic239('2.39:1 CinemaScope', 2.39),
  classic4x3('4:3 Classic', 4 / 3);

  final String label;
  final double? ratio;
  const CinemaAspectRatio(this.label, this.ratio);
}

class CameraOptionsState {
  final GridOverlayType gridType;
  final CinemaAspectRatio aspectRatio;
  final bool showTelemetryHud;
  final bool hapticFeedback;
  final bool mirrorFrontCamera;

  const CameraOptionsState({
    this.gridType = GridOverlayType.ruleOfThirds,
    this.aspectRatio = CinemaAspectRatio.full,
    this.showTelemetryHud = true,
    this.hapticFeedback = true,
    this.mirrorFrontCamera = true,
  });

  CameraOptionsState copyWith({
    GridOverlayType? gridType,
    CinemaAspectRatio? aspectRatio,
    bool? showTelemetryHud,
    bool? hapticFeedback,
    bool? mirrorFrontCamera,
  }) {
    return CameraOptionsState(
      gridType: gridType ?? this.gridType,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      showTelemetryHud: showTelemetryHud ?? this.showTelemetryHud,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      mirrorFrontCamera: mirrorFrontCamera ?? this.mirrorFrontCamera,
    );
  }
}
