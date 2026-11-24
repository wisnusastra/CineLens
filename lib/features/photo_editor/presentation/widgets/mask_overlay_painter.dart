// lib/features/photo_editor/presentation/widgets/mask_overlay_painter.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/photo_edit.dart';

/// Interactive visual overlay on the editor preview for dragging either:
/// - a Linear / Radial Selective Mask (`activeMask`), or
/// - the Lens Blur focus target (`showBlurTarget`).
class EditorInteractiveOverlay extends StatelessWidget {
  final SelectiveMask? activeMask;
  final ValueChanged<SelectiveMask>? onMaskChanged;

  final bool showBlurTarget;
  final String blurStyle;
  final double blurCenterX;
  final double blurCenterY;
  final double blurRadius;
  final void Function(double cx, double cy)? onBlurCenterChanged;

  const EditorInteractiveOverlay({
    super.key,
    this.activeMask,
    this.onMaskChanged,
    this.showBlurTarget = false,
    this.blurStyle = 'radial',
    this.blurCenterX = 0.5,
    this.blurCenterY = 0.5,
    this.blurRadius = 0.32,
    this.onBlurCenterChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (activeMask == null && !showBlurTarget) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.clamp(1.0, double.infinity);
        final h = constraints.maxHeight.clamp(1.0, double.infinity);

        if (showBlurTarget) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (d) => onBlurCenterChanged?.call(
              (d.localPosition.dx / w).clamp(0.05, 0.95),
              (d.localPosition.dy / h).clamp(0.05, 0.95),
            ),
            onPanUpdate: (d) => onBlurCenterChanged?.call(
              (d.localPosition.dx / w).clamp(0.05, 0.95),
              (d.localPosition.dy / h).clamp(0.05, 0.95),
            ),
            child: CustomPaint(
              painter: _BlurGuidePainter(
                style: blurStyle,
                cx: blurCenterX,
                cy: blurCenterY,
                radius: blurRadius,
              ),
              size: Size(w, h),
            ),
          );
        }

        final mask = activeMask!;
        return _MaskGestureLayer(
          mask: mask,
          width: w,
          height: h,
          onChanged: onMaskChanged,
        );
      },
    );
  }
}

class _MaskGestureLayer extends StatefulWidget {
  final SelectiveMask mask;
  final double width;
  final double height;
  final ValueChanged<SelectiveMask>? onChanged;

  const _MaskGestureLayer({
    required this.mask,
    required this.width,
    required this.height,
    required this.onChanged,
  });

  @override
  State<_MaskGestureLayer> createState() => _MaskGestureLayerState();
}

class _MaskGestureLayerState extends State<_MaskGestureLayer> {
  // 'start', 'end', or 'move'
  String? _dragHandle;
  Offset? _lastNorm;

  @override
  Widget build(BuildContext context) {
    final m = widget.mask;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (details) {
        final p = Offset(
          details.localPosition.dx / widget.width,
          details.localPosition.dy / widget.height,
        );
        final dStart = (p - Offset(m.startX, m.startY)).distance;
        final dEnd = (p - Offset(m.endX, m.endY)).distance;
        if (dEnd < 0.10 && dEnd <= dStart) {
          _dragHandle = 'end';
        } else if (dStart < 0.12) {
          _dragHandle = 'start';
        } else {
          _dragHandle = 'move';
        }
        _lastNorm = p;
      },
      onPanUpdate: (details) {
        final p = Offset(
          (details.localPosition.dx / widget.width).clamp(0.0, 1.0),
          (details.localPosition.dy / widget.height).clamp(0.0, 1.0),
        );
        final prev = _lastNorm ?? p;
        final delta = p - prev;
        _lastNorm = p;

        if (_dragHandle == 'start') {
          if (!m.isLinear) {
            // Move whole radial circle with center handle.
            widget.onChanged?.call(
              m.copyWith(
                startX: m.startX + delta.dx,
                startY: m.startY + delta.dy,
                endX: m.endX + delta.dx,
                endY: m.endY + delta.dy,
              ),
            );
          } else {
            widget.onChanged?.call(m.copyWith(startX: p.dx, startY: p.dy));
          }
        } else if (_dragHandle == 'end') {
          widget.onChanged?.call(m.copyWith(endX: p.dx, endY: p.dy));
        } else {
          widget.onChanged?.call(
            m.copyWith(
              startX: m.startX + delta.dx,
              startY: m.startY + delta.dy,
              endX: m.endX + delta.dx,
              endY: m.endY + delta.dy,
            ),
          );
        }
      },
      onPanEnd: (_) {
        _dragHandle = null;
        _lastNorm = null;
      },
      child: CustomPaint(
        painter: _MaskGuidePainter(mask: m),
        size: Size(widget.width, widget.height),
      ),
    );
  }
}

class _MaskGuidePainter extends CustomPainter {
  final SelectiveMask mask;

  const _MaskGuidePainter({required this.mask});

  @override
  void paint(Canvas canvas, Size size) {
    final start = Offset(mask.startX * size.width, mask.startY * size.height);
    final end = Offset(mask.endX * size.width, mask.endY * size.height);

    final stroke = Paint()
      ..color = AppTheme.cinemaAmber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final tintFill = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;

    if (mask.isLinear) {
      // Draw perpendicular gradient lines at start, mid, end.
      final dir = end - start;
      final len = dir.distance;
      if (len > 2) {
        final perp = Offset(-dir.dy / len, dir.dx / len) * (size.width * 0.45);
        canvas.drawLine(start - perp, start + perp, stroke);
        canvas.drawLine(
          end - perp,
          end + perp,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.55)
            ..strokeWidth = 1.1,
        );
      }
      canvas.drawLine(start, end, stroke);
    } else {
      final radius = math.max(16.0, (end - start).distance);
      canvas.drawCircle(start, radius, tintFill);
      canvas.drawCircle(start, radius, stroke);
      final inner = radius * (1.0 - mask.feather);
      if (inner > 4) {
        canvas.drawCircle(
          start,
          inner,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
      }
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..strokeWidth = 1.0,
      );
    }

    _drawHandle(canvas, start, AppTheme.cinemaAmber);
    _drawHandle(canvas, end, Colors.white);
  }

  void _drawHandle(Canvas canvas, Offset center, Color color) {
    canvas.drawCircle(
      center,
      8,
      Paint()..color = Colors.black.withValues(alpha: 0.72),
    );
    canvas.drawCircle(center, 5.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _MaskGuidePainter oldDelegate) =>
      oldDelegate.mask != mask;
}

class _BlurGuidePainter extends CustomPainter {
  final String style;
  final double cx;
  final double cy;
  final double radius;

  const _BlurGuidePainter({
    required this.style,
    required this.cx,
    required this.cy,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(cx * size.width, cy * size.height);
    final dim = math.min(size.width, size.height);
    final r = radius * dim * 0.65;
    final paint = Paint()
      ..color = AppTheme.cinemaAmber.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    if (style == 'linear') {
      canvas.drawLine(
        Offset(0, center.dy - r * 0.55),
        Offset(size.width, center.dy - r * 0.55),
        paint,
      );
      canvas.drawLine(
        Offset(0, center.dy + r * 0.55),
        Offset(size.width, center.dy + r * 0.55),
        paint,
      );
    } else {
      canvas.drawCircle(center, r, paint);
    }
    canvas.drawCircle(
      center,
      6,
      Paint()..color = AppTheme.cinemaAmber,
    );
  }

  @override
  bool shouldRepaint(covariant _BlurGuidePainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.cx != cx ||
      oldDelegate.cy != cy ||
      oldDelegate.radius != radius;
}
