// lib/features/options/presentation/providers/camera_options_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/camera_options_state.dart';

class CameraOptionsNotifier extends Notifier<CameraOptionsState> {
  @override
  CameraOptionsState build() {
    return const CameraOptionsState();
  }

  void setGridType(GridOverlayType type) {
    state = state.copyWith(gridType: type);
  }

  void setAspectRatio(CinemaAspectRatio ratio) {
    state = state.copyWith(aspectRatio: ratio);
  }

  void toggleTelemetryHud(bool value) {
    state = state.copyWith(showTelemetryHud: value);
  }

  void toggleHapticFeedback(bool value) {
    state = state.copyWith(hapticFeedback: value);
  }

  void toggleMirrorFrontCamera(bool value) {
    state = state.copyWith(mirrorFrontCamera: value);
  }

  void resetDefaults() {
    state = const CameraOptionsState();
  }
}

final cameraOptionsProvider =
    NotifierProvider<CameraOptionsNotifier, CameraOptionsState>(
  CameraOptionsNotifier.new,
);
