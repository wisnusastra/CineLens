// lib/features/photo_editor/presentation/widgets/tone_curve_editor.dart

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/photo_edit.dart';

/// Draggable point curve, the same interaction as a Lightroom tone curve.
///
/// Tap empty space to add a point, drag to shape, long-press a point to delete
/// it. The curve is sampled with [sampleCurve], which is the same function the
/// preview painter uses, so the drawing matches the native LUT exactly.
class ToneCurveEditor extends StatefulWidget {
  final List<CurvePoint> points;
  final EditCurveChannel channel;
  final ValueChanged<List<CurvePoint>> onChanged;

  const ToneCurveEditor({
    super.key,
    required this.points,
    required this.onChanged,
    this.channel = EditCurveChannel.rgb,
  });

  @override
  State<ToneCurveEditor> createState() => _ToneCurveEditorState();
}

class _ToneCurveEditorState extends State<ToneCurveEditor> {
  int? _dragging;

  List<CurvePoint> get _points {
    if (widget.points.length >= 2) return widget.points;
    return const <CurvePoint>[
      CurvePoint(0, 0),
      CurvePoint(0.25, 0.25),
      CurvePoint(0.75, 0.75),
      CurvePoint(1, 1),
    ];
  }

  Color get _tint => switch (widget.channel) {
        EditCurveChannel.rgb => AppTheme.cinemaAmber,
        EditCurveChannel.red => const Color(0xFFFF6B6B),
        EditCurveChannel.green => const Color(0xFF7BE495),
        EditCurveChannel.blue => const Color(0xFF6BA8FF),
      };

  void _commit(List<CurvePoint> points) {
    final sorted = List<CurvePoint>.of(points)
      ..sort((a, b) => a.x.compareTo(b.x));
    widget.onChanged(sorted);
  }

  void _handleStart(Offset local, Size size) {
    final target = _normalize(local, size);
    var best = -1;
    var bestDistance = 0.075;
    for (var index = 0; index < _points.length; index++) {
      final point = _points[index];
      final distance =
          (point.x - target.dx).abs() + (point.y - target.dy).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }

    if (best >= 0) {
      setState(() => _dragging = best);
      return;
    }

    final points = List<CurvePoint>.of(_points)
      ..add(CurvePoint(target.dx, target.dy))
      ..sort((a, b) => a.x.compareTo(b.x));
    _commit(points);
    final inserted =
        points.indexWhere((point) => (point.x - target.dx).abs() < 0.0001);
    setState(() => _dragging = inserted < 0 ? null : inserted);
  }

  void _handleUpdate(Offset local, Size size) {
    final index = _dragging;
    if (index == null || index >= _points.length) return;

    final target = _normalize(local, size);
    final points = List<CurvePoint>.of(_points);
    final lower = index > 0 ? points[index - 1].x + 0.004 : 0.0;
    final upper = index < points.length - 1 ? points[index + 1].x - 0.004 : 1.0;
    final x = upper <= lower
        ? target.dx.clamp(0.0, 1.0)
        : target.dx.clamp(lower, upper);
    points[index] = CurvePoint(x, target.dy.clamp(0.0, 1.0));
    _commit(points);
  }

  void _handleLongPress(Offset local, Size size) {
    final target = _normalize(local, size);
    if (_points.length <= 2) return;

    var best = -1;
    var bestDistance = 0.08;
    for (var index = 0; index < _points.length; index++) {
      final point = _points[index];
      final distance =
          (point.x - target.dx).abs() + (point.y - target.dy).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    if (best < 0) return;

    final points = List<CurvePoint>.of(_points)..removeAt(best);
    setState(() => _dragging = null);
    _commit(points);
  }

  Offset _normalize(Offset local, Size size) {
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      1.0 - (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;
        final size = Size(side, side);

        return Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) =>
                  _handleStart(details.localPosition, size),
              onPanUpdate: (details) =>
                  _handleUpdate(details.localPosition, size),
              onPanEnd: (_) => setState(() => _dragging = null),
              onLongPressStart: (details) =>
                  _handleLongPress(details.localPosition, size),
              child: CustomPaint(
                painter: _CurvePainter(
                  points: _points,
                  tint: _tint,
                  dragging: _dragging,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CurvePainter extends CustomPainter {
  final List<CurvePoint> points;
  final Color tint;
  final int? dragging;

  const _CurvePainter({
    required this.points,
    required this.tint,
    required this.dragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFF101014);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(12),
      ),
      background,
    );

    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    for (var step = 1; step < 4; step++) {
      final x = size.width * step / 4;
      final y = size.height * step / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final diagonal = Paint()
      ..color = Colors.white.withValues(alpha: 0.16)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, 0),
      diagonal,
    );

    final path = Path();
    for (var step = 0; step <= 96; step++) {
      final x = step / 96.0;
      final y = sampleCurve(points, x);
      final offset = Offset(x * size.width, (1 - y) * size.height);
      if (step == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }

    final glow = Paint()
      ..color = tint.withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, glow);

    final stroke = Paint()
      ..color = tint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, stroke);

    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final center = Offset(point.x * size.width, (1 - point.y) * size.height);
      final isActive = index == dragging;
      canvas.drawCircle(
        center,
        isActive ? 7 : 5,
        Paint()..color = const Color(0xFF101014),
      );
      canvas.drawCircle(
        center,
        isActive ? 6 : 4,
        Paint()..color = tint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter oldDelegate) {
    if (oldDelegate.tint != tint || oldDelegate.dragging != dragging) {
      return true;
    }
    if (oldDelegate.points.length != points.length) return true;
    for (var index = 0; index < points.length; index++) {
      if (oldDelegate.points[index] != points[index]) return true;
    }
    return false;
  }
}
