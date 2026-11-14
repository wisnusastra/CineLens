// lib/features/cinema_camera/domain/entities/cinema_tone.dart

class CinemaTone {
  final String id;
  final String name;
  final String description;
  final List<double> matrix;

  const CinemaTone({
    required this.id,
    required this.name,
    this.description = '',
    required this.matrix,
  });

  bool get isValidMatrix => matrix.length == 20;
}
