// lib/features/cinema_camera/domain/entities/frame_format.dart

/// Vintage photography & cinema aspect ratios rendered as viewfinder frame
/// masks and applied on export (either true crop or matte black framing).
enum CameraFrameFormat {
  full('FULL', 'Sensor', 0.0),
  square1x1('1:1', '6×6 Square', 1.0),
  portrait4x5('4:5', '4×5 Large', 4.0 / 5.0),
  medium6x7('6:7', '6×7 Medium', 6.0 / 7.0),
  classic35mm('3:2', '35mm Film', 3.0 / 2.0),
  wide16x9('16:9', 'Widescreen', 16.0 / 9.0),
  scope239('2.39:1', 'Anamorphic', 2.39),
  xpan('65:24', 'XPan', 65.0 / 24.0);

  const CameraFrameFormat(this.label, this.subtitle, this.aspectRatio);

  final String label;
  final String subtitle;

  /// Width / height ratio, or `0.0` for full native sensor.
  final double aspectRatio;

  bool get isFramed => aspectRatio > 0.1;

  static CameraFrameFormat fromName(String? raw) {
    if (raw == null || raw.isEmpty) return CameraFrameFormat.full;
    return CameraFrameFormat.values.firstWhere(
      (f) => f.name == raw || f.label == raw,
      orElse: () => CameraFrameFormat.full,
    );
  }
}
