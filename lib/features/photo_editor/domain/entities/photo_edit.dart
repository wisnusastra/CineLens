// lib/features/photo_editor/domain/entities/photo_edit.dart

import 'dart:math' as math;

/// One draggable point of a tone curve, both coordinates normalised to 0…1.
class CurvePoint {
  final double x;
  final double y;

  const CurvePoint(this.x, this.y);

  CurvePoint clamped() => CurvePoint(
        x.clamp(0.0, 1.0),
        y.clamp(0.0, 1.0),
      );

  List<double> toJson() => <double>[x, y];

  static CurvePoint? tryParse(Object? raw) {
    if (raw is List && raw.length >= 2) {
      final x = raw[0];
      final y = raw[1];
      if (x is num && y is num) {
        return CurvePoint(x.toDouble(), y.toDouble()).clamped();
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CurvePoint &&
      (other.x - x).abs() < 0.0001 &&
      (other.y - y).abs() < 0.0001;

  @override
  int get hashCode => Object.hash((x * 10000).round(), (y * 10000).round());
}

/// Which tone curve a [CurvePoint] belongs to, mirroring the four tabs of a
/// Lightroom-style curve panel.
enum EditCurveChannel { rgb, red, green, blue }

extension EditCurveChannelLabel on EditCurveChannel {
  String get label => switch (this) {
        EditCurveChannel.rgb => 'RGB',
        EditCurveChannel.red => 'R',
        EditCurveChannel.green => 'G',
        EditCurveChannel.blue => 'B',
      };
}

/// One of the eight colour bands of the Colour Mix (HSL) panel.
class HslBand {
  final String name;
  final double hue;
  final double saturation;
  final double luminance;

  const HslBand({
    required this.name,
    this.hue = 0,
    this.saturation = 0,
    this.luminance = 0,
  });

  HslBand copyWith({
    double? hue,
    double? saturation,
    double? luminance,
  }) {
    return HslBand(
      name: name,
      hue: hue ?? this.hue,
      saturation: saturation ?? this.saturation,
      luminance: luminance ?? this.luminance,
    );
  }

  bool get isNeutral =>
      hue.abs() < 0.001 && saturation.abs() < 0.001 && luminance.abs() < 0.001;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'hue': hue,
        'sat': saturation,
        'lum': luminance,
      };

  static HslBand? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String) return null;
    return HslBand(
      name: name,
      hue: _unit(raw['hue']),
      saturation: _unit(raw['sat']),
      luminance: _unit(raw['lum']),
    );
  }
}

double _unit(Object? value) {
  if (value is num) return value.toDouble().clamp(-1.0, 1.0);
  return 0;
}

double _signed(Object? value) => _unit(value);

double _positive(Object? value) {
  if (value is num) return value.toDouble().clamp(0.0, 1.0);
  return 0;
}

/// The complete adjustment set of one photo or video.
///
/// Every value is normalised so the UI and the native Core Image pipeline share
/// one definition: exposure is in stops, everything else is -1…1 (or 0…1 for
/// effects that only add).
class PhotoEdit {
  /// Exposure in stops, -2…+2.
  final double exposure;

  /// Basic tone shaping, all -1…1.
  final double contrast;
  final double highlights;
  final double shadows;
  final double whites;
  final double blacks;

  /// White balance, -1…1.
  final double temperature;
  final double tint;

  /// Colour, -1…1.
  final double vibrance;
  final double saturation;

  /// Effects, -1…1 except [fade] and [grain] (0…1).
  final double clarity;
  final double texture;
  final double dehaze;
  final double fade;
  final double grain;
  final double vignette;

  /// Detail, 0…1.
  final double sharpen;
  final double noiseReduction;

  /// Tone curves. An empty list means the identity curve.
  final List<CurvePoint> curveRgb;
  final List<CurvePoint> curveRed;
  final List<CurvePoint> curveGreen;
  final List<CurvePoint> curveBlue;

  /// Eight colour bands (red, orange, yellow, green, aqua, blue, purple,
  /// magenta).
  final List<HslBand> hsl;

  const PhotoEdit({
    this.exposure = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.whites = 0,
    this.blacks = 0,
    this.temperature = 0,
    this.tint = 0,
    this.vibrance = 0,
    this.saturation = 0,
    this.clarity = 0,
    this.texture = 0,
    this.dehaze = 0,
    this.fade = 0,
    this.grain = 0,
    this.vignette = 0,
    this.sharpen = 0,
    this.noiseReduction = 0,
    this.curveRgb = const <CurvePoint>[],
    this.curveRed = const <CurvePoint>[],
    this.curveGreen = const <CurvePoint>[],
    this.curveBlue = const <CurvePoint>[],
    this.hsl = defaultHslBands,
  });

  static const List<HslBand> defaultHslBands = <HslBand>[
    HslBand(name: 'Merah'),
    HslBand(name: 'Oranye'),
    HslBand(name: 'Kuning'),
    HslBand(name: 'Hijau'),
    HslBand(name: 'Aqua'),
    HslBand(name: 'Biru'),
    HslBand(name: 'Ungu'),
    HslBand(name: 'Magenta'),
  ];

  static const PhotoEdit neutral = PhotoEdit();

  PhotoEdit copyWith({
    double? exposure,
    double? contrast,
    double? highlights,
    double? shadows,
    double? whites,
    double? blacks,
    double? temperature,
    double? tint,
    double? vibrance,
    double? saturation,
    double? clarity,
    double? texture,
    double? dehaze,
    double? fade,
    double? grain,
    double? vignette,
    double? sharpen,
    double? noiseReduction,
    List<CurvePoint>? curveRgb,
    List<CurvePoint>? curveRed,
    List<CurvePoint>? curveGreen,
    List<CurvePoint>? curveBlue,
    List<HslBand>? hsl,
  }) {
    return PhotoEdit(
      exposure: (exposure ?? this.exposure).clamp(-2.0, 2.0),
      contrast: (contrast ?? this.contrast).clamp(-1.0, 1.0),
      highlights: (highlights ?? this.highlights).clamp(-1.0, 1.0),
      shadows: (shadows ?? this.shadows).clamp(-1.0, 1.0),
      whites: (whites ?? this.whites).clamp(-1.0, 1.0),
      blacks: (blacks ?? this.blacks).clamp(-1.0, 1.0),
      temperature: (temperature ?? this.temperature).clamp(-1.0, 1.0),
      tint: (tint ?? this.tint).clamp(-1.0, 1.0),
      vibrance: (vibrance ?? this.vibrance).clamp(-1.0, 1.0),
      saturation: (saturation ?? this.saturation).clamp(-1.0, 1.0),
      clarity: (clarity ?? this.clarity).clamp(-1.0, 1.0),
      texture: (texture ?? this.texture).clamp(-1.0, 1.0),
      dehaze: (dehaze ?? this.dehaze).clamp(-1.0, 1.0),
      fade: (fade ?? this.fade).clamp(0.0, 1.0),
      grain: (grain ?? this.grain).clamp(0.0, 1.0),
      vignette: (vignette ?? this.vignette).clamp(0.0, 1.0),
      sharpen: (sharpen ?? this.sharpen).clamp(0.0, 1.0),
      noiseReduction: (noiseReduction ?? this.noiseReduction).clamp(0.0, 1.0),
      curveRgb: curveRgb ?? this.curveRgb,
      curveRed: curveRed ?? this.curveRed,
      curveGreen: curveGreen ?? this.curveGreen,
      curveBlue: curveBlue ?? this.curveBlue,
      hsl: hsl ?? this.hsl,
    );
  }

  List<CurvePoint> curveFor(EditCurveChannel channel) => switch (channel) {
        EditCurveChannel.rgb => curveRgb,
        EditCurveChannel.red => curveRed,
        EditCurveChannel.green => curveGreen,
        EditCurveChannel.blue => curveBlue,
      };

  PhotoEdit withCurve(EditCurveChannel channel, List<CurvePoint> points) {
    final sorted = _normalizeCurve(points);
    return switch (channel) {
      EditCurveChannel.rgb => copyWith(curveRgb: sorted),
      EditCurveChannel.red => copyWith(curveRed: sorted),
      EditCurveChannel.green => copyWith(curveGreen: sorted),
      EditCurveChannel.blue => copyWith(curveBlue: sorted),
    };
  }

  PhotoEdit withHslBand(int index, HslBand band) {
    if (index < 0 || index >= hsl.length) return this;
    final updated = List<HslBand>.of(hsl);
    updated[index] = band;
    return copyWith(hsl: updated);
  }

  /// True when nothing would change, so the editor can skip a render.
  bool get isNeutral {
    return exposure.abs() < 0.001 &&
        contrast.abs() < 0.001 &&
        highlights.abs() < 0.001 &&
        shadows.abs() < 0.001 &&
        whites.abs() < 0.001 &&
        blacks.abs() < 0.001 &&
        temperature.abs() < 0.001 &&
        tint.abs() < 0.001 &&
        vibrance.abs() < 0.001 &&
        saturation.abs() < 0.001 &&
        clarity.abs() < 0.001 &&
        texture.abs() < 0.001 &&
        dehaze.abs() < 0.001 &&
        fade.abs() < 0.001 &&
        grain.abs() < 0.001 &&
        vignette.abs() < 0.001 &&
        sharpen.abs() < 0.001 &&
        noiseReduction.abs() < 0.001 &&
        curveRgb.isEmpty &&
        curveRed.isEmpty &&
        curveGreen.isEmpty &&
        curveBlue.isEmpty &&
        hsl.every((band) => band.isNeutral);
  }

  /// Payload understood by the native Core Image editor.
  Map<String, dynamic> toParameters() {
    List<List<double>> curve(List<CurvePoint> points) =>
        points.map((point) => point.toJson()).toList();

    return <String, dynamic>{
      'exposure': exposure,
      'contrast': contrast,
      'highlights': highlights,
      'shadows': shadows,
      'whites': whites,
      'blacks': blacks,
      'temperature': temperature,
      'tint': tint,
      'vibrance': vibrance,
      'saturation': saturation,
      'clarity': clarity,
      'texture': texture,
      'dehaze': dehaze,
      'fade': fade,
      'grain': grain,
      'vignette': vignette,
      'sharpen': sharpen,
      'noiseReduction': noiseReduction,
      'curveRgb': curve(curveRgb),
      'curveRed': curve(curveRed),
      'curveGreen': curve(curveGreen),
      'curveBlue': curve(curveBlue),
      'hsl': hsl
          .map((band) => <double>[band.hue, band.saturation, band.luminance])
          .toList(),
    };
  }

  Map<String, dynamic> toJson() => toParameters();

  static PhotoEdit fromJson(Map<String, dynamic> json) {
    List<CurvePoint> parseCurve(Object? raw) {
      if (raw is! List) return const <CurvePoint>[];
      final points = raw
          .map(CurvePoint.tryParse)
          .whereType<CurvePoint>()
          .toList();
      return _normalizeCurve(points);
    }

    final parsedHsl = <HslBand>[];
    final rawHsl = json['hsl'];
    if (rawHsl is List) {
      for (var index = 0; index < defaultHslBands.length; index++) {
        final raw = index < rawHsl.length ? rawHsl[index] : null;
        final parsed = HslBand.tryParse(raw);
        if (parsed != null) {
          parsedHsl.add(parsed);
        } else if (raw is List && raw.length >= 3) {
          parsedHsl.add(
            HslBand(
              name: defaultHslBands[index].name,
              hue: _unit(raw[0]),
              saturation: _unit(raw[1]),
              luminance: _unit(raw[2]),
            ),
          );
        } else {
          parsedHsl.add(defaultHslBands[index]);
        }
      }
    }

    return PhotoEdit(
      exposure: _signed(json['exposure']).clamp(-2.0, 2.0),
      contrast: _signed(json['contrast']),
      highlights: _signed(json['highlights']),
      shadows: _signed(json['shadows']),
      whites: _signed(json['whites']),
      blacks: _signed(json['blacks']),
      temperature: _signed(json['temperature']),
      tint: _signed(json['tint']),
      vibrance: _signed(json['vibrance']),
      saturation: _signed(json['saturation']),
      clarity: _signed(json['clarity']),
      texture: _signed(json['texture']),
      dehaze: _signed(json['dehaze']),
      fade: _positive(json['fade']),
      grain: _positive(json['grain']),
      vignette: _positive(json['vignette']),
      sharpen: _positive(json['sharpen']),
      noiseReduction: _positive(json['noiseReduction']),
      curveRgb: parseCurve(json['curveRgb']),
      curveRed: parseCurve(json['curveRed']),
      curveGreen: parseCurve(json['curveGreen']),
      curveBlue: parseCurve(json['curveBlue']),
      hsl: parsedHsl.length == defaultHslBands.length
          ? parsedHsl
          : defaultHslBands,
    );
  }

  /// Sorts points by x and drops unusable ones, so the native sampler never
  /// sees a curve that folds back on itself.
  static List<CurvePoint> _normalizeCurve(List<CurvePoint> points) {
    if (points.length < 2) return const <CurvePoint>[];
    final sorted = points.map((point) => point.clamped()).toList()
      ..sort((a, b) => a.x.compareTo(b.x));

    final unique = <CurvePoint>[];
    for (final point in sorted) {
      if (unique.isEmpty || (point.x - unique.last.x).abs() > 0.004) {
        unique.add(point);
      }
    }
    if (unique.length < 2) return const <CurvePoint>[];

    // A curve is meaningless if the whole shape is the identity line.
    final identity = unique.every((point) => (point.y - point.x).abs() < 0.002);
    return identity ? const <CurvePoint>[] : unique;
  }
}

/// Small helpers used by the UI to format slider values.
class EditValueFormat {
  EditValueFormat._();

  static String exposure(double value) {
    final sign = value >= 0 ? '+' : '';
    return '$sign${value.toStringAsFixed(1)} EV';
  }

  static String signed(double value) {
    final scaled = (value * 100).round();
    return scaled > 0 ? '+$scaled' : '$scaled';
  }

  static String percent(double value) => '${(value * 100).round()}';

  static String degrees(double value) {
    final degrees = (value * 60).round();
    return degrees > 0 ? '+$degrees°' : '$degrees°';
  }
}

/// Kept here so both the editor screen and tests can reuse the sampling code
/// used by the preview painter.
double sampleCurve(List<CurvePoint> points, double x) {
  if (points.length < 2) return x.clamp(0.0, 1.0);
  final value = x.clamp(0.0, 1.0);

  if (value <= points.first.x) return points.first.y;
  if (value >= points.last.x) return points.last.y;

  for (var index = 0; index < points.length - 1; index++) {
    final a = points[index];
    final b = points[index + 1];
    if (value >= a.x && value <= b.x) {
      final span = b.x - a.x;
      if (span.abs() < 0.00001) return b.y;
      final t = (value - a.x) / span;
      return (a.y + (b.y - a.y) * t).clamp(0.0, 1.0);
    }
  }
  return math.min(points.last.y, 1.0);
}
