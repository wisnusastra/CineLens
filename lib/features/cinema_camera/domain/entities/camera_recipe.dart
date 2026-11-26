import 'dart:convert';

import 'frame_format.dart';

/// User-customizable Fujifilm-style quick camera recipe (`C1` – `C4`).
///
/// Tap a slot to instantly recall the entire look & capture setup; long-press
/// any slot to overwrite it with your current camera configuration.
class CameraRecipe {
  final int slot; // 1..4
  final String name;
  final bool isVideo;
  final String toneId;
  final double intensity;
  final String frameFormatName;
  final String resolutionName;
  final int fps;
  final bool processZero;
  final bool nightStack;
  final bool hiRes48MP;
  final bool heif10Bit;
  final bool highlightMetering;

  const CameraRecipe({
    required this.slot,
    required this.name,
    required this.isVideo,
    required this.toneId,
    this.intensity = 1.0,
    this.frameFormatName = 'full',
    this.resolutionName = 'maxSensor',
    this.fps = 24,
    this.processZero = false,
    this.nightStack = false,
    this.hiRes48MP = false,
    this.heif10Bit = false,
    this.highlightMetering = false,
  });

  String get slotCode => 'C$slot';

  CameraFrameFormat get frameFormat => CameraFrameFormat.fromName(frameFormatName);

  CameraRecipe copyWith({
    String? name,
    bool? isVideo,
    String? toneId,
    double? intensity,
    String? frameFormatName,
    String? resolutionName,
    int? fps,
    bool? processZero,
    bool? nightStack,
    bool? hiRes48MP,
    bool? heif10Bit,
    bool? highlightMetering,
  }) {
    return CameraRecipe(
      slot: slot,
      name: name ?? this.name,
      isVideo: isVideo ?? this.isVideo,
      toneId: toneId ?? this.toneId,
      intensity: intensity ?? this.intensity,
      frameFormatName: frameFormatName ?? this.frameFormatName,
      resolutionName: resolutionName ?? this.resolutionName,
      fps: fps ?? this.fps,
      processZero: processZero ?? this.processZero,
      nightStack: nightStack ?? this.nightStack,
      hiRes48MP: hiRes48MP ?? this.hiRes48MP,
      heif10Bit: heif10Bit ?? this.heif10Bit,
      highlightMetering: highlightMetering ?? this.highlightMetering,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'slot': slot,
        'name': name,
        'isVideo': isVideo,
        'toneId': toneId,
        'intensity': intensity,
        'frameFormatName': frameFormatName,
        'resolutionName': resolutionName,
        'fps': fps,
        'processZero': processZero,
        'nightStack': nightStack,
        'hiRes48MP': hiRes48MP,
        'heif10Bit': heif10Bit,
        'highlightMetering': highlightMetering,
      };

  static CameraRecipe? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final slot = (raw['slot'] as num?)?.toInt();
    final toneId = raw['toneId'] as String?;
    if (slot == null || slot < 1 || slot > 4 || toneId == null) return null;
    return CameraRecipe(
      slot: slot,
      name: (raw['name'] as String?)?.trim().isNotEmpty == true
          ? (raw['name'] as String).trim()
          : 'C$slot',
      isVideo: raw['isVideo'] == true,
      toneId: toneId,
      intensity: ((raw['intensity'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
      frameFormatName: (raw['frameFormatName'] as String?) ?? 'full',
      resolutionName: (raw['resolutionName'] as String?) ?? 'maxSensor',
      fps: (raw['fps'] as num?)?.toInt() ?? 24,
      processZero: raw['processZero'] == true,
      nightStack: raw['nightStack'] == true,
      hiRes48MP: raw['hiRes48MP'] == true,
      heif10Bit: raw['heif10Bit'] == true,
      highlightMetering: raw['highlightMetering'] == true,
    );
  }

  /// Four curated starter recipes showcasing CineLens's cool, teal-orange,
  /// street monochrome, and 24fps cinema video pipelines.
  static const List<CameraRecipe> defaults = <CameraRecipe>[
    CameraRecipe(
      slot: 1,
      name: 'TEAL NIGHT',
      isVideo: false,
      toneId: 'metro_teal',
      intensity: 1.0,
      frameFormatName: 'ratio32',
      resolutionName: 'maxSensor',
      processZero: true,
      nightStack: true,
      heif10Bit: true,
      highlightMetering: true,
    ),
    CameraRecipe(
      slot: 2,
      name: 'BLUE HOUR',
      isVideo: false,
      toneId: 'rooftop_cyan',
      intensity: 1.0,
      frameFormatName: 'ratio32',
      resolutionName: 'maxSensor',
      processZero: true,
      heif10Bit: true,
    ),
    CameraRecipe(
      slot: 3,
      name: 'STREET B&W',
      isVideo: false,
      toneId: 'leica_chiaroscuro',
      intensity: 1.0,
      frameFormatName: 'ratio32',
      resolutionName: 'maxSensor',
      processZero: true,
      highlightMetering: true,
    ),
    CameraRecipe(
      slot: 4,
      name: 'CINE 24P',
      isVideo: true,
      toneId: 'teal_orange',
      intensity: 1.0,
      frameFormatName: 'full',
      resolutionName: 'uhd4K',
      fps: 24,
    ),
  ];

  static List<CameraRecipe> decodeList(String? rawJson) {
    final map = <int, CameraRecipe>{
      for (final d in defaults) d.slot: d,
    };
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final parsed = jsonDecode(rawJson);
        if (parsed is List) {
          for (final item in parsed) {
            final r = tryParse(item);
            if (r != null) map[r.slot] = r;
          }
        }
      } catch (_) {}
    }
    return [for (var i = 1; i <= 4; i++) map[i]!];
  }

  static String encodeList(List<CameraRecipe> recipes) {
    return jsonEncode(recipes.map((r) => r.toJson()).toList());
  }
}
