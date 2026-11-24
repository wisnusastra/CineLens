// lib/features/photo_editor/presentation/widgets/color_grading_wheel.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/photo_edit.dart';

/// Interactive Lightroom-style HSV Color Grading Wheel.
///
/// Drag anywhere on the wheel to set hue (angle) and saturation (distance from
/// centre); double-tap to reset the wheel cleanly to neutral.
class ColorGradingWheel extends StatelessWidget {
  final ColorWheelGrade grade;
  final ValueChanged<ColorWheelGrade> onChanged;
  final double size;

  const ColorGradingWheel({
    super.key,
    required this.grade,
    required this.onChanged,
    this.size = 136,
  });

  void _updateFromLocal(Offset localPosition) {
    final radius = size / 2.0 - 8.0;
    final center = Offset(size / 2.0, size / 2.0);
    final dx = localPosition.dx - center.dx;
    final dy = localPosition.dy - center.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    final sat = (dist / radius).clamp(0.0, 1.0);
    var deg = math.atan2(dy, dx) * 180.0 / math.pi;
    if (deg < 0) deg += 360.0;
    onChanged(grade.copyWith(hue: deg, saturation: sat));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: () => onChanged(ColorWheelGrade.neutral),
      onPanDown: (details) => _updateFromLocal(details.localPosition),
      onPanUpdate: (details) => _updateFromLocal(details.localPosition),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _ColorWheelPainter(grade: grade),
        ),
      ),
    );
  }
}

class _ColorWheelPainter extends CustomPainter {
  final ColorWheelGrade grade;

  const _ColorWheelPainter({required this.grade});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8.0;

    // 1. Hue sweep gradient background.
    final sweep = SweepGradient(
      colors: const <Color>[
        Color(0xFFFF4B4B),
        Color(0xFFFFD84B),
        Color(0xFF4BFF6B),
        Color(0xFF4BFFFF),
        Color(0xFF4B7BFF),
        Color(0xFFFF4BFF),
        Color(0xFFFF4B4B),
      ],
    );
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = sweep.createShader(rect),
    );

    // 2. Desaturated neutral core fading outward.
    final radial = RadialGradient(
      colors: <Color>[
        const Color(0xFF2B2B30),
        const Color(0xFF2B2B30).withValues(alpha: 0.72),
        Colors.transparent,
      ],
      stops: const <double>[0.0, 0.28, 1.0],
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = radial.createShader(rect),
    );

    // 3. Outer subtle border & crosshair.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.22),
    );
    final crossPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.16)
      ..strokeWidth = 0.8;
    canvas.drawLine(
      Offset(center.dx - 6, center.dy),
      Offset(center.dx + 6, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 6),
      Offset(center.dx, center.dy + 6),
      crossPaint,
    );

    // 4. Vector line + draggable puck.
    final angle = grade.hue * math.pi / 180.0;
    final puck = Offset(
      center.dx + math.cos(angle) * grade.saturation * radius,
      center.dy + math.sin(angle) * grade.saturation * radius,
    );

    if (grade.saturation > 0.01) {
      canvas.drawLine(
        center,
        puck,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..strokeWidth = 1.2,
      );
    }

    final puckFill = grade.saturation > 0.01
        ? HSVColor.fromAHSV(1, grade.hue, grade.saturation, 1).toColor()
        : AppTheme.cinemaAmber;

    canvas.drawCircle(
      puck,
      7.5,
      Paint()..color = Colors.black.withValues(alpha: 0.65),
    );
    canvas.drawCircle(
      puck,
      6.0,
      Paint()..color = puckFill,
    );
    canvas.drawCircle(
      puck,
      6.0,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) =>
      oldDelegate.grade.hue != grade.hue ||
      oldDelegate.grade.saturation != grade.saturation ||
      oldDelegate.grade.luminance != grade.luminance;
}
