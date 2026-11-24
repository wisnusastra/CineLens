// lib/features/cinema_camera/domain/entities/film_look.dart

/// Adjustable film emulation layered on top of the tone / LUT.
///
/// When [useStockEffects] is true (default), built-in film stocks keep their
/// authentic tuned halation, bloom, grain and vignette while [shadowDepth] and
/// [acutance] still sculpt deep chiaroscuro shadows and optical crispness.
class FilmLook {
  /// Use each built-in film stock's authentic tuned halation, bloom & grain.
  final bool useStockEffects;

  /// Luminance grain amount (when manual override is active). 0 = digital clean.
  final double grain;

  /// Grain size. 0 keeps the finest possible 1 px grain, 1 roughly doubles it.
  final double grainSize;

  /// Warm glow bleeding out of highlights (film base scatter).
  final double halation;

  /// Neutral, wider highlight bloom.
  final double bloom;

  /// Corner darkening.
  final double vignette;

  /// Chiaroscuro Deep Film Toe (0…1): carves rich ink-black directional shadows
  /// without crushing sunlit highlight texture.
  final double shadowDepth;

  /// Optical micro-contrast / prime-lens acutance sharpness (0…1).
  final double acutance;

  /// Strength of an imported `.cube` LUT (ignored by matrix tones).
  final double lutMix;

  const FilmLook({
    this.useStockEffects = true,
    this.grain = 0.14,
    this.grainSize = 0.12,
    this.halation = 0.0,
    this.bloom = 0.0,
    this.vignette = 0.16,
    this.shadowDepth = 0.0,
    this.acutance = 0.0,
    this.lutMix = 1.0,
  });

  static const FilmLook neutral = FilmLook(
    useStockEffects: false,
    grain: 0,
    grainSize: 0,
    halation: 0,
    bloom: 0,
    vignette: 0,
    shadowDepth: 0,
    acutance: 0,
    lutMix: 1,
  );

  bool get isNeutral =>
      !useStockEffects &&
      grain <= 0.001 &&
      halation <= 0.001 &&
      bloom <= 0.001 &&
      vignette <= 0.001 &&
      shadowDepth <= 0.001 &&
      acutance <= 0.001;

  FilmLook copyWith({
    bool? useStockEffects,
    double? grain,
    double? grainSize,
    double? halation,
    double? bloom,
    double? vignette,
    double? shadowDepth,
    double? acutance,
    double? lutMix,
  }) {
    return FilmLook(
      useStockEffects: useStockEffects ?? this.useStockEffects,
      grain: grain ?? this.grain,
      grainSize: grainSize ?? this.grainSize,
      halation: halation ?? this.halation,
      bloom: bloom ?? this.bloom,
      vignette: vignette ?? this.vignette,
      shadowDepth: shadowDepth ?? this.shadowDepth,
      acutance: acutance ?? this.acutance,
      lutMix: lutMix ?? this.lutMix,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 4,
        'useStockEffects': useStockEffects,
        'grain': grain,
        'grainSize': grainSize,
        'halation': halation,
        'bloom': bloom,
        'vignette': vignette,
        'shadowDepth': shadowDepth,
        'acutance': acutance,
        'lutMix': lutMix,
      };

  factory FilmLook.fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback) {
      final value = json[key];
      if (value is num) return value.toDouble().clamp(0.0, 1.0);
      return fallback;
    }

    final version = (json['v'] as num?)?.toInt() ?? 1;
    final grain = read('grain', 0.14);
    final halation = read('halation', 0.0);
    final bloom = read('bloom', 0.0);
    final vignette = read('vignette', 0.16);
    final shadowDepth = read('shadowDepth', 0.0);
    var acutance = read('acutance', 0.0);

    // Upgrade untouched v1/v2 defaults cleanly so existing users immediately
    // get authentic stock halation/grain with natural zero-halo sharpness.
    final untouchedLegacy = version < 3 &&
        ((grain - 0.30).abs() < 0.03 || (grain - 0.12).abs() < 0.03) &&
        (halation <= 0.01 || (halation - 0.35).abs() < 0.03) &&
        (bloom <= 0.01 || (bloom - 0.20).abs() < 0.03);
    if (untouchedLegacy) return const FilmLook();

    // v3 shipped with a 0.22 default acutance that double-sharpened iPhone
    // Deep Fusion photos; reset untouched v3 default cleanly to 0.0.
    if (version == 3 && (acutance - 0.22).abs() < 0.005) {
      acutance = 0.0;
    }

    final useStock = json['useStockEffects'] is bool
        ? json['useStockEffects'] as bool
        : version >= 3;

    return FilmLook(
      useStockEffects: useStock,
      grain: grain,
      grainSize: read('grainSize', 0.12),
      halation: halation,
      bloom: bloom,
      vignette: vignette,
      shadowDepth: shadowDepth,
      acutance: acutance,
      lutMix: read('lutMix', 1.0),
    );
  }

  /// Payload understood by `AppDelegate.FilmEffects.from` & `ImportedLut.from`.
  Map<String, dynamic> toNative({
    String? lutPath,
    int? lutSize,
    double? mix,
  }) {
    return <String, dynamic>{
      'lutPath': lutPath,
      'lutSize': lutSize ?? 0,
      'lutMix': mix ?? lutMix,
      'useStockEffects': useStockEffects,
      'grain': grain,
      'grainSize': grainSize,
      'halation': halation,
      'bloom': bloom,
      'vignette': vignette,
      'shadowDepth': shadowDepth,
      'acutance': acutance,
    };
  }
}
