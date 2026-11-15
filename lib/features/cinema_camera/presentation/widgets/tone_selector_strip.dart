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

  /// Shorter cards used in landscape, where the tray must stay out of the way.
  final bool compact;

  const ToneSelectorStrip({
    super.key,
    required this.tones,
    required this.selectedTone,
    required this.onToneSelected,
    required this.onOpenCustomCreator,
    this.onDeleteCustomTone,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final cardHeight = compact ? 52.0 : 76.0;
    final cardPadding = compact ? 8.0 : 10.0;

    return SizedBox(
      height: cardHeight,
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
                width: compact ? 74 : 92,
                padding: EdgeInsets.all(cardPadding),
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
              width: compact ? 104 : 122,
              padding: EdgeInsets.all(cardPadding),
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
                      _ToneSwatch(tone: tone, size: compact ? 11 : 13),
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
                  if (!compact) ...[
                    const SizedBox(height: 6),
                    Text(
                      tone.isCustom
                          ? '★ ${tone.filmReference}'
                          : tone.filmReference,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Miniature of the tone applied to a neutral highlight/skin/shadow ramp.
///
/// It goes through the exact same matrix as the viewfinder, so a preset card
/// now shows the colour response the capture will actually have instead of a
/// decorative accent dot.
class _ToneSwatch extends StatelessWidget {
  final CinemaTone tone;
  final double size;

  const _ToneSwatch({required this.tone, this.size = 12});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: tone.accentColor, width: 0.9),
      ),
      child: ClipOval(
        child: ColorFiltered(
          colorFilter: ColorFilter.matrix(tone.matrix),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF3E0C7),
                  Color(0xFFB9805C),
                  Color(0xFF2F4A54),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
