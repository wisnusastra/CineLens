import 'dart:convert';
import '../../../../core/constants/app_constants.dart';
import 'cinema_tone.dart';

class CinemaTonePresetPackage {
  final String app;
  final int schemaVersion;
  final DateTime exportedAt;
  final List<CinemaTone> presets;

  const CinemaTonePresetPackage({
    this.app = AppConstants.appName,
    this.schemaVersion = AppConstants.presetJsonSchemaVersion,
    required this.exportedAt,
    required this.presets,
  });

  String toPrettyJson() {
    final map = <String, dynamic>{
      'app': app,
      'schemaVersion': schemaVersion,
      'exportedAt': exportedAt.toUtc().toIso8601String(),
      'presets': presets.map((t) => t.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  static List<CinemaTone> parseAndValidateTones(String rawJson) {
    final trimmed = rawJson.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Konten JSON kosong.');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const FormatException(
        'Format JSON tidak valid. Pastikan tanda kurung dan kutip sudah benar.',
      );
    }

    final List<dynamic> rawItems;
    if (decoded is Map<String, dynamic>) {
      if (decoded.containsKey('presets') && decoded['presets'] is List) {
        rawItems = decoded['presets'] as List<dynamic>;
      } else if (decoded.containsKey('matrix')) {
        rawItems = [decoded];
      } else {
        throw const FormatException(
          'Struktur JSON tidak dikenali. Tidak ditemukan daftar "presets" atau "matrix".',
        );
      }
    } else if (decoded is List<dynamic>) {
      rawItems = decoded;
    } else {
      throw const FormatException('Root JSON harus berupa objek atau array.');
    }

    if (rawItems.isEmpty) {
      throw const FormatException('Tidak ada data preset di dalam file JSON.');
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final validatedTones = <CinemaTone>[];

    for (int i = 0; i < rawItems.length; i++) {
      final item = rawItems[i];
      if (item is! Map<String, dynamic>) {
        throw FormatException('Item preset ke-${i + 1} bukan objek JSON valid.');
      }

      final rawName = (item['name'] as String?)?.trim() ?? '';
      if (rawName.isEmpty) {
        throw FormatException('Preset ke-${i + 1} tidak memiliki nama ("name").');
      }

      final rawMatrix = item['matrix'];
      if (rawMatrix is! List || rawMatrix.length != 20) {
        throw FormatException(
          'Preset "$rawName" harus memiliki tepat 20 angka pada "matrix" warna.',
        );
      }

      final parsedMatrix = <double>[];
      for (final value in rawMatrix) {
        if (value is! num || !value.isFinite) {
          throw FormatException(
            'Matriks warna pada preset "$rawName" mengandung nilai non-numerik.',
          );
        }
        parsedMatrix.add(value.toDouble());
      }

      final accentHex = item['accentColorHex'] is int
          ? item['accentColorHex'] as int
          : 0xFFE5A93B;

      validatedTones.add(
        CinemaTone(
          id: 'imported_${timestamp}_$i',
          name: rawName.toUpperCase(),
          filmReference:
              (item['filmReference'] as String?)?.trim().isNotEmpty == true
                  ? (item['filmReference'] as String).trim()
                  : 'Imported LUT',
          description:
              (item['description'] as String?)?.trim().isNotEmpty == true
                  ? (item['description'] as String).trim()
                  : 'Preset LUT sinematik hasil impor JSON.',
          accentColorHex: accentHex,
          matrix: parsedMatrix,
          isCustom: true,
        ),
      );
    }

    return validatedTones;
  }
}
