// lib/features/photo_editor/presentation/widgets/edit_slider.dart

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// One labelled adjustment row, compact enough to stack a full Lightroom-style
/// panel in a phone-width sheet.
///
/// Double-tapping the label resets the value to [resetValue], which is the
/// fastest way back to neutral while grading on a small screen.
class EditSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String Function(double value) format;
  final double resetValue;
  final Color? accent;

  const EditSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.format,
    this.min = -1,
    this.max = 1,
    this.resetValue = 0,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? AppTheme.cinemaAmber;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => onChanged(resetValue),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Text(
                format(value),
                style: TextStyle(
                  color: (value - resetValue).abs() < 0.001
                      ? AppTheme.textSecondary
                      : tint,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 30,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: tint,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
                thumbColor: tint,
                overlayColor: tint.withValues(alpha: 0.16),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                tickMarkShape: SliderTickMarkShape.noTickMark,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
