import 'package:flutter/material.dart';

class CinemaTone {
  final String id;
  final String name;
  final String filmReference;
  final String description;
  final int accentColorHex;
  final List<double> matrix;
  final bool isCustom;

  /// Absolute path of the imported `.cube` payload, when this tone came from a
  /// LUT file instead of a matrix.
  ///
  /// The matrix next to it is a best-fit approximation used by the live
  /// preview; the native renderer reads this file so exports use the real look.
  final String? lutPath;

  /// Edge length of the imported cube (17, 33, 65…).
  final int? lutSize;

  const CinemaTone({
    required this.id,
    required this.name,
    required this.filmReference,
    required this.description,
    required this.accentColorHex,
    required this.matrix,
    this.isCustom = false,
    this.lutPath,
    this.lutSize,
  });

  static const List<double> identityMatrix = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  bool get isValidMatrix => matrix.length == 20;

  /// True when this tone renders from an imported `.cube` file.
  bool get isLutTone => lutPath != null && lutPath!.isNotEmpty;

  Color get accentColor => Color(accentColorHex);

  /// Interpolates between the identity matrix (0.0) and this tone's LUT (1.0).
  List<double> blendedMatrix(double intensity) {
    final clamped = intensity.clamp(0.0, 1.0);
    if (clamped == 0.0) return identityMatrix;
    if (clamped == 1.0) return matrix;

    return List<double>.generate(20, (i) {
      return identityMatrix[i] + (matrix[i] - identityMatrix[i]) * clamped;
    });
  }

  CinemaTone copyWith({
    String? id,
    String? name,
    String? filmReference,
    String? description,
    int? accentColorHex,
    List<double>? matrix,
    bool? isCustom,
    String? lutPath,
    int? lutSize,
  }) {
    return CinemaTone(
      id: id ?? this.id,
      name: name ?? this.name,
      filmReference: filmReference ?? this.filmReference,
      description: description ?? this.description,
      accentColorHex: accentColorHex ?? this.accentColorHex,
      matrix: matrix ?? this.matrix,
      isCustom: isCustom ?? this.isCustom,
      lutPath: lutPath ?? this.lutPath,
      lutSize: lutSize ?? this.lutSize,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'filmReference': filmReference,
        'description': description,
        'accentColorHex': accentColorHex,
        'matrix': matrix,
        'isCustom': isCustom,
        if (lutPath != null) 'lutPath': lutPath,
        if (lutSize != null) 'lutSize': lutSize,
      };

  factory CinemaTone.fromJson(Map<String, dynamic> json) {
    final rawMatrix = (json['matrix'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => (e as num).toDouble())
        .toList();

    return CinemaTone(
      id: json['id'] as String? ??
          'imported_${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'UNTITLED LUT',
      filmReference: json['filmReference'] as String? ?? 'Imported LUT',
      description: json['description'] as String? ?? '',
      accentColorHex: json['accentColorHex'] as int? ?? 0xFFE5A93B,
      matrix: rawMatrix.length == 20 ? rawMatrix : identityMatrix,
      isCustom: json['isCustom'] as bool? ?? false,
      lutPath: json['lutPath'] as String?,
      lutSize: (json['lutSize'] as num?)?.toInt(),
    );
  }
}
