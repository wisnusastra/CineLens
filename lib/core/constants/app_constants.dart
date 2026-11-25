import 'package:flutter/services.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'CineLens iOS';
  static const String albumName = 'CineLens Cinema';
  static const String prefSelectedToneId = 'selected_cinema_tone_id';
  static const String prefToneIntensity = 'selected_cinema_intensity';
  static const String prefCustomTonesJson = 'custom_cinema_tones_json';
  static const String prefCaptureResolution = 'capture_resolution_preset';
  static const String prefCaptureFrameRate = 'capture_frame_rate';
  static const String prefMediaLibraryJson = 'captured_media_library_json';
  static const String prefFilmLookJson = 'film_look_json';
  static const String prefBakeLookIntoProRes = 'bake_look_into_prores';
  static const String prefToneIntensityFullV2 = 'tone_intensity_full_v2';
  static const String prefProcessZeroRaw = 'process_zero_raw_photo';
  static const String prefAnamorphicCrop = 'anamorphic_true_crop';
  static const String prefAnamorphicDesqueeze = 'anamorphic_desqueeze_factor';
  static const String prefHighlightMetering = 'highlight_weighted_metering';
  static const String prefFrameFormat = 'camera_frame_format_v1';
  static const String prefSaveDngRaw = 'save_dng_raw_v1';
  static const String prefDirectLutRecording = 'direct_lut_recording_v1';
  static const String prefLiveMetalPreview = 'live_metal_preview_v1';
  static const String prefHeif10Bit = 'heif_10bit_p3_v1';
  static const String prefNightStack = 'process_zero_night_stack_v1';
  static const String prefVolumeShutter = 'hardware_volume_shutter_v1';
  static const String prefTimerSeconds = 'camera_timer_seconds_v1';
  static const String prefHiRes48MP = 'camera_hires_48mp_v1';
  static const String prefApertureFStop = 'camera_aperture_fstop_v1';

  /// Set once the first-install opening clip has been shown. Keeping this as a
  /// versioned key means a future opening can be shown again if needed.
  static const String prefOpeningSeen = 'opening_video_seen_v1';
  static const String videoGraderChannel = 'com.cinelens.ios/video_grader';

  static const int presetJsonSchemaVersion = 1;
  static const double anamorphicAspectRatio = 2.39;
  static const int cinemaTargetFps = 24;

  /// Folder inside the app documents directory that keeps a local copy of
  /// every capture so the in-app gallery works without Photos permission.
  static const String mediaFolderName = 'cinelens_media';

  /// Folder that keeps imported `.cube` LUTs as raw RGBA float cubes.
  static const String lutFolderName = 'cinelens_luts';

  /// How many captures the gallery index keeps. Older entries are pruned from
  /// the index (and their files deleted) so preferences cannot grow forever.
  static const int maxGalleryEntries = 300;

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
