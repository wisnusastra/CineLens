// lib/features/cinema_camera/domain/services/cube_lut.dart
//
// Reads a `.cube` 3D LUT and turns it into the two things CineLens needs:
//
// * raw RGBA float cube data for Core Image (`CIColorCubeWithColorSpace`), so
//   photos and videos get the exact look the file describes, and
// * a best-fit 4×5 colour matrix, which lets the live Flutter preview show a
//   very close approximation (Flutter can only filter with a matrix).

import 'dart:typed_data';

/// A parsed `.cube` LUT.
class CubeLut {
  /// Edge length of the cube, e.g. 17, 33 or 65.
  final int size;

  /// RGB triples in `.cube` order: red changes fastest, then green, then blue.
  final Float32List rgb;

  /// Human readable name taken from `TITLE`, or null when absent.
  final String? title;

  const CubeLut({required this.size, required this.rgb, this.title});

  int get entryCount => size * size * size;

  /// Core Image wants RGBA float32 with an opaque alpha per entry.
  Float32List toRgbaCube() {
    final out = Float32List(entryCount * 4);
    for (var i = 0; i < entryCount; i++) {
      out[i * 4] = rgb[i * 3];
      out[i * 4 + 1] = rgb[i * 3 + 1];
      out[i * 4 + 2] = rgb[i * 3 + 2];
      out[i * 4 + 3] = 1.0;
    }
    return out;
  }
}

/// Thrown when a file is not a usable 3D `.cube` LUT.
class CubeLutFormatException implements Exception {
  final String message;
  const CubeLutFormatException(this.message);

  @override
  String toString() => message;
}

/// Parses the text of a `.cube` file.
///
/// 1D LUTs are rejected on purpose: they cannot be expressed as a cube and the
/// app would silently show a flat result.
CubeLut parseCubeLut(String source, {int maxSize = 65}) {
  var size = 0;
  String? title;
  final values = <double>[];

  for (final rawLine in source.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final upper = line.toUpperCase();
    if (upper.startsWith('TITLE')) {
      title = line.substring(5).trim().replaceAll('"', '');
      continue;
    }
    if (upper.startsWith('LUT_3D_SIZE')) {
      size = int.tryParse(line.split(RegExp(r'\s+')).last) ?? 0;
      continue;
    }
    if (upper.startsWith('LUT_1D_SIZE') ||
        upper.startsWith('DOMAIN_MIN') ||
        upper.startsWith('DOMAIN_MAX')) {
      // Domain is 0…1 for every LUT CineLens can render; a 1D LUT is not a
      // 3D look at all, so refuse it instead of producing a flat image.
      if (upper.startsWith('LUT_1D_SIZE')) {
        throw const CubeLutFormatException(
          'File ini LUT 1D. CineLens butuh LUT 3D (LUT_3D_SIZE).',
        );
      }
      continue;
    }

    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 3) continue;

    final r = double.tryParse(parts[0]);
    final g = double.tryParse(parts[1]);
    final b = double.tryParse(parts[2]);
    if (r == null || g == null || b == null) continue;

    values
      ..add(r.clamp(0.0, 1.0))
      ..add(g.clamp(0.0, 1.0))
      ..add(b.clamp(0.0, 1.0));
  }

  if (size < 2) {
    throw const CubeLutFormatException(
      'Baris LUT_3D_SIZE tidak ditemukan. Pastikan file .cube berisi LUT 3D.',
    );
  }
  if (size > maxSize) {
    throw CubeLutFormatException(
      'LUT terlalu besar ($size³). Maksimal $maxSize³ agar tetap cepat.',
    );
  }

  final expected = size * size * size * 3;
  if (values.length < expected) {
    throw CubeLutFormatException(
      'Data LUT tidak lengkap: ${values.length ~/ 3} dari '
      '${size * size * size} titik.',
    );
  }

  return CubeLut(
    size: size,
    rgb: Float32List.fromList(values.sublist(0, expected)),
    title: title,
  );
}

/// Fits a 4×5 colour matrix that approximates [lut], for the live preview.
///
/// The fit is a plain least-squares regression per output channel. A 3D LUT is
/// not linear, so this is an approximation by design: the native renderer uses
/// the real cube for every exported frame.
List<double> fitCubeToMatrix(CubeLut lut) {
  const unknowns = 4; // r, g, b, 1
  final normal = List<List<double>>.generate(
    unknowns,
    (_) => List<double>.filled(unknowns, 0, growable: false),
    growable: false,
  );
  final rhs = List<List<double>>.generate(
    3,
    (_) => List<double>.filled(unknowns, 0, growable: false),
    growable: false,
  );

  final count = lut.entryCount;
  // Sampling every entry of a 65³ cube would be slow on a phone; a stride
  // keeps the fit within a few thousand points and visually identical.
  final stride = count > 6000 ? (count / 6000).ceil() : 1;

  for (var i = 0; i < count; i += stride) {
    final r = lut.rgb[i * 3];
    final g = lut.rgb[i * 3 + 1];
    final b = lut.rgb[i * 3 + 2];
    final row = <double>[r, g, b, 1.0];

    for (var a = 0; a < unknowns; a++) {
      for (var c = 0; c < unknowns; c++) {
        normal[a][c] += row[a] * row[c];
      }
      rhs[0][a] += row[a] * r;
      rhs[1][a] += row[a] * g;
      rhs[2][a] += row[a] * b;
    }
  }

  final solutions = <List<double>>[
    for (var channel = 0; channel < 3; channel++) _solve(normal, rhs[channel]),
  ];

  // Identity fallback when the system is singular.
  if (solutions.any((s) => s.any((v) => v.isNaN || v.isInfinite))) {
    return const <double>[
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, 1, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  final matrix = List<double>.filled(20, 0);
  for (var channel = 0; channel < 3; channel++) {
    final s = solutions[channel];
    matrix[channel * 5] = s[0];
    matrix[channel * 5 + 1] = s[1];
    matrix[channel * 5 + 2] = s[2];
    matrix[channel * 5 + 3] = 0;
    // The app stores offsets in 0…255 so they can be fed straight into
    // Flutter's `ColorFilter.matrix`.
    matrix[channel * 5 + 4] = s[3] * 255.0;
  }
  matrix[15] = 0;
  matrix[16] = 0;
  matrix[17] = 0;
  matrix[18] = 1;
  matrix[19] = 0;
  return matrix;
}

/// Solves `A x = b` with Gaussian elimination and partial pivoting.
List<double> _solve(List<List<double>> a, List<double> b) {
  const n = 4;
  final m = List<List<double>>.generate(
    n,
    (i) => List<double>.from(a[i])..add(b[i]),
    growable: false,
  );

  for (var col = 0; col < n; col++) {
    var pivot = col;
    for (var row = col + 1; row < n; row++) {
      if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
    }
    if (m[pivot][col].abs() < 1e-12) {
      return List<double>.filled(n, double.nan);
    }
    if (pivot != col) {
      final tmp = m[pivot];
      m[pivot] = m[col];
      m[col] = tmp;
    }

    final divisor = m[col][col];
    for (var c = col; c <= n; c++) {
      m[col][c] /= divisor;
    }

    for (var row = 0; row < n; row++) {
      if (row == col) continue;
      final factor = m[row][col];
      if (factor == 0) continue;
      for (var c = col; c <= n; c++) {
        m[row][c] -= factor * m[col][c];
      }
    }
  }

  return <double>[for (var i = 0; i < n; i++) m[i][n]];
}
