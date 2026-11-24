// lib/features/cinema_camera/presentation/widgets/dop_overlays.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';

/// Precision horizon level bar (Blackmagic / Leica style).
///
/// Sits softly in the center of the viewfinder and snaps to warm Cinema Amber
/// when the phone is level within ±0.8°.
class HorizonLevelOverlay extends StatelessWidget {
  final double degrees;

  const HorizonLevelOverlay({super.key, required this.degrees});

  @override
  Widget build(BuildContext context) {
    final clamped = degrees.clamp(-35.0, 35.0);
    final isLevel = clamped.abs() <= 0.85;
    final color = isLevel
        ? AppTheme.cinemaAmber
        : Colors.white.withValues(alpha: 0.52);

    return IgnorePointer(
      child: Center(
        child: SizedBox(
          width: 170,
          height: 28,
          child: CustomPaint(
            painter: _HorizonPainter(
              radians: clamped * math.pi / 180.0,
              color: color,
              isLevel: isLevel,
            ),
          ),
        ),
      ),
    );
  }
}

class _HorizonPainter extends CustomPainter {
  final double radians;
  final Color color;
  final bool isLevel;

  const _HorizonPainter({
    required this.radians,
    required this.color,
    required this.isLevel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Fixed outer reference ticks
    final refPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1.1;
    canvas.drawLine(Offset(cx - 72, cy), Offset(cx - 56, cy), refPaint);
    canvas.drawLine(Offset(cx + 56, cy), Offset(cx + 72, cy), refPaint);

    // Rotating live horizon bar
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(radians);

    final barPaint = Paint()
      ..color = color
      ..strokeWidth = isLevel ? 1.8 : 1.2
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(const Offset(-46, 0), const Offset(-8, 0), barPaint);
    canvas.drawLine(const Offset(8, 0), const Offset(46, 0), barPaint);
    canvas.drawCircle(
      Offset.zero,
      isLevel ? 2.6 : 1.8,
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HorizonPainter oldDelegate) =>
      (oldDelegate.radians - radians).abs() > 0.002 ||
      oldDelegate.isLevel != isLevel;
}

/// Real-time segmented audio peak dB meter (`-60..0 dBFS`) for video recording.
class AudioMeterOverlay extends StatelessWidget {
  final double peakDb;

  const AudioMeterOverlay({super.key, required this.peakDb});

  @override
  Widget build(BuildContext context) {
    const segments = 14;
    final norm = ((peakDb + 60.0) / 60.0).clamp(0.0, 1.0);
    final lit = (norm * segments).round();

    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.56),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'dB',
              style: AppTheme.monoStyle(
                color: Colors.white54,
                fontSize: 8,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 5),
            for (var i = 0; i < segments; i++) ...[
              Container(
                width: 3.5,
                height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1.5),
                  color: i < lit
                      ? (i >= segments - 2
                          ? AppTheme.cinemaRed
                          : i >= segments - 5
                              ? AppTheme.cinemaAmber
                              : const Color(0xFF34C759))
                      : Colors.white.withValues(alpha: 0.14),
                ),
              ),
            ],
            const SizedBox(width: 5),
            SizedBox(
              width: 24,
              child: Text(
                peakDb <= -59 ? '-∞' : '${peakDb.round()}',
                textAlign: TextAlign.right,
                style: AppTheme.monoStyle(
                  color: peakDb >= -3 ? AppTheme.cinemaRed : Colors.white70,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact real-time RGB histogram box fed by the Tahap 2 Metal pipeline.
class LiveCameraScopeMini extends StatelessWidget {
  final Map<String, dynamic>? scopeData;

  const LiveCameraScopeMini({super.key, required this.scopeData});

  @override
  Widget build(BuildContext context) {
    final data = scopeData;
    final r = _toDoubles(data?['r']);
    final g = _toDoubles(data?['g']);
    final b = _toDoubles(data?['b']);
    final clipped = (data?['clippedPct'] as num?)?.toDouble() ?? 0.0;

    return IgnorePointer(
      child: Container(
        width: 112,
        height: 44,
        padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12, width: 0.8),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _MiniHistPainter(r: r, g: g, b: b),
              ),
            ),
            if (clipped >= 0.5)
              Positioned(
                top: 0,
                right: 0,
                child: Text(
                  'CLIP ${clipped.toStringAsFixed(0)}%',
                  style: AppTheme.monoStyle(
                    color: AppTheme.cinemaRed,
                    fontSize: 7.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<double> _toDoubles(dynamic raw) {
    if (raw is! List) return const <double>[];
    return raw.map((e) => (e as num).toDouble()).toList();
  }
}

class _MiniHistPainter extends CustomPainter {
  final List<double> r;
  final List<double> g;
  final List<double> b;

  const _MiniHistPainter({required this.r, required this.g, required this.b});

  @override
  void paint(Canvas canvas, Size size) {
    if (r.isEmpty || size.isEmpty) return;

    void drawChannel(List<double> bins, Color color) {
      if (bins.isEmpty) return;
      final path = Path()..moveTo(0, size.height);
      final step = size.width / math.max(1, bins.length - 1);
      for (var i = 0; i < bins.length; i++) {
        final y = size.height - (bins[i].clamp(0.0, 1.0) * size.height);
        path.lineTo(i * step, y);
      }
      path.lineTo(size.width, size.height);
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..blendMode = BlendMode.screen,
      );
    }

    drawChannel(r, const Color(0xAAFF453A));
    drawChannel(g, const Color(0xAA30D158));
    drawChannel(b, const Color(0xAA0A84FF));
  }

  @override
  bool shouldRepaint(covariant _MiniHistPainter oldDelegate) =>
      oldDelegate.r != r || oldDelegate.g != g || oldDelegate.b != b;
}

/// Halide / Leica-inspired precision tick-ruler slider for manual camera controls
/// (Shutter, ISO, WB Kelvin, Focus) inside the 4-Tab Control Drawer.
class TactileRulerSlider extends StatelessWidget {
  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final bool enabled;
  final bool autoActive;
  final VoidCallback? onToggleAuto;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;
  final bool haptics;

  const TactileRulerSlider({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.enabled = true,
    this.autoActive = false,
    this.onToggleAuto,
    this.haptics = true,
  });

  @override
  Widget build(BuildContext context) {
    final safeMin = min;
    final safeMax = max <= min ? min + 1.0 : max;
    final clamped = value.clamp(safeMin, safeMax);
    final norm = ((clamped - safeMin) / (safeMax - safeMin)).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: !autoActive && enabled
              ? AppTheme.cinemaAmber.withValues(alpha: 0.42)
              : AppTheme.hairline,
          width: 0.9,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              Text(
                valueText,
                style: AppTheme.monoStyle(
                  color: autoActive
                      ? AppTheme.textSecondary
                      : AppTheme.cinemaAmber,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (onToggleAuto != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: enabled
                      ? () {
                          if (haptics) HapticFeedback.selectionClick();
                          onToggleAuto!();
                        }
                      : null,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: autoActive
                          ? Colors.white.withValues(alpha: 0.1)
                          : AppTheme.cinemaAmber,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      autoActive ? 'AUTO' : 'MAN',
                      style: AppTheme.monoStyle(
                        color: autoActive ? Colors.white70 : Colors.black,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              void updateFromDx(double dx) {
                if (!enabled || width <= 0) return;
                final frac = (dx / width).clamp(0.0, 1.0);
                onChanged(safeMin + frac * (safeMax - safeMin));
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) =>
                    updateFromDx(d.localPosition.dx),
                onHorizontalDragEnd: (_) => onChangeEnd?.call(),
                onTapDown: (d) {
                  if (haptics) HapticFeedback.selectionClick();
                  updateFromDx(d.localPosition.dx);
                },
                onTapUp: (_) => onChangeEnd?.call(),
                child: SizedBox(
                  height: 26,
                  child: CustomPaint(
                    painter: _RulerTicksPainter(
                      norm: norm,
                      active: enabled && !autoActive,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RulerTicksPainter extends CustomPainter {
  final double norm;
  final bool active;

  const _RulerTicksPainter({required this.norm, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    const ticks = 36;
    final step = size.width / ticks;
    final indicatorX = (norm * size.width).clamp(1.5, size.width - 1.5);

    for (var i = 0; i <= ticks; i++) {
      final x = i * step;
      final isMajor = i % 6 == 0;
      final passed = x <= indicatorX;
      final tickH = isMajor ? 14.0 : 8.0;
      final top = (size.height - tickH) / 2;
      final paint = Paint()
        ..color = active && passed
            ? AppTheme.cinemaAmber.withValues(alpha: isMajor ? 0.9 : 0.5)
            : Colors.white.withValues(alpha: isMajor ? 0.28 : 0.14)
        ..strokeWidth = isMajor ? 1.3 : 0.9
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, top), Offset(x, top + tickH), paint);
    }

    // Precision needle
    final needlePaint = Paint()
      ..color = active ? AppTheme.cinemaAmber : Colors.white54
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(indicatorX, 2),
      Offset(indicatorX, size.height - 2),
      needlePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RulerTicksPainter oldDelegate) =>
      oldDelegate.norm != norm || oldDelegate.active != active;
}
