// lib/features/cinema_camera/domain/entities/film_look.dart

/// Adjustable film emulation layered on top of the tone / LUT.
///
/// The strengths are 0…1 and are applied by the native Core Image pipeline to
/// both stills and clips, so the exported file gets exactly the same treatment
/// as the viewfinder preview.
class FilmLook {
  /// Luminance grain amount. 0 = digital clean, 1 = heavy 16mm texture.
  final double grain;

  /// Grain size. 0 keeps the finest possible 1 px grain, 1 roughly doubles it.
  final double grainSize;

  /// Warm glow bleeding out of highlights (film base scatter).
  final double halation;

  /// Neutral, wider highlight bloom.
  final double bloom;

  /// Corner darkening.
  final double vignette;

  /// Strength of an imported `.cube` LUT (ignored by matrix tones).
  final double lutMix;

  const FilmLook({
    this.grain = 0.30,
    this.grainSize = 0.10,
    this.halation = 0.35,
    this.bloom = 0.20,
    this.vignette = 0.25,
    this.lutMix = 1.0,
  });

  static const FilmLook neutral = FilmLook(
    grain: 0,
    grainSize: 0,
    halation: 0,
    bloom: 0,
    vignette: 0,
    lutMix: 1,
  );

  bool get isNeutral =>
      grain <= 0.001 &&
      halation <= 0.001 &&
      bloom <= 0.001 &&
      vignette <= 0.001;

  FilmLook copyWith({
    double? grain,
    double? grainSize,
    double? halation,
    double? bloom,
    double? vignette,
    double? lutMix,
  }) {
    return FilmLook(
      grain: grain ?? this.grain,
      grainSize: grainSize ?? this.grainSize,
      halation: halation ?? this.halation,
      bloom: bloom ?? this.bloom,
      vignette: vignette ?? this.vignette,
      lutMix: lutMix ?? this.lutMix,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'grain': grain,
        'grainSize': grainSize,
        'halation': halation,
        'bloom': bloom,
        'vignette': vignette,
        'lutMix': lutMix,
      };

  factory FilmLook.fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback) {
      final value = json[key];
      if (value is num) return value.toDouble().clamp(0.0, 1.0);
      return fallback;
    }

    return FilmLook(
      grain: read('grain', 0.30),
      grainSize: read('grainSize', 0.10),
      halation: read('halation', 0.35),
      bloom: read('bloom', 0.20),
      vignette: read('vignette', 0.25),
      lutMix: read('lutMix', 1.0),
    );
  }

  /// Payload understood by `AppDelegate.filmLook(from:)`.
  Map<String, dynamic> toNative({
    String? lutPath,
    int? lutSize,
    double? mix,
  }) {
    return <String, dynamic>{
      'lutPath': lutPath,
      'lutSize': lutSize ?? 0,
      'lutMix': mix ?? lutMix,
      'grain': grain,
      'grainSize': grainSize,
      'halation': halation,
      'bloom': bloom,
      'vignette': vignette,
    };
  }
}
