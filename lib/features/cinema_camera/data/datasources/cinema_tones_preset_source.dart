// lib/features/cinema_camera/data/datasources/cinema_tones_preset_source.dart

import '../../domain/entities/cinema_tone.dart';

class CinemaTonesPresetSource {
  const CinemaTonesPresetSource();

  /// The built-in film looks shipped with CineLens.
  ///
  /// The matrices below drive the live viewfinder (a linear approximation of
  /// each film model). Photos and video exports use the full native film
  /// emulation (tone curve, crosstalk, halation, bloom, grain) keyed by [id].
  List<CinemaTone> getHollywoodTones() {
    return const [
      CinemaTone(
        id: 'standard',
        name: 'Standard',
        filmReference: 'Natural Sensor',
        description: 'Natural sensor color profile',
        accentColorHex: 0xFFB8B8C0,
        matrix: <double>[
          1.0, 0.0, 0.0, 0.0, 0.0,
          0.0, 1.0, 0.0, 0.0, 0.0,
          0.0, 0.0, 1.0, 0.0, 0.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'kodak_2383',
        name: 'Kodak 2383',
        filmReference: '35mm Print Film',
        description: 'Warm highlight roll-off & rich contrast',
        accentColorHex: 0xFFE5A93B,
        matrix: <double>[
          1.13, 0.002, -0.018, 0.0, -16.3,
          -0.025, 1.117, -0.032, 0.0, -12.0,
          -0.02, 0.017, 1.089, 0.0, -12.5,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'teal_orange',
        name: 'Teal & Orange',
        filmReference: 'Blockbuster Action',
        description: 'Hollywood blockbuster color separation',
        accentColorHex: 0xFF3AA6B9,
        matrix: <double>[
          1.216, -0.055, -0.051, 0.0, -18.6,
          -0.083, 1.16, -0.006, 0.0, -11.9,
          -0.113, -0.009, 1.143, 0.0, -2.7,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'fuji_velvia',
        name: 'Fuji Velvia',
        filmReference: 'Vivid Slide Film',
        description: 'Deep shadows & vivid landscape saturation',
        accentColorHex: 0xFF34D399,
        matrix: <double>[
          1.249, -0.126, -0.033, 0.0, -19.2,
          -0.081, 1.262, -0.069, 0.0, -26.3,
          -0.05, -0.143, 1.262, 0.0, -16.3,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'noir_bw',
        name: 'Noir B&W',
        filmReference: 'Monochrome 35mm',
        description: 'High-contrast monochrome cinema film',
        accentColorHex: 0xFFD1D1D6,
        matrix: <double>[
          0.443, 0.607, 0.19, 0.0, -10.4,
          0.443, 0.607, 0.19, 0.0, -10.4,
          0.443, 0.607, 0.19, 0.0, -10.4,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'cinelens_flat',
        name: 'CineLens Flat',
        filmReference: 'Log-like Flat Profile',
        description: 'Gamma datar gaya Log: highlight lembut & shadow terangkat',
        accentColorHex: 0xFF9AA5B1,
        matrix: <double>[
          0.786, 0.086, 0.01, 0.0, 15.4,
          0.022, 0.844, 0.008, 0.0, 16.0,
          0.03, 0.091, 0.767, 0.0, 14.6,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'golden_hour',
        name: 'Golden Hour',
        filmReference: 'Golden Sunset',
        description: 'Amber sunset warmth & soft skin tones',
        accentColorHex: 0xFFFFB14A,
        matrix: <double>[
          1.164, -0.051, -0.024, 0.0, -10.0,
          -0.016, 1.129, -0.037, 0.0, -11.7,
          -0.079, -0.028, 1.152, 0.0, -13.2,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'vintage_16mm',
        name: 'Vintage 16mm',
        filmReference: 'Analog Nostalgia',
        description: 'Faded blacks & nostalgic analog grain feel',
        accentColorHex: 0xFFD08A5E,
        matrix: <double>[
          0.843, 0.183, -0.039, 0.0, 6.0,
          0.058, 0.915, -0.022, 0.0, 8.4,
          0.029, 0.201, 0.761, 0.0, 3.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
    ];
  }
}
