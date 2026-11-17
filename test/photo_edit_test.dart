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
    });
  });
}
