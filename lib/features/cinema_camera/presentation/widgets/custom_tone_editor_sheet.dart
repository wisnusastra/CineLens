import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/services/color_matrix_builder.dart';
import '../providers/cinema_camera_provider.dart';

class CustomToneEditorSheet extends ConsumerStatefulWidget {
  const CustomToneEditorSheet({super.key});

  @override
  ConsumerState<CustomToneEditorSheet> createState() =>
      _CustomToneEditorSheetState();
}

class _CustomToneEditorSheetState extends ConsumerState<CustomToneEditorSheet> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _refController = TextEditingController();

  CustomGradeParameters _params = const CustomGradeParameters();
  int _selectedBadgeColor = 0xFFE5A93B;

  static const List<int> _badgeColors = [
    0xFFE5A93B,
    0xFFFF6B4A,
    0xFF38BDF8,
    0xFF34D399,
    0xFFF472B6,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cinemaCameraProvider.notifier).updateLiveCustomDraft(_params);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _refController.dispose();
    // Dragging the sheet away or tapping outside bypasses the cancel button, so
    // the live draft has to be cleared here as well. Otherwise the viewfinder
    // stays on the draft matrix and tone/intensity changes look like they do
    // nothing. The notifier is captured first because `ref` is gone by the
    // time the microtask runs.
    final notifier = ref.read(cinemaCameraProvider.notifier);
    Future.microtask(() => notifier.updateLiveCustomDraft(null));
    super.dispose();
  }

  void _updateParam(CustomGradeParameters updated) {
    setState(() => _params = updated);
    ref.read(cinemaCameraProvider.notifier).updateLiveCustomDraft(updated);
  }

  Future<void> _savePreset() async {
    final rawName = _nameController.text.trim();
    final presetName = rawName.isEmpty ? 'MY FILM LUT' : rawName;

    await ref.read(cinemaCameraProvider.notifier).createAndSelectCustomTone(
          name: presetName,
          filmReference: _refController.text,
          accentColorHex: _selectedBadgeColor,
          parameters: _params,
        );

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 20 + bottomInset),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark.withValues(alpha: 0.94),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(
          color: AppTheme.cinemaAmber.withValues(alpha: 0.35),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'CUSTOM TONE STUDIO',
                  style: TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    ref
                        .read(cinemaCameraProvider.notifier)
                        .updateLiveCustomDraft(null);
                    Navigator.of(context).pop();
                  },
                  child: const Text(
                    'Batal',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: CupertinoTextField(
                    controller: _nameController,
                    placeholder: 'Nama Tone (mis. TOKYO NIGHT)',
                    placeholderStyle: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundBlack,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: CupertinoTextField(
                    controller: _refController,
                    placeholder: 'Gaya (mis. 35mm)',
                    placeholderStyle: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundBlack,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text(
                  'Warna Label:',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
                const SizedBox(width: 10),
                ..._badgeColors.map((hex) {
                  final selected = _selectedBadgeColor == hex;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedBadgeColor = hex),
                    child: Container(
                      margin: const EdgeInsets.only(right: 10),
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(hex),
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: Colors.white, width: 2.5)
                            : null,
                      ),
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 12),
            _buildGradeSlider(
              label: 'Temperature (Cool / Warm)',
              value: _params.temperature,
              min: -1.0,
              max: 1.0,
              displayValue: _params.temperature.toStringAsFixed(2),
              onChanged: (v) => _updateParam(_params.copyWith(temperature: v)),
            ),
            _buildGradeSlider(
              label: 'Tint (Green / Magenta)',
              value: _params.tint,
              min: -1.0,
              max: 1.0,
              displayValue: _params.tint.toStringAsFixed(2),
              onChanged: (v) => _updateParam(_params.copyWith(tint: v)),
            ),
            _buildGradeSlider(
              label: 'Contrast',
              value: _params.contrast,
              min: 0.6,
              max: 1.6,
              displayValue: '${(_params.contrast * 100).round()}%',
              onChanged: (v) => _updateParam(_params.copyWith(contrast: v)),
            ),
            _buildGradeSlider(
              label: 'Saturation',
              value: _params.saturation,
              min: 0.0,
              max: 1.8,
              displayValue: '${(_params.saturation * 100).round()}%',
              onChanged: (v) => _updateParam(_params.copyWith(saturation: v)),
            ),
            _buildGradeSlider(
              label: 'Exposure Offset',
              value: _params.exposure,
              min: -1.0,
              max: 1.0,
              displayValue:
                  '${_params.exposure >= 0 ? '+' : ''}${_params.exposure.toStringAsFixed(2)}',
              onChanged: (v) => _updateParam(_params.copyWith(exposure: v)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    color: AppTheme.backgroundBlack,
                    onPressed: () =>
                        _updateParam(const CustomGradeParameters()),
                    child: const Text(
                      'Reset',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: CupertinoButton.filled(
                    onPressed: _savePreset,
                    child: const Text(
                      'Simpan Preset Tone',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGradeSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                displayValue,
                style: const TextStyle(
                  color: AppTheme.cinemaAmber,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 30,
            child: CupertinoSlider(
              value: value,
              min: min,
              max: max,
              activeColor: AppTheme.cinemaAmber,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
