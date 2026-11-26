import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';

/// Metadata for one Watermark Frame preset.
class WatermarkFramePreset {
  final String id;
  final String label;
  final String category; // 'signature' | 'film' | 'minimal'

  const WatermarkFramePreset({
    required this.id,
    required this.label,
    required this.category,
  });

  static const List<WatermarkFramePreset> all = <WatermarkFramePreset>[
    // Signature Cinema (vivo/ZEISS/Leica editorial style)
    WatermarkFramePreset(
      id: 'cinema_bar',
      label: 'Classic Bar',
      category: 'signature',
    ),
    WatermarkFramePreset(
      id: 'side_strip',
      label: 'Side Strip',
      category: 'signature',
    ),
    WatermarkFramePreset(
      id: 'cinema_gallery',
      label: 'Gallery Frame',
      category: 'signature',
    ),
    WatermarkFramePreset(
      id: 'corner_glass',
      label: 'Corner Glass',
      category: 'signature',
    ),

    // Film Heritage (analog 35mm, 120, slate, polaroid)
    WatermarkFramePreset(
      id: 'film_35mm',
      label: '35mm Kodak',
      category: 'film',
    ),
    WatermarkFramePreset(
      id: 'film_120',
      label: '120 Medium',
      category: 'film',
    ),
    WatermarkFramePreset(
      id: 'cinema_slate',
      label: 'Director Slate',
      category: 'film',
    ),
    WatermarkFramePreset(
      id: 'polaroid',
      label: 'Polaroid',
      category: 'film',
    ),

    // Minimal & Classic
    WatermarkFramePreset(
      id: 'none',
      label: 'None',
      category: 'minimal',
    ),
    WatermarkFramePreset(
      id: 'leica_white',
      label: 'Leica Dot',
      category: 'minimal',
    ),
    WatermarkFramePreset(
      id: 'dark_matte',
      label: 'Dark Matte',
      category: 'minimal',
    ),
    WatermarkFramePreset(
      id: 'minimal_left',
      label: 'Minimal Left',
      category: 'minimal',
    ),
    WatermarkFramePreset(
      id: 'minimal_center',
      label: 'Minimal Center',
      category: 'minimal',
    ),
  ];

  static String labelFor(String id) {
    for (final p in all) {
      if (p.id == id) return p.label;
    }
    return 'None';
  }
}

/// Visual Watermark Frame Studio modeled on flagship camera watermark pickers:
/// - Theme selector pills: `White` | `Black` | `Glass`
/// - Grouped visual wireframe thumbnail cards (`Signature Cinema`, `Film Heritage`, `Minimal`)
class WatermarkFramePicker extends StatelessWidget {
  final String selectedStyle;
  final String selectedTheme; // 'white' | 'black' | 'glass'
  final ValueChanged<String> onStyleChanged;
  final ValueChanged<String> onThemeChanged;
  final bool compact;

  const WatermarkFramePicker({
    super.key,
    required this.selectedStyle,
    required this.selectedTheme,
    required this.onStyleChanged,
    required this.onThemeChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final signature = WatermarkFramePreset.all
        .where((p) => p.category == 'signature')
        .toList();
    final film =
        WatermarkFramePreset.all.where((p) => p.category == 'film').toList();
    final minimal =
        WatermarkFramePreset.all.where((p) => p.category == 'minimal').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top header row: Watermark Frames badge + White | Black | Glass theme switcher
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 16),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.cinemaAmber.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.cinemaAmber.withValues(alpha: 0.55),
                  ),
                ),
                child: Text(
                  selectedStyle != 'none' ? 'Watermark' : 'Watermark Frames',
                  style: const TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              if (selectedStyle != 'none') ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onStyleChanged('none');
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.cinemaRed.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppTheme.cinemaRed.withValues(alpha: 0.55),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.close_rounded,
                          size: 11,
                          color: AppTheme.cinemaRed,
                        ),
                        SizedBox(width: 2),
                        Text(
                          'OFF',
                          style: TextStyle(
                            color: AppTheme.cinemaRed,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const Spacer(),
              for (final t in const <(String, String)>[
                ('white', 'White'),
                ('black', 'Black'),
                ('glass', 'Glass'),
              ]) ...[
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onThemeChanged(t.$1);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    margin: const EdgeInsets.only(left: 5),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: selectedTheme == t.$1
                          ? AppTheme.cinemaAmber
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      t.$2,
                      style: TextStyle(
                        color: selectedTheme == t.$1
                            ? Colors.black
                            : AppTheme.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        _buildGroup('Signature Cinema', signature),
        const SizedBox(height: 10),
        _buildGroup('Film Heritage', film),
        const SizedBox(height: 10),
        _buildGroup('Minimal & Classic', minimal),
      ],
    );
  }

  Widget _buildGroup(String title, List<WatermarkFramePreset> items) {
    final hPad = compact ? 0.0 : 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: Text(
            title,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 86,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: hPad),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, idx) {
              final item = items[idx];
              final selected = selectedStyle == item.id;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onStyleChanged(selected ? 'none' : item.id);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 84,
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
                  decoration: BoxDecoration(
                    color: AppTheme.cardDark,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: selected
                          ? AppTheme.cinemaAmber
                          : Colors.white.withValues(alpha: 0.14),
                      width: selected ? 1.6 : 0.9,
                    ),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: _FrameSchematic(
                          style: item.id,
                          theme: selectedTheme,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? AppTheme.cinemaAmber
                              : AppTheme.textPrimary.withValues(alpha: 0.85),
                          fontSize: 8.8,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Miniature wireframe preview of each Watermark Frame layout.
class _FrameSchematic extends StatelessWidget {
  final String style;
  final String theme;

  const _FrameSchematic({required this.style, required this.theme});

  @override
  Widget build(BuildContext context) {
    final isGlass = theme == 'glass' || style == 'corner_glass';
    final isDark = theme == 'black' ||
        style == 'dark_matte' ||
        style == 'film_35mm' ||
        style == 'film_120' ||
        style == 'cinema_slate';
    final frameBg = isGlass
        ? const Color(0xFF475569)
        : isDark
            ? const Color(0xFF141519)
            : const Color(0xFFF3F4F6);
    const photoFill = Color(0xFF4A596A);
    final accent = (style == 'film_35mm' ||
            style == 'film_120' ||
            style == 'cinema_slate' ||
            isDark ||
            isGlass)
        ? AppTheme.cinemaAmber
        : style == 'leica_white'
            ? const Color(0xFFE63946)
            : const Color(0xFF1A6CE8);

    if (style == 'none') {
      return Container(
        decoration: BoxDecoration(
          color: photoFill,
          borderRadius: BorderRadius.circular(5),
        ),
      );
    }

    if (style == 'side_strip') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Row(
          children: [
            const Expanded(flex: 4, child: ColoredBox(color: photoFill)),
            Expanded(
              flex: 1,
              child: Container(
                color: isGlass ? Colors.black.withValues(alpha: 0.55) : frameBg,
                alignment: Alignment.bottomCenter,
                padding: const EdgeInsets.only(bottom: 4),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (style == 'corner_glass') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: photoFill),
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                width: 34,
                height: 11,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.white24, width: 0.5),
                ),
                alignment: Alignment.centerLeft,
                child: Container(width: 12, height: 2.5, color: accent),
              ),
            ),
          ],
        ),
      );
    }

    if (style == 'film_35mm' || style == 'film_120') {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0E0E10),
          borderRadius: BorderRadius.circular(5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: photoFill,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (style == 'film_35mm')
              Align(
                alignment: Alignment.topCenter,
                child: Transform.translate(
                  offset: const Offset(0, -4.5),
                  child: Container(width: 24, height: 2, color: accent),
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Transform.translate(
                offset: const Offset(0, 4.5),
                child: Container(width: 28, height: 2, color: accent),
              ),
            ),
          ],
        ),
      );
    }

    final hasAllSides = style == 'cinema_gallery' ||
        style == 'leica_white' ||
        style == 'dark_matte' ||
        style == 'polaroid';
    final bottomHeight = style == 'polaroid' ? 16.0 : 12.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Container(
        color: frameBg,
        padding: hasAllSides && !isGlass
            ? const EdgeInsets.fromLTRB(4, 4, 4, 0)
            : EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: photoFill,
                      borderRadius: hasAllSides && !isGlass
                          ? BorderRadius.circular(2)
                          : BorderRadius.zero,
                    ),
                  ),
                ),
                if (!isGlass)
                  SizedBox(
                    height: bottomHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Row(
                        mainAxisAlignment: (style == 'minimal_center' ||
                                style == 'leica_white' ||
                                style == 'dark_matte' ||
                                style == 'polaroid')
                            ? MainAxisAlignment.center
                            : MainAxisAlignment.spaceBetween,
                        children: [
                          Container(
                            width: 18,
                            height: 3,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          ),
                          if (style == 'cinema_bar' ||
                              style == 'cinema_gallery' ||
                              style == 'cinema_slate')
                            Container(
                              width: 12,
                              height: 3,
                              decoration: BoxDecoration(
                                color: isDark ? Colors.white54 : Colors.black38,
                                borderRadius: BorderRadius.circular(1.5),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (isGlass)
              Positioned(
                left: 4,
                right: 4,
                bottom: 4,
                height: 11,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.white24, width: 0.5),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(width: 16, height: 2.5, color: accent),
                      Container(width: 10, height: 2.5, color: Colors.white60),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
