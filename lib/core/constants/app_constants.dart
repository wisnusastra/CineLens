import 'package:flutter/services.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'CineLens iOS';
  static const String albumName = 'CineLens Cinema';
  static const String prefSelectedToneId = 'selected_cinema_tone_id';
  static const String prefToneIntensity = 'selected_cinema_intensity';
  static const String prefCustomTonesJson = 'custom_cinema_tones_json';
  static const String videoGraderChannel = 'com.cinelens.ios/video_grader';

  static const int presetJsonSchemaVersion = 1;
  static const double anamorphicAspectRatio = 2.39;
  static const int cinemaTargetFps = 24;

  /// Orientations the app is allowed to rotate into.
  ///
  /// Keep this in sync with `UISupportedInterfaceOrientations` in
  /// `ios/Runner/Info.plist`; iOS intersects both lists.
  static const List<DeviceOrientation> supportedOrientations = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static const List<DeviceOrientation> portraitOnly = [
    DeviceOrientation.portraitUp,
  ];

  static const List<DeviceOrientation> landscapeOnly = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];
}
