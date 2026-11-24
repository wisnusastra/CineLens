import 'package:cinelens_ios/features/photo_editor/domain/entities/photo_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PhotoEdit', () {
    test('neutral values report as neutral and clamp out of range', () {
      expect(PhotoEdit.neutral.isNeutral, isTrue);

      final edit = PhotoEdit.neutral.copyWith(
        exposure: 9,
        contrast: -9,
        fade: 4,
      );
      expect(edit.exposure, 2.0);
      expect(edit.contrast, -1.0);
      expect(edit.fade, 1.0);
      expect(edit.isNeutral, isFalse);
    });

    test('curve points are sorted, deduplicated and identity is dropped', () {
      final identity = PhotoEdit.neutral.withCurve(
        EditCurveChannel.rgb,
        const <CurvePoint>[
          CurvePoint(1, 1),
          CurvePoint(0, 0),
        ],
      );
      expect(identity.curveRgb, isEmpty);

      final shaped = PhotoEdit.neutral.withCurve(
        EditCurveChannel.red,
        const <CurvePoint>[
          CurvePoint(0.8, 0.9),
          CurvePoint(0, 0),
          CurvePoint(0.5, 0.62),
          CurvePoint(0.501, 0.99),
          CurvePoint(1, 1),
        ],
      );
      expect(shaped.curveRed.length, 4);
      expect(shaped.curveRed[1].x, lessThan(shaped.curveRed[2].x));
      expect(shaped.curveFor(EditCurveChannel.red), shaped.curveRed);
    });

    test('HSL bands update by index and survive JSON round-trip', () {
      final band = PhotoEdit.defaultHslBands[1].copyWith(
        hue: 0.4,
        saturation: -0.25,
        luminance: 0.1,
      );
      final edit = PhotoEdit.neutral
          .copyWith(exposure: 0.75, saturation: -0.3, grain: 0.2)
          .withHslBand(1, band);

      final restored = PhotoEdit.fromJson(edit.toJson());

      expect(restored.exposure, 0.75);
      expect(restored.saturation, -0.3);
      expect(restored.grain, 0.2);
      expect(restored.hsl.length, 8);
      expect(restored.hsl[1].hue, 0.4);
      expect(restored.hsl[1].saturation, -0.25);
      expect(restored.hsl[1].luminance, 0.1);
      expect(restored.hsl[0].isNeutral, isTrue);
    });

    test('native payload keeps every slider and curve', () {
      final edit = PhotoEdit.neutral.copyWith(
        exposure: -0.4,
        temperature: 0.2,
        sharpen: 0.3,
      ).withCurve(
        EditCurveChannel.rgb,
        const <CurvePoint>[
          CurvePoint(0, 0.05),
          CurvePoint(0.5, 0.55),
          CurvePoint(1, 0.95),
        ],
      );

      final payload = edit.toParameters();
      expect(payload['exposure'], -0.4);
      expect(payload['temperature'], 0.2);
      expect(payload['sharpen'], 0.3);
      expect(payload['curveRgb'], hasLength(3));
      final hsl = payload['hsl'] as List<List<double>>;
      expect(hsl, hasLength(8));
      expect(hsl.first, <double>[0, 0, 0]);
    });

    test('fromJson tolerates missing and malformed fields', () {
      final restored = PhotoEdit.fromJson(<String, dynamic>{
        'exposure': 'not a number',
        'saturation': 5,
        'hsl': <dynamic>[
          <double>[0.5, 0, 0],
          'broken',
        ],
      });

      expect(restored.exposure, 0);
      expect(restored.saturation, 1.0);
      expect(restored.hsl.length, 8);
      expect(restored.hsl.first.hue, 0.5);
      expect(restored.hsl[1].isNeutral, isTrue);
    });
  });

  group('sampleCurve', () {
    test('interpolates linearly between points', () {
      const points = <CurvePoint>[
        CurvePoint(0, 0),
        CurvePoint(0.5, 0.75),
        CurvePoint(1, 1),
      ];

      expect(sampleCurve(points, 0.25), closeTo(0.375, 0.0001));
      expect(sampleCurve(points, 0.5), closeTo(0.75, 0.0001));
      expect(sampleCurve(points, 1.5), 1);
      expect(sampleCurve(points, -1), 0);
    });

    test('an empty curve is the identity line', () {
      expect(sampleCurve(const <CurvePoint>[], 0.3), 0.3);
    });
  });

  group('EditValueFormat', () {
    test('formats exposure and signed values the way the panel shows them', () {
      expect(EditValueFormat.exposure(0.5), '+0.5 EV');
      expect(EditValueFormat.exposure(-0.3), '-0.3 EV');
      expect(EditValueFormat.signed(0.2), '+20');
      expect(EditValueFormat.signed(-0.15), '-15');
      expect(EditValueFormat.percent(0.42), '42');
      expect(EditValueFormat.degrees(-0.5), '-30°');
      expect(EditValueFormat.straighten(3.5), '+3.5°');
      expect(EditValueFormat.straighten(-2.0), '-2.0°');
    });
  });

  group('Lightroom Pro Editor features (v2.1)', () {
    test('3-way ColorGrading, Optics, Crop/Geometry, Blur & B&W round-trip JSON', () {
      const grading = ColorGrading(
        shadows: ColorWheelGrade(hue: 215, saturation: 0.45, luminance: -0.15),
        midtones: ColorWheelGrade(hue: 40, saturation: 0.2, luminance: 0.05),
        highlights: ColorWheelGrade(hue: 35, saturation: 0.35, luminance: 0.1),
        blending: 0.65,
        balance: -0.2,
      );
      const mask = SelectiveMask(
        id: 'mask_1',
        name: 'Langit',
        type: 'linear',
        startX: 0.5,
        startY: 0.1,
        endX: 0.5,
        endY: 0.5,
        feather: 0.6,
        inverted: true,
        exposure: -0.6,
        temperature: -0.2,
        clarity: 0.25,
      );
      final edit = PhotoEdit.neutral.copyWith(
        blackAndWhite: true,
        colorGrading: grading,
        vignette: 0.4,
        vignetteMidpoint: 0.35,
        vignetteFeather: 0.7,
        vignetteRoundness: -0.3,
        grain: 0.25,
        grainSize: 0.4,
        grainRoughness: 0.65,
        sharpen: 0.3,
        sharpenRadius: 0.5,
        colorNoiseReduction: 0.35,
        lensDistortion: -0.25,
        opticsVignette: 0.3,
        defringe: 0.45,
        cropAspect: '4:5',
        rotateQuarterTurns: 1,
        flipHorizontal: true,
        straightenDegrees: 2.5,
        verticalPerspective: -0.3,
        horizontalPerspective: 0.15,
        blurAmount: 0.55,
        blurStyle: 'linear',
        blurCenterX: 0.4,
        blurCenterY: 0.6,
        blurRadius: 0.35,
        blurFeather: 0.5,
        blurBokehBoost: 0.6,
        masks: const <SelectiveMask>[mask],
      );

      expect(edit.isNeutral, isFalse);
      expect(edit.hasGeometryChanges, isTrue);

      final restored = PhotoEdit.fromJson(edit.toJson());
      expect(restored.blackAndWhite, isTrue);
      expect(restored.colorGrading.shadows.hue, closeTo(215, 0.01));
      expect(restored.colorGrading.shadows.saturation, closeTo(0.45, 0.01));
      expect(restored.colorGrading.balance, closeTo(-0.2, 0.01));
      expect(restored.vignetteMidpoint, closeTo(0.35, 0.01));
      expect(restored.colorNoiseReduction, closeTo(0.35, 0.01));
      expect(restored.lensDistortion, closeTo(-0.25, 0.01));
      expect(restored.defringe, closeTo(0.45, 0.01));
      expect(restored.cropAspect, '4:5');
      expect(restored.rotateQuarterTurns, 1);
      expect(restored.flipHorizontal, isTrue);
      expect(restored.straightenDegrees, closeTo(2.5, 0.01));
      expect(restored.verticalPerspective, closeTo(-0.3, 0.01));
      expect(restored.blurAmount, closeTo(0.55, 0.01));
      expect(restored.blurStyle, 'linear');
      expect(restored.masks, hasLength(1));
      expect(restored.masks.first.isLinear, isTrue);
      expect(restored.masks.first.inverted, isTrue);
      expect(restored.masks.first.exposure, closeTo(-0.6, 0.01));
    });

    test('SavedEditPreset serialises and parses cleanly', () {
      final preset = SavedEditPreset(
        id: 'p_1',
        name: 'Leica Street',
        edit: PhotoEdit.neutral.copyWith(contrast: 0.25, blacks: -0.2),
        toneId: 'leica_chiaroscuro',
        toneIntensity: 0.85,
        stockEffects: false,
      );
      final restored = SavedEditPreset.tryParse(preset.toJson());
      expect(restored, isNotNull);
      expect(restored!.name, 'Leica Street');
      expect(restored.toneId, 'leica_chiaroscuro');
      expect(restored.toneIntensity, closeTo(0.85, 0.01));
      expect(restored.stockEffects, isFalse);
      expect(restored.edit.contrast, closeTo(0.25, 0.01));
    });

    test('v2.2 OpenFilm Multi-Log IDT, ASC CDL, Video Trim & -14 LUFS round-trip', () {
      final edit = PhotoEdit.neutral.copyWith(
        inputLogProfile: 'sony_slog3',
        cdlSlope: const <double>[1.12, 1.0, 0.94],
        cdlOffset: const <double>[0.02, 0.0, -0.03],
        cdlPower: const <double>[1.05, 1.0, 0.96],
        cdlSaturation: 1.15,
        cropAspect: '65:24',
        trimStart: 0.15,
        trimEnd: 0.85,
        normalizeAudio: true,
      );

      expect(edit.isNeutral, isFalse);
      expect(edit.hasCdlChanges, isTrue);
      expect(edit.hasTrimChanges, isTrue);

      final restored = PhotoEdit.fromJson(edit.toJson());
      expect(restored.inputLogProfile, 'sony_slog3');
      expect(restored.cdlSlope[0], closeTo(1.12, 0.001));
      expect(restored.cdlOffset[2], closeTo(-0.03, 0.001));
      expect(restored.cdlPower[0], closeTo(1.05, 0.001));
      expect(restored.cdlSaturation, closeTo(1.15, 0.001));
      expect(restored.cropAspect, '65:24');
      expect(restored.trimStart, closeTo(0.15, 0.001));
      expect(restored.trimEnd, closeTo(0.85, 0.001));
      expect(restored.normalizeAudio, isTrue);
    });
  });
}
