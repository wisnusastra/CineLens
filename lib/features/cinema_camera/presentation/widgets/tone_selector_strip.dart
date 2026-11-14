import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/cinema_tone.dart';

class ToneSelectorStrip extends StatelessWidget {
  final List<CinemaTone> tones;
  final CinemaTone selectedTone;
  final ValueChanged<CinemaTone> onToneSelected;
  final VoidCallback onOpenCustomCreator;
  final ValueChanged<CinemaTone>? onDeleteCustomTone;

  const ToneSelectorStrip({
    super.key,
    required this.tones,
    required this.selectedTone,
    required this.onToneSelected,
    required this.onOpenCustomCreator,
    this.onDeleteCustomTone,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tones.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return GestureDetector(
              onTap: () {
                HapticFeedback.mediumImpact();
                onOpenCustomCreator();
              },
              child: Container(
                width: 92,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.cinemaAmber.withValues(alpha: 0.7),
                    width: 1.2,
                  ),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      CupertinoIcons.slider_horizontal_3,
                      color: AppTheme.cinemaAmber,
                      size: 20,
                    ),
                    SizedBox(height: 6),
                    Text(
                      '+ CUSTOM',
                      style: TextStyle(
                        color: AppTheme.cinemaAmber,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final tone = tones[index - 1];
          final isSelected = tone.id == selectedTone.id;

          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onToneSelected(tone);
            },
            onLongPress: tone.isCustom && onDeleteCustomTone != null
                ? () {
                    HapticFeedback.heavyImpact();
                    onDeleteCustomTone!(tone);
                  }
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 122,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.cinemaAmber.withValues(alpha: 0.18)
                    : AppTheme.surfaceDark.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.cinemaAmber
                      : Colors.white.withValues(alpha: 0.12),
                  width: isSelected ? 1.5 : 1.0,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: tone.accentColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tone.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected
                                ? AppTheme.cinemaAmber
                                : AppTheme.textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tone.isCustom ? '★ ${tone.filmReference}' : tone.filmReference,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
