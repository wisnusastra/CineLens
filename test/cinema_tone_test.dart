import 'package:cinelens_ios/core/l10n/app_strings.dart';
import 'package:cinelens_ios/features/cinema_camera/data/datasources/cinema_tones_preset_source.dart';
import 'package:cinelens_ios/features/cinema_camera/domain/entities/cinema_tone.dart';
import 'package:cinelens_ios/features/cinema_camera/domain/entities/film_look.dart';
import 'package:cinelens_ios/features/cinema_camera/domain/entities/frame_format.dart';
import 'package:cinelens_ios/features/cinema_camera/presentation/providers/cinema_camera_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sample = CinemaTone(
    id: 'teal_orange',
    name: 'Teal & Orange',
    filmReference: 'Blockbuster Action',
    description: 'Hollywood blockbuster color separation',
    accentColorHex: 0xFF3AA6B9,
    matrix: <double>[
      1.18, 0.05, -0.08, 0.0, 8.0,
      -0.02, 1.02, 0.06, 0.0, 0.0,
      -0.06, 0.12, 1.10, 0.0, 6.0,
      0.0, 0.0, 0.0, 1.0, 0.0,
    ],
  );

  group('CinemaTone.blendedMatrix', () {
    test('returns the identity matrix at zero intensity', () {
      expect(sample.blendedMatrix(0), CinemaTone.identityMatrix);
    });

    test('returns the full LUT at full intensity', () {
      expect(sample.blendedMatrix(1), sample.matrix);
    });

    test('interpolates linearly in between', () {
      final blended = sample.blendedMatrix(0.5);
      expect(blended.length, 20);
      expect(blended[0], closeTo(1.09, 1e-9));
      expect(blended[4], closeTo(4.0, 1e-9));
    });

    test('clamps out-of-range intensity', () {
      expect(sample.blendedMatrix(-1), CinemaTone.identityMatrix);
      expect(sample.blendedMatrix(3), sample.matrix);
    });
  });

  group('CinemaTone JSON round trip', () {
    test('preserves every field', () {
      final restored = CinemaTone.fromJson(sample.toJson());

      expect(restored.id, sample.id);
      expect(restored.name, sample.name);
      expect(restored.filmReference, sample.filmReference);
      expect(restored.description, sample.description);
      expect(restored.accentColorHex, sample.accentColorHex);
      expect(restored.matrix, sample.matrix);
      expect(restored.isCustom, isFalse);
      expect(restored.accentColor, sample.accentColor);
    });

    test('falls back to the identity matrix on malformed data', () {
      final restored = CinemaTone.fromJson(<String, dynamic>{
        'id': 'broken',
        'name': 'BROKEN',
        'matrix': <double>[1, 0, 0],
      });

      expect(restored.isValidMatrix, isTrue);
      expect(restored.matrix, CinemaTone.identityMatrix);
      expect(restored.filmReference, 'Imported LUT');
    });
  });

  group('Pro FilmLook & Built-in Stocks v2.0.1', () {
    test('defaults preserve stock halation/grain with zero double-sharpening', () {
      const look = FilmLook();
      expect(look.useStockEffects, isTrue);
      expect(look.acutance, 0.0);
      expect(look.shadowDepth, 0.0);

      final native = look.toNative();
      expect(native['useStockEffects'], isTrue);
      expect(native['shadowDepth'], 0.0);
      expect(native['acutance'], 0.0);
    });

    test('migrates legacy v3 default acutance (0.22) cleanly to 0.0', () {
      final restored = FilmLook.fromJson(<String, dynamic>{
        'v': 3,
        'useStockEffects': true,
        'acutance': 0.22,
        'shadowDepth': 0.3,
      });
      expect(restored.acutance, 0.0);
      expect(restored.shadowDepth, closeTo(0.3, 1e-6));
    });

    test('FilmLook JSON round trip preserves shadowDepth & acutance', () {
      const custom = FilmLook(
        useStockEffects: false,
        shadowDepth: 0.65,
        acutance: 0.45,
        halation: 0.5,
      );
      final restored = FilmLook.fromJson(custom.toJson());
      expect(restored.useStockEffects, isFalse);
      expect(restored.shadowDepth, closeTo(0.65, 1e-6));
      expect(restored.acutance, closeTo(0.45, 1e-6));
      expect(restored.halation, closeTo(0.5, 1e-6));
    });

    test('built-in presets include Leica Chiaroscuro, ARRI Alexa 709 & Tri-X', () {
      final ids = const CinemaTonesPresetSource()
          .getHollywoodTones()
          .map((t) => t.id)
          .toSet();
      expect(ids, containsAll(<String>[
        'leica_chiaroscuro',
        'arri_alexa_709',
        'kodak_trix_400',
        'cinestill_800t',
        'kodak_2383',
      ]));
    });
  });

  group('Vintage Frame Formats & Auto-Localization (v2.2.0)', () {
    test('CameraFrameFormat exposes vintage & cinema aspect ratios cleanly', () {
      expect(CameraFrameFormat.full.isFramed, isFalse);
      expect(CameraFrameFormat.square1x1.aspectRatio, closeTo(1.0, 1e-6));
      expect(CameraFrameFormat.portrait4x5.aspectRatio, closeTo(0.8, 1e-6));
      expect(CameraFrameFormat.medium6x7.aspectRatio, closeTo(6 / 7, 1e-6));
      expect(CameraFrameFormat.classic35mm.aspectRatio, closeTo(1.5, 1e-6));
      expect(CameraFrameFormat.scope239.aspectRatio, closeTo(2.39, 1e-6));
      expect(CameraFrameFormat.xpan.aspectRatio, closeTo(65 / 24, 1e-6));
      expect(CameraFrameFormat.fromName('square1x1'), CameraFrameFormat.square1x1);
      expect(CameraFrameFormat.fromName('65:24'), CameraFrameFormat.xpan);
      expect(CameraFrameFormat.fromName('unknown'), CameraFrameFormat.full);
    });

    test('AppStrings provides concise EN & ID labels', () {
      expect(AppStrings.en.photo, 'PHOTO');
      expect(AppStrings.id.photo, 'FOTO');
      expect(AppStrings.en.gallery, 'GALLERY');
      expect(AppStrings.id.gallery, 'GALERI');
      expect(AppStrings.en.selectedCount(3), '3 selected');
      expect(AppStrings.id.selectedCount(3), '3 dipilih');
      expect(AppStrings.en.changelogBtn, 'View Changelog');
      expect(AppStrings.id.changelogBtn, 'Lihat Riwayat Versi');
    });

    test('FilmLook v2.3 preserves ACES/AgX filmicRollOff in JSON & native payload', () {
      const look = FilmLook(filmicRollOff: 0.65, shadowDepth: 0.2);
      final restored = FilmLook.fromJson(look.toJson());
      expect(restored.filmicRollOff, closeTo(0.65, 1e-6));
      expect(restored.toNative()['filmicRollOff'], closeTo(0.65, 1e-6));
    });

    test('v2.4 AppStrings expose Portrait, Cinematic & 48MP labels in EN/ID', () {
      expect(AppStrings.en.portrait, 'PORTRAIT');
      expect(AppStrings.id.portrait, 'POTRET');
      expect(AppStrings.en.cinematic, 'CINEMATIC');
      expect(AppStrings.id.cinematic, 'SINEMATIK');
      expect(AppStrings.en.hiRes48MP, '48MP HI-RES');
      expect(AppStrings.id.hiRes48MP, '48MP PENUH');
    });

    test('v3.3 native camera enums & OpticalLensOption work cleanly (PHOTO + VIDEO)', () {
      const lens = OpticalLensOption(id: 'wide#2x', label: '2×', initialZoom: 2.0);
      expect(lens.id, 'wide#2x');
      expect(lens.label, '2×');
      expect(lens.initialZoom, 2.0);
      expect(CameraLensDirection.values, hasLength(2));
      expect(FlashMode.values, containsAll(<FlashMode>[FlashMode.off, FlashMode.auto, FlashMode.torch]));
      expect(CinemaCaptureMode.values, hasLength(2));
      expect(CinemaCaptureMode.photo.isPhoto, isTrue);
      expect(CinemaCaptureMode.video24fps.isVideo, isTrue);
    });
  });
}
