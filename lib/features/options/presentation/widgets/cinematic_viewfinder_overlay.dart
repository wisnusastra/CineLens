// lib/features/options/presentation/widgets/cinematic_viewfinder_overlay.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/camera_options_state.dart';
import '../providers/camera_options_provider.dart';

class CinematicViewfinderOverlay extends ConsumerWidget {
  final String activeToneName;

  const CinematicViewfinderOverlay({
    super.key,
    this.activeToneName = 'Standard',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(cameraOptionsProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (options.gridType != GridOverlayType.none)
            CustomPaint(
              painter: _GridOverlayPainter(gridType: options.gridType),
            ),
          if (options.aspectRatio.ratio != null)
            LayoutBuilder(
              builder: (context, constraints) {
                final screenW = constraints.maxWidth;
                final screenH = constraints.maxHeight;
                final targetRatio = isLandscape
                    ? options.aspectRatio.ratio!
                    : (1 / options.aspectRatio.ratio!);

                double frameW = screenW;
                double frameH = screenW / targetRatio;

                if (frameH > screenH) {
                  frameH = screenH;
                  frameW = screenH * targetRatio;
                }

                final barH = ((screenH - frameH) / 2).clamp(0.0, screenH);
                final barW = ((screenW - frameW) / 2).clamp(0.0, screenW);

                return Stack(
                  children: [
                    if (barH > 0) ...[
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: barH,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: barH,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                    ],
                    if (barW > 0) ...[
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: 0,
                        width: barW,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: barW,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                    ],
                    Center(
                      child: Container(
                        width: frameW,
                        height: frameH,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.amberAccent.withOpacity(0.45),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          if (options.showTelemetryHud)
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: const EdgeInsets.all(14),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.fiber_manual_record,
                        color: Colors.amber,
                        size: 10,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${isLandscape ? "LANDSCAPE" : "PORTRAIT"}  •  '
                        '${options.aspectRatio.label.toUpperCase()}  •  '
                        'LUT: ${activeToneName.toUpperCase()}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GridOverlayPainter extends CustomPainter {
  final GridOverlayType gridType;

  _GridOverlayPainter({required this.gridType});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..strokeWidth = 0.9;

    if (gridType == GridOverlayType.ruleOfThirds) {
      for (int i = 1; i <= 2; i++) {
        final dx = size.width * (i / 3);
        final dy = size.height * (i / 3);
        canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
        canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
      }
    } else if (gridType == GridOverlayType.goldenRatio) {
      const phi = 0.382;
      const invPhi = 1 - phi;
      canvas.drawLine(Offset(size.width * phi, 0),
          Offset(size.width * phi, size.height), paint);
      canvas.drawLine(Offset(size.width * invPhi, 0),
          Offset(size.width * invPhi, size.height), paint);
      canvas.drawLine(Offset(0, size.height * phi),
          Offset(size.width, size.height * phi), paint);
      canvas.drawLine(Offset(0, size.height * invPhi),
          Offset(size.width, size.height * invPhi), paint);
    } else if (gridType == GridOverlayType.crosshair) {
      final cx = size.width / 2;
      final cy = size.height / 2;
      canvas.drawLine(Offset(cx - 24, cy), Offset(cx + 24, cy), paint);
      canvas.drawLine(Offset(cx, cy - 24), Offset(cx, cy + 24), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridOverlayPainter oldDelegate) {
    return oldDelegate.gridType != gridType;
  }
}
