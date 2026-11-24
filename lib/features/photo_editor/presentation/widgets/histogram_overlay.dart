// lib/features/photo_editor/presentation/widgets/histogram_overlay.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';

enum CinemaScopeMode { histogram, waveform, vectorscope }

/// Tap-to-cycle Pro Cinema Scopes Overlay (`HIST` → `WAVE` → `VECT`) inspired
/// by DaVinci Resolve & OpenFilm broadcast scopes.
class HistogramOverlay extends StatefulWidget {
  final Map<String, dynamic> scopes;

  const HistogramOverlay({
    super.key,
    required Map<String, dynamic> histogram,
  }) : scopes = histogram;

  @override
  State<HistogramOverlay> createState() => _HistogramOverlayState();
}

class _HistogramOverlayState extends State<HistogramOverlay> {
  CinemaScopeMode _mode = CinemaScopeMode.histogram;

  void _cycleMode() {
    HapticFeedback.selectionClick();
    setState(() {
      _mode = CinemaScopeMode.values[
          (_mode.index + 1) % CinemaScopeMode.values.length];
    });
  }

  String get _modeLabel => switch (_mode) {
        CinemaScopeMode.histogram => 'HIST',
        CinemaScopeMode.waveform => 'WAVE',
        CinemaScopeMode.vectorscope => 'VECT',
      };

  @override
  Widget build(BuildContext context) {
    if (widget.scopes.isEmpty) return const SizedBox.shrink();

    final clipped = (widget.scopes['clippedPct'] as num?)?.toDouble() ?? 0.0;
    final crushed = (widget.scopes['crushedPct'] as num?)?.toDouble() ?? 0.0;

    return GestureDetector(
      onTap: _cycleMode,
      child: Container(
        width: _mode == CinemaScopeMode.vectorscope ? 102 : 156,
        height: _mode == CinemaScopeMode.vectorscope ? 102 : 66,
        padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: switch (_mode) {
                  CinemaScopeMode.histogram => _HistogramPainter(widget.scopes),
                  CinemaScopeMode.waveform => _WaveformPainter(widget.scopes),
                  CinemaScopeMode.vectorscope =>
                    _VectorscopePainter(widget.scopes),
                },
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  _modeLabel,
                  style: AppTheme.monoStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 7.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            if (clipped >= 0.5 || crushed >= 0.5)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    clipped >= crushed
                        ? 'HI ${clipped.toStringAsFixed(0)}%'
                        : 'LO ${crushed.toStringAsFixed(0)}%',
                    style: AppTheme.monoStyle(
                      color: clipped >= 2.0
                          ? AppTheme.cinemaRed
                          : Colors.white70,
                      fontSize: 7,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

List<double> _doubleList(dynamic raw) {
  if (raw is! List) return const <double>[];
  return raw.whereType<num>().map((e) => e.toDouble()).toList();
}

class _HistogramPainter extends CustomPainter {
  final Map<String, dynamic> scopes;
  const _HistogramPainter(this.scopes);

  void _drawCurve(Canvas canvas, Size size, List<double> bins, Color color) {
    if (bins.length < 2) return;
    final path = Path()..moveTo(0, size.height);
    final step = size.width / (bins.length - 1);
    for (var i = 0; i < bins.length; i++) {
      final x = i * step;
      final y = size.height - (bins[i].clamp(0.0, 1.0) * size.height);
      path.lineTo(x, y);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.32)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.85,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 0.6;
    for (final frac in const <double>[0.25, 0.5, 0.75]) {
      final x = size.width * frac;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    _drawCurve(canvas, size, _doubleList(scopes['luma']), Colors.white);
    _drawCurve(canvas, size, _doubleList(scopes['r']), const Color(0xFFFF5A5A));
    _drawCurve(canvas, size, _doubleList(scopes['g']), const Color(0xFF5AD27C));
    _drawCurve(canvas, size, _doubleList(scopes['b']), const Color(0xFF4A8DFF));
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter oldDelegate) =>
      oldDelegate.scopes != scopes;
}

/// 2D Broadcast Luma Waveform (0–100 IRE grid, horizontal spatial axis).
class _WaveformPainter extends CustomPainter {
  final Map<String, dynamic> scopes;
  const _WaveformPainter(this.scopes);

  @override
  void paint(Canvas canvas, Size size) {
    // 25 / 50 / 75 IRE horizontal graticule lines
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 0.6;
    for (final ire in const <double>[0.25, 0.5, 0.75]) {
      final y = size.height * (1.0 - ire);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final rawGrid = _doubleList(scopes['waveform']);
    final cols = (scopes['waveformCols'] as num?)?.toInt() ?? 48;
    final rows = (scopes['waveformRows'] as num?)?.toInt() ?? 16;
    if (rawGrid.isEmpty || cols <= 0 || rows <= 0) return;

    final cellW = size.width / cols;
    final cellH = size.height / rows;
    final paint = Paint()..style = PaintingStyle.fill;

    for (var c = 0; c < cols; c++) {
      for (var r = 0; r < rows; r++) {
        final idx = c * rows + r;
        if (idx >= rawGrid.length) continue;
        final intensity = rawGrid[idx].clamp(0.0, 1.0);
        if (intensity < 0.04) continue;
        final y = size.height - ((r + 1) * cellH);
        paint.color = Color.lerp(
          const Color(0xFF2ED573),
          const Color(0xFFE5A93B),
          intensity,
        )!
            .withValues(alpha: (0.25 + intensity * 0.75).clamp(0.0, 1.0));
        canvas.drawRect(
          Rect.fromLTWH(c * cellW, y, cellW + 0.4, cellH + 0.4),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.scopes != scopes;
}

/// Broadcast Cb/Cr Vectorscope with Skin-Tone I-Line (~123°).
class _VectorscopePainter extends CustomPainter {
  final Map<String, dynamic> scopes;
  const _VectorscopePainter(this.scopes);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.44;

    final ringPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawCircle(center, radius, ringPaint);
    canvas.drawCircle(center, radius * 0.5, ringPaint);
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      ringPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      ringPaint,
    );

    // Skin-Tone I-Line (upper-left quadrant ~123° in Cb/Cr space)
    const skinAngle = -123.0 * math.pi / 180.0;
    final skinEnd = Offset(
      center.dx + math.cos(skinAngle) * radius,
      center.dy + math.sin(skinAngle) * radius,
    );
    canvas.drawLine(
      center,
      skinEnd,
      Paint()
        ..color = AppTheme.cinemaAmber.withValues(alpha: 0.55)
        ..strokeWidth = 1.0,
    );

    final pts = _doubleList(scopes['vectorscope']);
    if (pts.length < 2) return;

    final dotPaint = Paint()
      ..color = const Color(0xFF4ADE80).withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    for (var i = 0; i + 1 < pts.length; i += 2) {
      final cb = pts[i].clamp(-0.5, 0.5) * 2.0; // -1..1
      final cr = pts[i + 1].clamp(-0.5, 0.5) * 2.0; // -1..1
      final x = center.dx + cb * radius;
      final y = center.dy - cr * radius;
      canvas.drawCircle(Offset(x, y), 1.1, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _VectorscopePainter oldDelegate) =>
      oldDelegate.scopes != scopes;
}
