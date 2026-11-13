import 'dart:math' as math;

class CustomGradeParameters {
  final double exposure;
  final double contrast;
  final double saturation;
  final double temperature;
  final double tint;

  const CustomGradeParameters({
    this.exposure = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.temperature = 0.0,
    this.tint = 0.0,
  });

  CustomGradeParameters copyWith({
    double? exposure,
    double? contrast,
    double? saturation,
    double? temperature,
    double? tint,
  }) {
    return CustomGradeParameters(
      exposure: exposure ?? this.exposure,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      temperature: temperature ?? this.temperature,
      tint: tint ?? this.tint,
    );
  }
}

class ColorMatrixBuilder {
  ColorMatrixBuilder._();

  static List<double> build(CustomGradeParameters params) {
    final double expGain = math.pow(2.0, params.exposure).toDouble();
    final double c = params.contrast;
    final double cOffset = 128.0 * (1.0 - c);

    const double lumR = 0.2126;
    const double lumG = 0.7152;
    const double lumB = 0.0722;

    final double s = params.saturation;
    final double sr = (1.0 - s) * lumR;
    final double sg = (1.0 - s) * lumG;
    final double sb = (1.0 - s) * lumB;

    final double rTemp = 1.0 + (params.temperature * 0.18);
    final double bTemp = 1.0 - (params.temperature * 0.18);
    final double gTint = 1.0 - (params.tint * 0.14);
    final double rbTint = 1.0 + (params.tint * 0.07);

    final double rScale = expGain * c * rTemp * rbTint;
    final double gScale = expGain * c * gTint;
    final double bScale = expGain * c * bTemp * rbTint;

    return <double>[
      (sr + s) * rScale, sg * rScale, sb * rScale, 0.0, cOffset,
      sr * gScale, (sg + s) * gScale, sb * gScale, 0.0, cOffset,
      sr * bScale, sg * bScale, (sb + s) * bScale, 0.0, cOffset,
      0.0, 0.0, 0.0, 1.0, 0.0,
    ];
  }
}
