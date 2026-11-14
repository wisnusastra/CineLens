// lib/features/cinema_camera/presentation/providers/cinema_camera_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/cinema_tones_preset_source.dart';
import '../../domain/entities/cinema_tone.dart';

class CinemaCameraState {
  final List<CinemaTone> presets;
  final int selectedToneIndex;
  final bool isVideoMode;
  final bool isRecording;
  final bool isCapturing;
  final int cameraIndex;

  const CinemaCameraState({
    required this.presets,
    this.selectedToneIndex = 0,
    this.isVideoMode = false,
    this.isRecording = false,
    this.isCapturing = false,
    this.cameraIndex = 0,
  });

  CinemaTone get activeTone => presets[selectedToneIndex];

  CinemaCameraState copyWith({
    List<CinemaTone>? presets,
    int? selectedToneIndex,
    bool? isVideoMode,
    bool? isRecording,
    bool? isCapturing,
    int? cameraIndex,
  }) {
    return CinemaCameraState(
      presets: presets ?? this.presets,
      selectedToneIndex: selectedToneIndex ?? this.selectedToneIndex,
      isVideoMode: isVideoMode ?? this.isVideoMode,
      isRecording: isRecording ?? this.isRecording,
      isCapturing: isCapturing ?? this.isCapturing,
      cameraIndex: cameraIndex ?? this.cameraIndex,
    );
  }
}

class CinemaCameraNotifier extends Notifier<CinemaCameraState> {
  @override
  CinemaCameraState build() {
    const source = CinemaTonesPresetSource();
    return CinemaCameraState(presets: source.getPresets());
  }

  void selectTone(int index) {
    if (index >= 0 && index < state.presets.length) {
      state = state.copyWith(selectedToneIndex: index);
    }
  }

  void setVideoMode(bool value) {
    if (!state.isRecording) {
      state = state.copyWith(isVideoMode: value);
    }
  }

  void setRecording(bool value) {
    state = state.copyWith(isRecording: value);
  }

  void setCapturing(bool value) {
    state = state.copyWith(isCapturing: value);
  }

  void setCameraIndex(int index) {
    state = state.copyWith(cameraIndex: index);
  }
}

final cinemaCameraProvider =
    NotifierProvider<CinemaCameraNotifier, CinemaCameraState>(
  CinemaCameraNotifier.new,
);
