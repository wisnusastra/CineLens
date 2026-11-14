import 'package:cinelens_ios/features/cinema_camera/domain/entities/cinema_tone.dart';
import 'package:cinelens_ios/features/cinema_camera/domain/services/color_matrix_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ColorMatrixBuilder.build', () {
    test('always returns 20 coefficients', () {
      expect(ColorMatrixBuilder.build(const CustomGradeParameters()).length, 20);
    });

    test('neutral parameters produce the identity matrix', () {
      final matrix = ColorMatrixBuilder.build(const CustomGradeParameters());

      for (var i = 0; i < 20; i++) {
        expect(matrix[i], closeTo(CinemaTone.identityMatrix[i], 1e-9));
      }
    });

    test('contrast below 1 keeps the row sum non-negative', () {
      const params = CustomGradeParameters(contrast: 0.8);
      final matrix = ColorMatrixBuilder.build(params);

      expect(matrix[0] + matrix[1] + matrix[2], closeTo(0.8, 1e-9));
      expect(matrix[4], closeTo(128.0 * (1.0 - 0.8), 1e-9));
    });

    test('saturation 0 collapses every row to the luma row', () {
      const params = CustomGradeParameters(saturation: 0);
      final matrix = ColorMatrixBuilder.build(params);

      expect(matrix[0], closeTo(matrix[5], 1e-9));
      expect(matrix[0], closeTo(matrix[10], 1e-9));
      expect(matrix[0], closeTo(0.2126, 1e-9));
    });

    test('exposure doubles the gain per stop', () {
      final oneStop = ColorMatrixBuilder.build(const CustomGradeParameters(exposure: 1));
      final twoStops = ColorMatrixBuilder.build(const CustomGradeParameters(exposure: 2));

      expect(oneStop[0], closeTo(2.0, 1e-9));
      expect(twoStops[0], closeTo(4.0, 1e-9));
    });
  });
}
