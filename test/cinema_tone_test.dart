import 'package:cinelens_ios/features/cinema_camera/domain/entities/cinema_tone.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sample = CinemaTone(
    id: 'teal_orange',
    name: 'Teal & Orange',
    filmReference: 'Blockbuster Action',
    description: 'Hollywood blockbuster color separation',
    accentColorHex: 0xFF3AA6B9,
    matrix: <double>[
      1.18, 0.05, -0.08, 0.0, 8.0,
      -0.02, 1.02, 0.06, 0.0, 0.0,
      -0.06, 0.12, 1.10, 0.0, 6.0,
      0.0, 0.0, 0.0, 1.0, 0.0,
    ],
  );

  group('CinemaTone.blendedMatrix', () {
    test('returns the identity matrix at zero intensity', () {
      expect(sample.blendedMatrix(0), CinemaTone.identityMatrix);
    });

    test('returns the full LUT at full intensity', () {
      expect(sample.blendedMatrix(1), sample.matrix);
    });

    test('interpolates linearly in between', () {
      final blended = sample.blendedMatrix(0.5);
      expect(blended.length, 20);
      expect(blended[0], closeTo(1.09, 1e-9));
      expect(blended[4], closeTo(4.0, 1e-9));
    });

    test('clamps out-of-range intensity', () {
      expect(sample.blendedMatrix(-1), CinemaTone.identityMatrix);
      expect(sample.blendedMatrix(3), sample.matrix);
    });
  });

  group('CinemaTone JSON round trip', () {
    test('preserves every field', () {
      final restored = CinemaTone.fromJson(sample.toJson());

      expect(restored.id, sample.id);
      expect(restored.name, sample.name);
      expect(restored.filmReference, sample.filmReference);
      expect(restored.description, sample.description);
      expect(restored.accentColorHex, sample.accentColorHex);
      expect(restored.matrix, sample.matrix);
      expect(restored.isCustom, isFalse);
      expect(restored.accentColor, sample.accentColor);
    });

    test('falls back to the identity matrix on malformed data', () {
      final restored = CinemaTone.fromJson(<String, dynamic>{
        'id': 'broken',
        'name': 'BROKEN',
        'matrix': <double>[1, 0, 0],
      });

      expect(restored.isValidMatrix, isTrue);
      expect(restored.matrix, CinemaTone.identityMatrix);
      expect(restored.filmReference, 'Imported LUT');
    });
  });
}
