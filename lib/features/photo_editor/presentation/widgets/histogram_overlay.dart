// lib/features/photo_editor/presentation/widgets/histogram_overlay.dart

import 'package:flutter/material.dart';

/// Compact translucent Live RGB + Luminance Histogram rendered over the top
/// corner of the editor preview, just like Lightroom Mobile.
class HistogramOverlay extends StatelessWidget {
  final Map<String, List<double>> histogram;

  const HistogramOverlay({super.key, required this.histogram});

  @override
  Widget build(BuildContext context) {
    if (histogram.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Container(
        width: 148,
        height: 54,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.64),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: CustomPaint(
          painter: _HistogramPainter(histogram),
        ),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final Map<String, List<double>> histogram;

  const _HistogramPainter(this.histogram);

  void _drawCurve(Canvas canvas, Size size, List<double>? bins, Color color) {
    if (bins == null || bins.length < 2) return;
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
        ..color = color.withValues(alpha: 0.34)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Subtle exposure grid lines at 25%, 50%, 75%.
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 0.6;
    for (final frac in const <double>[0.25, 0.5, 0.75]) {
      final x = size.width * frac;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    _drawCurve(canvas, size, histogram['luma'], Colors.white);
    _drawCurve(canvas, size, histogram['r'], const Color(0xFFFF5A5A));
    _drawCurve(canvas, size, histogram['g'], const Color(0xFF5AD27C));
    _drawCurve(canvas, size, histogram['b'], const Color(0xFF4A8DFF));
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter oldDelegate) =>
      oldDelegate.histogram != histogram;
}
