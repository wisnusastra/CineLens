// lib/features/cinema_camera/presentation/widgets/film_look_section.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/film_look.dart';
import '../providers/cinema_camera_provider.dart';
import '../providers/cinema_camera_state.dart';

/// "Film emulation" panel: `.cube` import plus grain / halation / bloom /
/// vignette strengths, and the ProRes bake switch.
///
/// The values only travel with the next capture, so dragging a slider never
/// reconfigures the running capture session.
class FilmLookSection extends StatelessWidget {
  final CinemaCameraState state;
  final CinemaCameraNotifier notifier;
  final bool haptics;

  const FilmLookSection({
    super.key,
    required this.state,
    required this.notifier,
    required this.haptics,
  });

  @override
  Widget build(BuildContext context) {
    final look = state.filmLook;
    final tone = state.selectedTone;

    void apply(FilmLook next) {
      if (haptics) HapticFeedback.selectionClick();
      notifier.setFilmLook(next);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'FILM EMULATION',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E22),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tone.isLutTone
                              ? 'LUT: ${tone.name}'
                              : 'Tone: ${tone.name}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tone.isLutTone
                              ? 'LUT 3D asli dipakai saat simpan. Pratinjau '
                                  'memakai pendekatan matriks warna.'
                              : 'Efek berikut dirender ke foto & video.',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.amber,
                      side: const BorderSide(color: Colors.amber),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => _importLut(context),
                    child: const Text(
                      'IMPOR .CUBE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (!tone.isLutTone && !tone.isCustom) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeThumbColor: Colors.amber,
                  title: const Text(
                    'Efek Bawaan Film Stock',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: Text(
                    look.useStockEffects
                        ? 'Aktif: memakai halation, bloom & grain asli milik ${tone.name}.'
                        : 'Manual: halation, bloom & grain mengikuti slider di bawah.',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  value: look.useStockEffects,
                  onChanged: (value) =>
                      apply(look.copyWith(useStockEffects: value)),
                ),
                const SizedBox(height: 4),
              ],
              _FilmSlider(
                label: 'DEEP SHADOW (CHIAROSCURO)',
                value: look.shadowDepth,
                onChanged: (value) => apply(look.copyWith(shadowDepth: value)),
              ),
              _FilmSlider(
                label: 'KETAJAMAN OPTIK (ACUTANCE)',
                value: look.acutance,
                onChanged: (value) => apply(look.copyWith(acutance: value)),
              ),
              if (!look.useStockEffects || tone.isLutTone || tone.isCustom) ...[
                _FilmSlider(
                  label: 'GRAIN',
                  value: look.grain,
                  onChanged: (value) => apply(look.copyWith(grain: value)),
                ),
                _FilmSlider(
                  label: 'UKURAN GRAIN',
                  value: look.grainSize,
                  onChanged: (value) => apply(look.copyWith(grainSize: value)),
                ),
                _FilmSlider(
                  label: 'HALATION',
                  value: look.halation,
                  onChanged: (value) => apply(look.copyWith(halation: value)),
                ),
                _FilmSlider(
                  label: 'BLOOM',
                  value: look.bloom,
                  onChanged: (value) => apply(look.copyWith(bloom: value)),
                ),
                _FilmSlider(
                  label: 'VIGNETTE',
                  value: look.vignette,
                  onChanged: (value) => apply(look.copyWith(vignette: value)),
                ),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white54,
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => apply(const FilmLook()),
                  child: const Text(
                    'RESET EFEK',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const Divider(height: 12, color: Colors.white12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeThumbColor: Colors.amber,
                title: const Text(
                  'Process Zero RAW (Bypass Smart HDR)',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                subtitle: const Text(
                  'Foto diambil langsung dari sensor RAW tanpa angkat bayangan '
                  'Smart HDR Apple — shadow hitam pekat & organik ala kamera pro.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                value: state.processZeroEnabled,
                onChanged: (value) {
                  if (haptics) HapticFeedback.selectionClick();
                  notifier.setProcessZeroEnabled(value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeThumbColor: Colors.amber,
                title: const Text(
                  'Highlight Metering (Chiaroscuro)',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                subtitle: const Text(
                  'Mengukur cahaya dari area terang (-0.9 EV + Deep Shadow) '
                  'supaya sorotan matahari tajam & bayangan jatuh hitam pekat.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                value: state.highlightMeteringEnabled,
                onChanged: (value) {
                  if (haptics) HapticFeedback.selectionClick();
                  notifier.setHighlightMeteringEnabled(value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeThumbColor: Colors.amber,
                title: const Text(
                  'True 2.39:1 Crop (Tanpa Bar Hitam)',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                subtitle: const Text(
                  'Saat mode Anamorphic aktif, hasil foto & video benar-benar '
                  'di-crop 2.39:1 sinema tanpa bar hitam atas-bawah.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                value: state.anamorphicCrop,
                onChanged: state.isRecordingVideo
                    ? null
                    : (value) {
                        if (haptics) HapticFeedback.selectionClick();
                        notifier.setAnamorphicCrop(value);
                      },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'DESQUEEZE LENSA ANAMORPHIC',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        for (final factor in const <double>[1.0, 1.33, 1.55])
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: ChoiceChip(
                              label: Text(
                                factor == 1.0 ? 'OFF' : '${factor}×',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              selected:
                                  (state.anamorphicDesqueeze - factor).abs() <
                                      0.02,
                              selectedColor: Colors.amber,
                              backgroundColor: const Color(0xFF28282E),
                              labelStyle: TextStyle(
                                color: (state.anamorphicDesqueeze - factor)
                                            .abs() <
                                        0.02
                                    ? Colors.black
                                    : Colors.white70,
                              ),
                              onSelected: state.isRecordingVideo
                                  ? null
                                  : (_) {
                                      if (haptics) {
                                        HapticFeedback.selectionClick();
                                      }
                                      notifier.setAnamorphicDesqueeze(factor);
                                    },
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.anamorphicDesqueeze > 1.02
                          ? '⚠ Aktif (${state.anamorphicDesqueeze}×) — khusus lensa fisik clip-on Anamorphic. Matikan (OFF) untuk lensa iPhone biasa agar foto tidak tertarik.'
                          : 'Khusus lensa fisik clip-on Anamorphic (Moment/Sandmarc). Biarkan OFF untuk lensa iPhone biasa.',
                      style: TextStyle(
                        color: state.anamorphicDesqueeze > 1.02
                            ? Colors.amber
                            : Colors.white54,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 12, color: Colors.white12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeThumbColor: Colors.amber,
                title: const Text(
                  'Sertakan look di ProRes',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: const Text(
                  'Master ProRes 422 direkam ulang dengan tone + efek dibakar. '
                  'Nonaktif = master tetap flat untuk grading manual.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                value: state.bakeLookIntoProRes,
                onChanged: state.proResEnabled
                    ? (value) {
                        if (haptics) HapticFeedback.selectionClick();
                        notifier.setBakeLookIntoProRes(value);
                      }
                    : null,
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'Pratinjau menampilkan tone, grain, dan vignette. Halation & '
                  'bloom dirender saat foto/video disimpan.',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _importLut(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await notifier.importCubeLuts();
      if (count == 0) {
        messenger.showSnackBar(
          const SnackBar(
              content: Text('Tidak ada LUT .cube yang bisa diimpor.')),
        );
        return;
      }
      if (haptics) HapticFeedback.mediumImpact();
      messenger.showSnackBar(
        SnackBar(content: Text('$count LUT diimpor dan langsung aktif.')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Gagal mengimpor LUT: $error')),
      );
    }
  }
}

class _FilmSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _FilmSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            Text(
              '${(value.clamp(0.0, 1.0) * 100).round()}%',
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        SizedBox(
          height: 28,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.clamp(0.0, 1.0),
              activeColor: Colors.amber,
              inactiveColor: Colors.white24,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
