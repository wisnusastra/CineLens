import 'package:cinelens_ios/features/cinema_camera/domain/services/cube_lut.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 2×2×2 `.cube` whose data is a perfect identity transform.
///
/// `.cube` stores red fastest, so the order below is b-major, then g, then r.
const _identityCube = '''
# CineLens test cube
TITLE "Identity 2"
LUT_3D_SIZE 2
0 0 0
1 0 0
0 1 0
1 1 0
0 0 1
1 0 1
0 1 1
1 1 1
''';

void main() {
  group('parseCubeLut', () {
    test('reads size, title and every triple', () {
      final lut = parseCubeLut(_identityCube);

      expect(lut.size, 2);
      expect(lut.title, 'Identity 2');
      expect(lut.entryCount, 8);
      expect(lut.rgb.length, 24);
      expect(lut.rgb[3], 1.0); // second entry, red channel
    });

    test('converts to opaque RGBA float data for Core Image', () {
      final lut = parseCubeLut(_identityCube);
      final rgba = lut.toRgbaCube();

      expect(rgba.length, lut.entryCount * 4);
      expect(rgba[3], 1.0);
      expect(rgba[7], 1.0);
    });

    test('rejects a 1D LUT instead of rendering it flat', () {
      expect(
        () => parseCubeLut('LUT_1D_SIZE 16\n0 0 0\n'),
        throwsA(isA<CubeLutFormatException>()),
      );
    });

    test('rejects an incomplete cube', () {
      expect(
        () => parseCubeLut('LUT_3D_SIZE 2\n0 0 0\n1 0 0\n'),
        throwsA(isA<CubeLutFormatException>()),
      );
    });

    test('rejects a missing LUT_3D_SIZE header', () {
      expect(
        () => parseCubeLut('0 0 0\n1 0 0\n'),
        throwsA(isA<CubeLutFormatException>()),
      );
    });
  });

  group('fitCubeToMatrix', () {
    test('an identity cube fits an identity matrix', () {
      final matrix = fitCubeToMatrix(parseCubeLut(_identityCube));

      expect(matrix.length, 20);
      expect(matrix[0], closeTo(1.0, 1e-6));
      expect(matrix[6], closeTo(1.0, 1e-6));
      expect(matrix[12], closeTo(1.0, 1e-6));
      expect(matrix[4], closeTo(0.0, 1e-6));
      expect(matrix[9], closeTo(0.0, 1e-6));
      expect(matrix[14], closeTo(0.0, 1e-6));
      expect(matrix[18], 1.0);
    });
  });
}
