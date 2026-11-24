// lib/features/options/presentation/widgets/cinematic_viewfinder_overlay.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/camera_options_state.dart';
import '../providers/camera_options_provider.dart';

/// Clean hairline composition grid overlay (Rule of Thirds / Golden Ratio /
/// Crosshair). Frame aspect-ratio masks and top telemetry now live directly in
/// the unified Camera HUD so nothing ever overlaps.
class CinematicViewfinderOverlay extends ConsumerWidget {
  final String activeToneName;
  final bool showGrid;

  const CinematicViewfinderOverlay({
    super.key,
    this.activeToneName = 'Standard',
    this.showGrid = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gridType = ref.watch(
      cameraOptionsProvider.select((s) => s.gridType),
    );
    if (!showGrid || gridType == GridOverlayType.none) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: CustomPaint(
        painter: _GridOverlayPainter(gridType: gridType),
      ),
    );
  }
}

class _GridOverlayPainter extends CustomPainter {
  final GridOverlayType gridType;

  const _GridOverlayPainter({required this.gridType});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 0.8;

    if (gridType == GridOverlayType.ruleOfThirds) {
      for (var i = 1; i <= 2; i++) {
        final dx = size.width * (i / 3);
        final dy = size.height * (i / 3);
        canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
        canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
      }
    } else if (gridType == GridOverlayType.goldenRatio) {
      const phi = 0.382;
      const invPhi = 1 - phi;
      canvas.drawLine(
        Offset(size.width * phi, 0),
        Offset(size.width * phi, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(size.width * invPhi, 0),
        Offset(size.width * invPhi, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(0, size.height * phi),
        Offset(size.width, size.height * phi),
        paint,
      );
      canvas.drawLine(
        Offset(0, size.height * invPhi),
        Offset(size.width, size.height * invPhi),
        paint,
      );
    } else if (gridType == GridOverlayType.crosshair) {
      final cx = size.width / 2;
      final cy = size.height / 2;
      canvas.drawLine(Offset(cx - 22, cy), Offset(cx + 22, cy), paint);
      canvas.drawLine(Offset(cx, cy - 22), Offset(cx, cy + 22), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridOverlayPainter oldDelegate) =>
      oldDelegate.gridType != gridType;
}
