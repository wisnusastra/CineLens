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

/// One wheel of Lightroom's 3-way Color Grading panel (Shadows, Midtones,
/// Highlights): hue (0…360°), saturation (0…1), and luminance (-1…1).
class ColorWheelGrade {
  final double hue;
  final double saturation;
  final double luminance;

  const ColorWheelGrade({
    this.hue = 0,
    this.saturation = 0,
    this.luminance = 0,
  });

  static const ColorWheelGrade neutral = ColorWheelGrade();

  bool get isNeutral => saturation <= 0.001 && luminance.abs() < 0.001;

  ColorWheelGrade copyWith({
    double? hue,
    double? saturation,
    double? luminance,
  }) {
    var nextHue = hue ?? this.hue;
    nextHue = nextHue % 360.0;
    if (nextHue < 0) nextHue += 360.0;
    return ColorWheelGrade(
      hue: nextHue,
      saturation: (saturation ?? this.saturation).clamp(0.0, 1.0),
      luminance: (luminance ?? this.luminance).clamp(-1.0, 1.0),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'hue': hue,
        'sat': saturation,
        'lum': luminance,
      };

  static ColorWheelGrade fromJson(Object? raw) {
    if (raw is! Map) return neutral;
    final rawHue = raw['hue'];
    var h = rawHue is num ? rawHue.toDouble() % 360.0 : 0.0;
    if (h < 0) h += 360.0;
    return ColorWheelGrade(
      hue: h,
      saturation: _positive(raw['sat']),
      luminance: _signed(raw['lum']),
    );
  }
}

/// Complete 3-way Color Grading settings (Shadows, Midtones, Highlights,
/// Blending, Balance).
class ColorGrading {
  final ColorWheelGrade shadows;
  final ColorWheelGrade midtones;
  final ColorWheelGrade highlights;
  final double blending;
  final double balance;

  const ColorGrading({
    this.shadows = ColorWheelGrade.neutral,
    this.midtones = ColorWheelGrade.neutral,
    this.highlights = ColorWheelGrade.neutral,
    this.blending = 0.5,
    this.balance = 0.0,
  });

  static const ColorGrading neutral = ColorGrading();

  bool get isNeutral =>
      shadows.isNeutral && midtones.isNeutral && highlights.isNeutral;

  ColorGrading copyWith({
    ColorWheelGrade? shadows,
    ColorWheelGrade? midtones,
    ColorWheelGrade? highlights,
    double? blending,
    double? balance,
  }) {
    return ColorGrading(
      shadows: shadows ?? this.shadows,
      midtones: midtones ?? this.midtones,
      highlights: highlights ?? this.highlights,
      blending: (blending ?? this.blending).clamp(0.0, 1.0),
      balance: (balance ?? this.balance).clamp(-1.0, 1.0),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'shadows': shadows.toJson(),
        'midtones': midtones.toJson(),
        'highlights': highlights.toJson(),
        'blending': blending,
        'balance': balance,
      };

  static ColorGrading fromJson(Object? raw) {
    if (raw is! Map) return neutral;
    return ColorGrading(
      shadows: ColorWheelGrade.fromJson(raw['shadows']),
      midtones: ColorWheelGrade.fromJson(raw['midtones']),
      highlights: ColorWheelGrade.fromJson(raw['highlights']),
      blending: raw['blending'] is num
          ? (raw['blending'] as num).toDouble().clamp(0.0, 1.0)
          : 0.5,
      balance: _signed(raw['balance']),
    );
  }
}

/// One selective adjustment mask (Linear Gradient or Radial Gradient) with
/// independent local Light, Color and Detail sliders.
class SelectiveMask {
  final String id;
  final String name;

  /// `'linear'` or `'radial'`.
  final String type;

  /// Normalised 0…1 coordinates (UI space: top-left = 0,0, bottom-right = 1,1).
  /// For linear: start = full effect, end = zero effect.
  /// For radial: start = centre, end = edge point defining radius.
  final double startX;
  final double startY;
  final double endX;
  final double endY;

  final double feather;
  final bool inverted;

  final double exposure;
  final double contrast;
  final double highlights;
  final double shadows;
  final double temperature;
  final double saturation;
  final double clarity;
  final double sharpen;

  const SelectiveMask({
    required this.id,
    required this.name,
    this.type = 'radial',
    this.startX = 0.5,
    this.startY = 0.5,
    this.endX = 0.82,
    this.endY = 0.5,
    this.feather = 0.5,
    this.inverted = false,
    this.exposure = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.temperature = 0,
    this.saturation = 0,
    this.clarity = 0,
    this.sharpen = 0,
  });

  bool get isLinear => type == 'linear';

  bool get isNeutral =>
      exposure.abs() < 0.001 &&
      contrast.abs() < 0.001 &&
      highlights.abs() < 0.001 &&
      shadows.abs() < 0.001 &&
      temperature.abs() < 0.001 &&
      saturation.abs() < 0.001 &&
      clarity.abs() < 0.001 &&
      sharpen.abs() < 0.001;

  SelectiveMask copyWith({
    String? name,
    String? type,
    double? startX,
    double? startY,
    double? endX,
    double? endY,
    double? feather,
    bool? inverted,
    double? exposure,
    double? contrast,
    double? highlights,
    double? shadows,
    double? temperature,
    double? saturation,
    double? clarity,
    double? sharpen,
  }) {
    return SelectiveMask(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      startX: (startX ?? this.startX).clamp(0.0, 1.0),
      startY: (startY ?? this.startY).clamp(0.0, 1.0),
      endX: (endX ?? this.endX).clamp(0.0, 1.0),
      endY: (endY ?? this.endY).clamp(0.0, 1.0),
      feather: (feather ?? this.feather).clamp(0.05, 1.0),
      inverted: inverted ?? this.inverted,
      exposure: (exposure ?? this.exposure).clamp(-2.0, 2.0),
      contrast: (contrast ?? this.contrast).clamp(-1.0, 1.0),
      highlights: (highlights ?? this.highlights).clamp(-1.0, 1.0),
      shadows: (shadows ?? this.shadows).clamp(-1.0, 1.0),
      temperature: (temperature ?? this.temperature).clamp(-1.0, 1.0),
      saturation: (saturation ?? this.saturation).clamp(-1.0, 1.0),
      clarity: (clarity ?? this.clarity).clamp(-1.0, 1.0),
      sharpen: (sharpen ?? this.sharpen).clamp(0.0, 1.0),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'type': type,
        'startX': startX,
        'startY': startY,
        'endX': endX,
        'endY': endY,
        'feather': feather,
        'inverted': inverted,
        'exposure': exposure,
        'contrast': contrast,
        'highlights': highlights,
        'shadows': shadows,
        'temperature': temperature,
        'saturation': saturation,
        'clarity': clarity,
        'sharpen': sharpen,
      };

  static SelectiveMask? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final type = raw['type'] == 'linear' ? 'linear' : 'radial';
    final name = raw['name'] is String && (raw['name'] as String).isNotEmpty
        ? raw['name'] as String
        : (type == 'linear' ? 'Gradien Linear' : 'Gradien Radial');
    double coord(Object? v, double fallback) =>
        v is num ? v.toDouble().clamp(0.0, 1.0) : fallback;
    return SelectiveMask(
      id: id,
      name: name,
      type: type,
      startX: coord(raw['startX'], 0.5),
      startY: coord(raw['startY'], type == 'linear' ? 0.15 : 0.5),
      endX: coord(raw['endX'], type == 'linear' ? 0.5 : 0.82),
      endY: coord(raw['endY'], type == 'linear' ? 0.55 : 0.5),
      feather: coord(raw['feather'], 0.5).clamp(0.05, 1.0),
      inverted: raw['inverted'] == true,
      exposure: _signed(raw['exposure']).clamp(-2.0, 2.0),
      contrast: _signed(raw['contrast']),
      highlights: _signed(raw['highlights']),
      shadows: _signed(raw['shadows']),
      temperature: _signed(raw['temperature']),
      saturation: _signed(raw['saturation']),
      clarity: _signed(raw['clarity']),
      sharpen: _positive(raw['sharpen']),
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

double _exposure(Object? value) {
  if (value is num) return value.toDouble().clamp(-2.0, 2.0);
  return 0;
}

/// The complete adjustment set of one photo or video — covering Lightroom's
/// full Light, Curve, Color, Mix, 3-Way Color Grading, Effects, Detail,
/// Lens Blur, Selective Masking, Optics, and Crop/Geometry pipeline.
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

  /// Colour, -1…1, plus panchromatic B&W toggle.
  final double vibrance;
  final double saturation;
  final bool blackAndWhite;

  /// Effects: clarity/texture/dehaze (-1…1), fade (0…1), full Lightroom
  /// vignette (amount 0…1, midpoint 0…1, feather 0…1, roundness -1…1),
  /// and full grain (amount/size/roughness 0…1).
  final double clarity;
  final double texture;
  final double dehaze;
  final double fade;
  final double grain;
  final double grainSize;
  final double grainRoughness;
  final double vignette;
  final double vignetteMidpoint;
  final double vignetteFeather;
  final double vignetteRoundness;

  /// Detail: sharpen amount & radius, luminance NR, and chroma-only Color NR.
  final double sharpen;
  final double sharpenRadius;
  final double noiseReduction;
  final double colorNoiseReduction;

  /// Optics: radial barrel/pincushion distortion (-1…1), lens vignette
  /// correction (0…1), and chromatic aberration defringe (0…1).
  final double lensDistortion;
  final double opticsVignette;
  final double defringe;

  /// Crop & Geometry: aspect preset, 90° quarter turns, flips, straighten
  /// (-45°…+45°), and vertical/horizontal perspective keystone (-1…1).
  final String cropAspect;
  final int rotateQuarterTurns;
  final bool flipHorizontal;
  final bool flipVertical;
  final double straightenDegrees;
  final double verticalPerspective;
  final double horizontalPerspective;

  /// Lens Blur (optical disc bokeh): amount (0…1), style ('radial'|'linear'),
  /// focus centre (0…1), focus radius (0.05…0.9), transition feather (0.05…1),
  /// and highlight bokeh boost (0…1).
  final double blurAmount;
  final String blurStyle;
  final double blurCenterX;
  final double blurCenterY;
  final double blurRadius;
  final double blurFeather;
  final double blurBokehBoost;

  /// Tone curves. An empty list means the identity curve.
  final List<CurvePoint> curveRgb;
  final List<CurvePoint> curveRed;
  final List<CurvePoint> curveGreen;
  final List<CurvePoint> curveBlue;

  /// Eight colour bands (red, orange, yellow, green, aqua, blue, purple,
  /// magenta).
  final List<HslBand> hsl;

  /// 3-way Color Grading (Shadows / Midtones / Highlights wheels + blend/balance).
  final ColorGrading colorGrading;

  /// Layered selective adjustment masks (Linear & Radial gradients).
  final List<SelectiveMask> masks;

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
    this.blackAndWhite = false,
    this.clarity = 0,
    this.texture = 0,
    this.dehaze = 0,
    this.fade = 0,
    this.grain = 0,
    this.grainSize = 0.25,
    this.grainRoughness = 0.5,
    this.vignette = 0,
    this.vignetteMidpoint = 0.5,
    this.vignetteFeather = 0.5,
    this.vignetteRoundness = 0.0,
    this.sharpen = 0,
    this.sharpenRadius = 0.35,
    this.noiseReduction = 0,
    this.colorNoiseReduction = 0,
    this.lensDistortion = 0,
    this.opticsVignette = 0,
    this.defringe = 0,
    this.cropAspect = 'original',
    this.rotateQuarterTurns = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.straightenDegrees = 0,
    this.verticalPerspective = 0,
    this.horizontalPerspective = 0,
    this.blurAmount = 0,
    this.blurStyle = 'radial',
    this.blurCenterX = 0.5,
    this.blurCenterY = 0.5,
    this.blurRadius = 0.32,
    this.blurFeather = 0.45,
    this.blurBokehBoost = 0.25,
    this.curveRgb = const <CurvePoint>[],
    this.curveRed = const <CurvePoint>[],
    this.curveGreen = const <CurvePoint>[],
    this.curveBlue = const <CurvePoint>[],
    this.hsl = defaultHslBands,
    this.colorGrading = ColorGrading.neutral,
    this.masks = const <SelectiveMask>[],
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
    bool? blackAndWhite,
    double? clarity,
    double? texture,
    double? dehaze,
    double? fade,
    double? grain,
    double? grainSize,
    double? grainRoughness,
    double? vignette,
    double? vignetteMidpoint,
    double? vignetteFeather,
    double? vignetteRoundness,
    double? sharpen,
    double? sharpenRadius,
    double? noiseReduction,
    double? colorNoiseReduction,
    double? lensDistortion,
    double? opticsVignette,
    double? defringe,
    String? cropAspect,
    int? rotateQuarterTurns,
    bool? flipHorizontal,
    bool? flipVertical,
    double? straightenDegrees,
    double? verticalPerspective,
    double? horizontalPerspective,
    double? blurAmount,
    String? blurStyle,
    double? blurCenterX,
    double? blurCenterY,
    double? blurRadius,
    double? blurFeather,
    double? blurBokehBoost,
    List<CurvePoint>? curveRgb,
    List<CurvePoint>? curveRed,
    List<CurvePoint>? curveGreen,
    List<CurvePoint>? curveBlue,
    List<HslBand>? hsl,
    ColorGrading? colorGrading,
    List<SelectiveMask>? masks,
  }) {
    final nextTurns = (rotateQuarterTurns ?? this.rotateQuarterTurns) % 4;
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
      blackAndWhite: blackAndWhite ?? this.blackAndWhite,
      clarity: (clarity ?? this.clarity).clamp(-1.0, 1.0),
      texture: (texture ?? this.texture).clamp(-1.0, 1.0),
      dehaze: (dehaze ?? this.dehaze).clamp(-1.0, 1.0),
      fade: (fade ?? this.fade).clamp(0.0, 1.0),
      grain: (grain ?? this.grain).clamp(0.0, 1.0),
      grainSize: (grainSize ?? this.grainSize).clamp(0.0, 1.0),
      grainRoughness: (grainRoughness ?? this.grainRoughness).clamp(0.0, 1.0),
      vignette: (vignette ?? this.vignette).clamp(0.0, 1.0),
      vignetteMidpoint:
          (vignetteMidpoint ?? this.vignetteMidpoint).clamp(0.0, 1.0),
      vignetteFeather:
          (vignetteFeather ?? this.vignetteFeather).clamp(0.0, 1.0),
      vignetteRoundness:
          (vignetteRoundness ?? this.vignetteRoundness).clamp(-1.0, 1.0),
      sharpen: (sharpen ?? this.sharpen).clamp(0.0, 1.0),
      sharpenRadius: (sharpenRadius ?? this.sharpenRadius).clamp(0.0, 1.0),
      noiseReduction: (noiseReduction ?? this.noiseReduction).clamp(0.0, 1.0),
      colorNoiseReduction:
          (colorNoiseReduction ?? this.colorNoiseReduction).clamp(0.0, 1.0),
      lensDistortion: (lensDistortion ?? this.lensDistortion).clamp(-1.0, 1.0),
      opticsVignette: (opticsVignette ?? this.opticsVignette).clamp(0.0, 1.0),
      defringe: (defringe ?? this.defringe).clamp(0.0, 1.0),
      cropAspect: cropAspect ?? this.cropAspect,
      rotateQuarterTurns: nextTurns < 0 ? nextTurns + 4 : nextTurns,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      flipVertical: flipVertical ?? this.flipVertical,
      straightenDegrees:
          (straightenDegrees ?? this.straightenDegrees).clamp(-45.0, 45.0),
      verticalPerspective:
          (verticalPerspective ?? this.verticalPerspective).clamp(-1.0, 1.0),
      horizontalPerspective:
          (horizontalPerspective ?? this.horizontalPerspective)
              .clamp(-1.0, 1.0),
      blurAmount: (blurAmount ?? this.blurAmount).clamp(0.0, 1.0),
      blurStyle: blurStyle ?? this.blurStyle,
      blurCenterX: (blurCenterX ?? this.blurCenterX).clamp(0.0, 1.0),
      blurCenterY: (blurCenterY ?? this.blurCenterY).clamp(0.0, 1.0),
      blurRadius: (blurRadius ?? this.blurRadius).clamp(0.05, 0.9),
      blurFeather: (blurFeather ?? this.blurFeather).clamp(0.05, 1.0),
      blurBokehBoost: (blurBokehBoost ?? this.blurBokehBoost).clamp(0.0, 1.0),
      curveRgb: curveRgb ?? this.curveRgb,
      curveRed: curveRed ?? this.curveRed,
      curveGreen: curveGreen ?? this.curveGreen,
      curveBlue: curveBlue ?? this.curveBlue,
      hsl: hsl ?? this.hsl,
      colorGrading: colorGrading ?? this.colorGrading,
      masks: masks ?? this.masks,
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

  PhotoEdit withMaskUpdated(SelectiveMask mask) {
    final updated = masks.map((m) => m.id == mask.id ? mask : m).toList();
    return copyWith(masks: updated);
  }

  bool get hasGeometryChanges =>
      cropAspect != 'original' ||
      rotateQuarterTurns != 0 ||
      flipHorizontal ||
      flipVertical ||
      straightenDegrees.abs() > 0.05 ||
      verticalPerspective.abs() > 0.001 ||
      horizontalPerspective.abs() > 0.001;

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
        !blackAndWhite &&
        clarity.abs() < 0.001 &&
        texture.abs() < 0.001 &&
        dehaze.abs() < 0.001 &&
        fade.abs() < 0.001 &&
        grain.abs() < 0.001 &&
        vignette.abs() < 0.001 &&
        sharpen.abs() < 0.001 &&
        noiseReduction.abs() < 0.001 &&
        colorNoiseReduction.abs() < 0.001 &&
        lensDistortion.abs() < 0.001 &&
        opticsVignette.abs() < 0.001 &&
        defringe.abs() < 0.001 &&
        !hasGeometryChanges &&
        blurAmount.abs() < 0.001 &&
        curveRgb.isEmpty &&
        curveRed.isEmpty &&
        curveGreen.isEmpty &&
        curveBlue.isEmpty &&
        hsl.every((band) => band.isNeutral) &&
        colorGrading.isNeutral &&
        masks.every((m) => m.isNeutral);
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
      'blackAndWhite': blackAndWhite,
      'clarity': clarity,
      'texture': texture,
      'dehaze': dehaze,
      'fade': fade,
      'grain': grain,
      'grainSize': grainSize,
      'grainRoughness': grainRoughness,
      'vignette': vignette,
      'vignetteMidpoint': vignetteMidpoint,
      'vignetteFeather': vignetteFeather,
      'vignetteRoundness': vignetteRoundness,
      'sharpen': sharpen,
      'sharpenRadius': sharpenRadius,
      'noiseReduction': noiseReduction,
      'colorNoiseReduction': colorNoiseReduction,
      'lensDistortion': lensDistortion,
      'opticsVignette': opticsVignette,
      'defringe': defringe,
      'cropAspect': cropAspect,
      'rotateQuarterTurns': rotateQuarterTurns,
      'flipHorizontal': flipHorizontal,
      'flipVertical': flipVertical,
      'straightenDegrees': straightenDegrees,
      'verticalPerspective': verticalPerspective,
      'horizontalPerspective': horizontalPerspective,
      'blurAmount': blurAmount,
      'blurStyle': blurStyle,
      'blurCenterX': blurCenterX,
      'blurCenterY': blurCenterY,
      'blurRadius': blurRadius,
      'blurFeather': blurFeather,
      'blurBokehBoost': blurBokehBoost,
      'curveRgb': curve(curveRgb),
      'curveRed': curve(curveRed),
      'curveGreen': curve(curveGreen),
      'curveBlue': curve(curveBlue),
      'hsl': hsl
          .map((band) => <double>[band.hue, band.saturation, band.luminance])
          .toList(),
      'colorGrading': colorGrading.toJson(),
      'masks': masks.map((m) => m.toJson()).toList(),
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

    final parsedMasks = <SelectiveMask>[];
    final rawMasks = json['masks'];
    if (rawMasks is List) {
      for (final item in rawMasks) {
        final parsed = SelectiveMask.tryParse(item);
        if (parsed != null) parsedMasks.add(parsed);
      }
    }

    double numOr(Object? v, double fallback, double min, double max) =>
        v is num ? v.toDouble().clamp(min, max) : fallback;

    return PhotoEdit(
      exposure: _exposure(json['exposure']),
      contrast: _signed(json['contrast']),
      highlights: _signed(json['highlights']),
      shadows: _signed(json['shadows']),
      whites: _signed(json['whites']),
      blacks: _signed(json['blacks']),
      temperature: _signed(json['temperature']),
      tint: _signed(json['tint']),
      vibrance: _signed(json['vibrance']),
      saturation: _signed(json['saturation']),
      blackAndWhite: json['blackAndWhite'] == true,
      clarity: _signed(json['clarity']),
      texture: _signed(json['texture']),
      dehaze: _signed(json['dehaze']),
      fade: _positive(json['fade']),
      grain: _positive(json['grain']),
      grainSize: numOr(json['grainSize'], 0.25, 0.0, 1.0),
      grainRoughness: numOr(json['grainRoughness'], 0.5, 0.0, 1.0),
      vignette: _positive(json['vignette']),
      vignetteMidpoint: numOr(json['vignetteMidpoint'], 0.5, 0.0, 1.0),
      vignetteFeather: numOr(json['vignetteFeather'], 0.5, 0.0, 1.0),
      vignetteRoundness: _signed(json['vignetteRoundness']),
      sharpen: _positive(json['sharpen']),
      sharpenRadius: numOr(json['sharpenRadius'], 0.35, 0.0, 1.0),
      noiseReduction: _positive(json['noiseReduction']),
      colorNoiseReduction: _positive(json['colorNoiseReduction']),
      lensDistortion: _signed(json['lensDistortion']),
      opticsVignette: _positive(json['opticsVignette']),
      defringe: _positive(json['defringe']),
      cropAspect: json['cropAspect'] is String
          ? json['cropAspect'] as String
          : 'original',
      rotateQuarterTurns:
          json['rotateQuarterTurns'] is num
              ? ((json['rotateQuarterTurns'] as num).toInt() % 4 + 4) % 4
              : 0,
      flipHorizontal: json['flipHorizontal'] == true,
      flipVertical: json['flipVertical'] == true,
      straightenDegrees: numOr(json['straightenDegrees'], 0.0, -45.0, 45.0),
      verticalPerspective: _signed(json['verticalPerspective']),
      horizontalPerspective: _signed(json['horizontalPerspective']),
      blurAmount: _positive(json['blurAmount']),
      blurStyle: json['blurStyle'] == 'linear' ? 'linear' : 'radial',
      blurCenterX: numOr(json['blurCenterX'], 0.5, 0.0, 1.0),
      blurCenterY: numOr(json['blurCenterY'], 0.5, 0.0, 1.0),
      blurRadius: numOr(json['blurRadius'], 0.32, 0.05, 0.9),
      blurFeather: numOr(json['blurFeather'], 0.45, 0.05, 1.0),
      blurBokehBoost: numOr(json['blurBokehBoost'], 0.25, 0.0, 1.0),
      curveRgb: parseCurve(json['curveRgb']),
      curveRed: parseCurve(json['curveRed']),
      curveGreen: parseCurve(json['curveGreen']),
      curveBlue: parseCurve(json['curveBlue']),
      hsl: parsedHsl.length == defaultHslBands.length
          ? parsedHsl
          : defaultHslBands,
      colorGrading: ColorGrading.fromJson(json['colorGrading']),
      masks: parsedMasks,
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

/// Saved full Lightroom-style edit preset (sliders + curves + HSL + grading +
/// optional film tone).
class SavedEditPreset {
  final String id;
  final String name;
  final PhotoEdit edit;
  final String toneId;
  final double toneIntensity;
  final bool stockEffects;

  const SavedEditPreset({
    required this.id,
    required this.name,
    required this.edit,
    this.toneId = 'standard',
    this.toneIntensity = 1.0,
    this.stockEffects = true,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'edit': edit.toJson(),
        'toneId': toneId,
        'toneIntensity': toneIntensity,
        'stockEffects': stockEffects,
      };

  static SavedEditPreset? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String || id.isEmpty || name.isEmpty) {
      return null;
    }
    final rawEdit = raw['edit'];
    final editMap = rawEdit is Map
        ? rawEdit.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};
    return SavedEditPreset(
      id: id,
      name: name,
      edit: PhotoEdit.fromJson(editMap),
      toneId: raw['toneId'] is String ? raw['toneId'] as String : 'standard',
      toneIntensity: raw['toneIntensity'] is num
          ? (raw['toneIntensity'] as num).toDouble().clamp(0.0, 1.0)
          : 1.0,
      stockEffects: raw['stockEffects'] != false,
    );
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

  static String straighten(double value) {
    final sign = value > 0.05 ? '+' : '';
    return '$sign${value.toStringAsFixed(1)}°';
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
