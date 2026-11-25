// lib/features/cinema_camera/domain/entities/pro_capture_capabilities.dart

/// What the running `AVCaptureDevice` can actually do.
///
/// The `camera` plugin hides the device, so these limits come from the native
/// side through the grading channel. Every manual control in the UI is gated on
/// this object: iPhone models differ a lot (Apple Log only exists on iPhone 15
/// Pro and newer, ProRes on iPhone 13 Pro and newer).
class ProCaptureCapabilities {
  final bool available;
  final String deviceName;
  final double minIso;
  final double maxIso;
  final double minShutterSeconds;
  final double maxShutterSeconds;
  final bool supportsAppleLog;
  final bool supportsProRes;
  final bool supports48MP;

  const ProCaptureCapabilities({
    required this.available,
    required this.deviceName,
    required this.minIso,
    required this.maxIso,
    required this.minShutterSeconds,
    required this.maxShutterSeconds,
    required this.supportsAppleLog,
    required this.supportsProRes,
    this.supports48MP = false,
  });

  /// Used before the native side has answered (and on a simulator).
  static const ProCaptureCapabilities unavailable = ProCaptureCapabilities(
    available: false,
    deviceName: '',
    minIso: 25,
    maxIso: 3200,
    minShutterSeconds: 1 / 8000,
    maxShutterSeconds: 1,
    supportsAppleLog: false,
    supportsProRes: false,
    supports48MP: false,
  );

  factory ProCaptureCapabilities.fromMap(Map<Object?, Object?> map) {
    double read(String key, double fallback) {
      final value = map[key];
      return value is num ? value.toDouble() : fallback;
    }

    final deviceName = map['deviceName'];

    return ProCaptureCapabilities(
      available: map['available'] == true,
      deviceName: deviceName is String ? deviceName : '',
      minIso: read('minISO', unavailable.minIso),
      maxIso: read('maxISO', unavailable.maxIso),
      minShutterSeconds:
          read('minShutterSeconds', unavailable.minShutterSeconds),
      maxShutterSeconds:
          read('maxShutterSeconds', unavailable.maxShutterSeconds),
      supportsAppleLog: map['supportsAppleLog'] == true,
      supportsProRes: map['supportsProRes'] == true,
      supports48MP: map['supports48MP'] == true,
    );
  }

  /// Longest usable exposure, as a denominator (for example 8000 for 1/8000).
  int get fastestShutterDenominator =>
      (1 / minShutterSeconds).round().clamp(1, 100000);

  /// Slowest usable exposure, as a denominator (usually 1/2 … 1).
  int get slowestShutterDenominator =>
      (1 / maxShutterSeconds).round().clamp(1, 100000);
}
