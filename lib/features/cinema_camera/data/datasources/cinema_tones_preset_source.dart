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
          1.183, 0.017, -0.023, 0.0, -29.9,
          -0.041, 1.145, -0.03, 0.0, -19.3,
          -0.04, -0.059, 1.124, 0.0, -12.1,
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
          1.257, 0.002, -0.049, 0.0, -34.4,
          -0.079, 1.171, -0.007, 0.0, -19.0,
          -0.158, -0.101, 1.154, 0.0, 5.2,
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
          1.279, -0.126, -0.039, 0.0, -26.1,
          -0.088, 1.297, -0.085, 0.0, -32.4,
          -0.062, -0.175, 1.287, 0.0, -16.7,
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
          0.486, 0.673, 0.203, 0.0, -38.5,
          0.486, 0.673, 0.203, 0.0, -38.5,
          0.486, 0.673, 0.203, 0.0, -38.5,
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
          0.693, 0.13, 0.014, 0.0, 21.2,
          0.035, 0.779, 0.012, 0.0, 22.0,
          0.043, 0.135, 0.665, 0.0, 20.4,
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
          1.216, -0.053, -0.044, 0.0, -11.1,
          -0.019, 1.179, -0.037, 0.0, -16.5,
          -0.107, -0.062, 1.179, 0.0, -15.6,
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
          0.811, 0.24, -0.062, 0.0, 8.1,
          0.084, 0.896, -0.042, 0.0, 11.9,
          0.019, 0.258, 0.692, 0.0, -0.6,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
    ];
  }
}
