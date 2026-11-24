import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/cinema_tone.dart';

/// Ultra-clean Leica / Kino style film-stock pill strip (38px height).
class ToneSelectorStrip extends StatelessWidget {
  final List<CinemaTone> tones;
  final CinemaTone selectedTone;
  final ValueChanged<CinemaTone> onToneSelected;
  final VoidCallback onOpenCustomCreator;
  final ValueChanged<CinemaTone>? onDeleteCustomTone;

  /// Shorter pills used in landscape, keeping the viewfinder unobstructed.
  final bool compact;

  /// The gallery editor has no custom-tone creator, so it hides that pill.
  final bool showCustomCard;

  const ToneSelectorStrip({
    super.key,
    required this.tones,
    required this.selectedTone,
    required this.onToneSelected,
    required this.onOpenCustomCreator,
    this.onDeleteCustomTone,
    this.compact = false,
    this.showCustomCard = true,
  });

  @override
  Widget build(BuildContext context) {
    final pillHeight = compact ? 34.0 : 38.0;

    return SizedBox(
      height: pillHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: tones.length + (showCustomCard ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, index) {
          if (showCustomCard && index == 0) {
            return GestureDetector(
              onTap: () {
                HapticFeedback.mediumImpact();
                onOpenCustomCreator();
              },
              child: Container(
                width: pillHeight,
                height: pillHeight,
                decoration: BoxDecoration(
                  color: AppTheme.cardDark.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.cinemaAmber.withValues(alpha: 0.6),
                    width: 1.0,
                  ),
                ),
                child: const Icon(
                  CupertinoIcons.plus,
                  color: AppTheme.cinemaAmber,
                  size: 17,
                ),
              ),
            );
          }

          final tone = tones[index - (showCustomCard ? 1 : 0)];
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
              duration: const Duration(milliseconds: 160),
              padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.cinemaAmber.withValues(alpha: 0.16)
                    : AppTheme.cardDark.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.cinemaAmber
                      : Colors.white.withValues(alpha: 0.1),
                  width: isSelected ? 1.3 : 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ToneSwatch(tone: tone, size: 10),
                  const SizedBox(width: 7),
                  Text(
                    tone.name.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.cinemaAmber
                          : AppTheme.textPrimary.withValues(alpha: 0.88),
                      fontSize: 10.5,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                  if (tone.isLutTone) ...[
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.cinemaAmber.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text(
                        '3D',
                        style: TextStyle(
                          color: AppTheme.cinemaAmber,
                          fontSize: 7.5,
                          fontWeight: FontWeight.w800,
                        ),
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

/// Miniature color response dot passed through the tone's exact matrix.
class _ToneSwatch extends StatelessWidget {
  final CinemaTone tone;
  final double size;

  const _ToneSwatch({required this.tone, this.size = 10});

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
