import '../../domain/entities/cinema_tone.dart';

class CinemaTonesPresetSource {
  const CinemaTonesPresetSource();

  List<CinemaTone> getHollywoodTones() {
    return const [
      CinemaTone(
        id: 'standard_709',
        name: 'REC.709 RAW',
        filmReference: 'Natural Sensor',
        description: 'Warna natural standar tanpa gradasi tambahan.',
        accentColorHex: 0xFFE5E5EA,
        matrix: CinemaTone.identityMatrix,
      ),
      CinemaTone(
        id: 'teal_orange',
        name: 'TEAL & ORANGE',
        filmReference: 'Blockbuster Action',
        description: 'Kontras tinggi dengan kulit hangat keemasan dan bayangan cyan.',
        accentColorHex: 0xFFFF8C42,
        matrix: [
          1.22, -0.08, -0.06, 0, 8,
          -0.04, 1.04, 0.06, 0, 2,
          -0.12, 0.14, 1.18, 0, 12,
          0, 0, 0, 1, 0,
        ],
      ),
      CinemaTone(
        id: 'kodak_500t',
        name: 'VISION3 500T',
        filmReference: '35mm Tungsten Film',
        description: 'Highlight amber lembut dengan shadow gelap kehijauan khas seluloid.',
        accentColorHex: 0xFFE5A93B,
        matrix: [
          1.14, 0.05, -0.05, 0, 6,
          0.02, 1.08, 0.03, 0, 4,
          -0.06, 0.08, 0.94, 0, 8,
          0, 0, 0, 1, 0,
        ],
      ),
      CinemaTone(
        id: 'neo_noir',
        name: 'NEO-NOIR 2049',
        filmReference: 'Cyberpunk Dusk',
        description: 'Nuansa malam futuristik dominan biru elektrik dan aksen magenta.',
        accentColorHex: 0xFF38BDF8,
        matrix: [
          0.95, -0.05, 0.15, 0, -4,
          -0.05, 0.98, 0.12, 0, 0,
          0.12, 0.16, 1.28, 0, 14,
          0, 0, 0, 1, 0,
        ],
      ),
      CinemaTone(
        id: 'cold_steel',
        name: 'COLD STEEL',
        filmReference: 'Sci-Fi Anamorphic',
        description: 'Desaturasi dingin dengan kontras tajam ala film fiksi ilmiah.',
        accentColorHex: 0xFF94A3B8,
        matrix: [
          0.88, 0.06, 0.06, 0, -6,
          0.04, 0.94, 0.08, 0, -2,
          0.08, 0.10, 1.12, 0, 10,
          0, 0, 0, 1, 0,
        ],
      ),
      CinemaTone(
        id: 'bleach_ochre',
        name: 'DESERT OCHRE',
        filmReference: 'Bleach Bypass 35mm',
        description: 'Cahaya matahari gurun keemasan dengan kontras perak tinggi.',
        accentColorHex: 0xFFD97706,
        matrix: [
          1.26, 0.08, -0.10, 0, 10,
          0.06, 1.12, -0.06, 0, 5,
          -0.10, -0.04, 0.78, 0, -4,
          0, 0, 0, 1, 0,
        ],
      ),
      CinemaTone(
        id: 'silver_noir',
        name: 'SILVER NOIR',
        filmReference: 'Panchromatic B&W',
        description: 'Hitam putih kontras tinggi terinspirasi film klasik Hollywood.',
        accentColorHex: 0xFFA1A1AA,
        matrix: [
          0.36, 0.58, 0.14, 0, -8,
          0.36, 0.58, 0.14, 0, -8,
          0.36, 0.58, 0.14, 0, -8,
          0, 0, 0, 1, 0,
        ],
      ),
    ];
  }
}
