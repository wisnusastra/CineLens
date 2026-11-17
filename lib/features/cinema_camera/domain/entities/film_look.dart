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
    this.grain = 0.12,
    this.grainSize = 0.10,
    this.halation = 0.0,
    this.bloom = 0.0,
    this.vignette = 0.16,
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
        'v': 2,
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

    final version = (json['v'] as num?)?.toInt() ?? 1;
    final grain = read('grain', 0.12);
    final halation = read('halation', 0.0);
    final bloom = read('bloom', 0.0);
    final vignette = read('vignette', 0.16);

    // v1 shipped heavier defaults (0.30 / 0.35 / 0.20 / 0.25). Tones read as
    // washed out behind that much halation and bloom, and every export had to
    // render the extra glow. Only untouched v1 values are replaced; a look the
    // user actually dialled in is preserved.
    final untouchedV1Defaults = version < 2 &&
        (grain - 0.30).abs() < 0.02 &&
        (halation - 0.35).abs() < 0.02 &&
        (bloom - 0.20).abs() < 0.02 &&
        (vignette - 0.25).abs() < 0.02;
    if (untouchedV1Defaults) return const FilmLook();

    return FilmLook(
      grain: grain,
      grainSize: read('grainSize', 0.10),
      halation: halation,
      bloom: bloom,
      vignette: vignette,
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
