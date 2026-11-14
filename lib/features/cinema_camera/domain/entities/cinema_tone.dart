import 'package:flutter/material.dart';

class CinemaTone {
  final String id;
  final String name;
  final String filmReference;
  final String description;
  final int accentColorHex;
  final List<double> matrix;
  final bool isCustom;

  const CinemaTone({
    required this.id,
    required this.name,
    required this.filmReference,
    required this.description,
    required this.accentColorHex,
    required this.matrix,
    this.isCustom = false,
  }); 

  static const List<double> identityMatrix = <double>[
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  List<double> blendedMatrix(double intensity) {
    final clamped = intensity.clamp(0.0, 1.0);
    if (clamped == 0.0) return identityMatrix;
    if (clamped == 1.0) return matrix;

    return List<double>.generate(20, (i) {
      return identityMatrix[i] + (matrix[i] - identityMatrix[i]) * clamped;
    });
  }

  Color get accentColor => Color(accentColorHex);

  CinemaTone copyWith({
    String? id,
    String? name,
    String? filmReference,
    String? description,
    int? accentColorHex,
    List<double>? matrix,
    bool? isCustom,
  }) {
    return CinemaTone(
      id: id ?? this.id,
      name: name ?? this.name,
      filmReference: filmReference ?? this.filmReference,
      description: description ?? this.description,
      accentColorHex: accentColorHex ?? this.accentColorHex,
      matrix: matrix ?? this.matrix,
      isCustom: isCustom ?? this.isCustom,
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
      };

  factory CinemaTone.fromJson(Map<String, dynamic> json) {
    return CinemaTone(
      id: json['id'] as String,
      name: json['name'] as String,
      filmReference: json['filmReference'] as String,
      description: json['description'] as String,
      accentColorHex: json['accentColorHex'] as int,
      matrix: (json['matrix'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
      isCustom: (json['isCustom'] as bool?) ?? false,
    );
  }
}
