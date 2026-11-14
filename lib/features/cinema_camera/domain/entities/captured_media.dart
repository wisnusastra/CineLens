// lib/features/cinema_camera/domain/entities/captured_media.dart

enum CapturedMediaType { photo, video }

/// One entry of the in-app gallery.
///
/// Every capture is copied into the app documents directory, so the gallery
/// keeps working even when the user denied access to Apple Photos.
class CapturedMedia {
  final String id;
  final CapturedMediaType type;
  final String path;
  final DateTime createdAt;
  final String toneId;
  final String toneName;
  final double intensity;
  final bool isAnamorphic;

  const CapturedMedia({
    required this.id,
    required this.type,
    required this.path,
    required this.createdAt,
    required this.toneId,
    required this.toneName,
    required this.intensity,
    required this.isAnamorphic,
  });

  bool get isVideo => type == CapturedMediaType.video;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'type': type.name,
      'path': path,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'toneId': toneId,
      'toneName': toneName,
      'intensity': intensity,
      'isAnamorphic': isAnamorphic,
    };
  }

  static CapturedMedia? tryParse(Map<String, dynamic> json) {
    final id = json['id'];
    final path = json['path'];
    if (id is! String || path is! String) return null;

    final type = CapturedMediaType.values.firstWhere(
      (value) => value.name == json['type'],
      orElse: () => CapturedMediaType.photo,
    );

    return CapturedMedia(
      id: id,
      type: type,
      path: path,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      toneId: json['toneId'] as String? ?? 'standard',
      toneName: json['toneName'] as String? ?? 'Standard',
      intensity: (json['intensity'] as num?)?.toDouble() ?? 1.0,
      isAnamorphic: json['isAnamorphic'] as bool? ?? false,
    );
  }
}
