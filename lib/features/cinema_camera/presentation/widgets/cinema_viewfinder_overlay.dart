import 'package:flutter/material.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';

class CinemaViewfinderOverlay extends StatelessWidget {
  final bool isAnamorphicRatio;
  final bool showGrid;
  final bool isVideoMode;
  final bool isRecordingVideo;
  final Duration recordingDuration;
  final Offset? focusPoint;
  final String activeToneName;
  final String filmReference;

  const CinemaViewfinderOverlay({
    super.key,
    required this.isAnamorphicRatio,
    required this.showGrid,
    required this.isVideoMode,
    required this.isRecordingVideo,
    required this.recordingDuration,
    required this.focusPoint,
    required this.activeToneName,
    required this.filmReference,
  });

  String _formatTimecode(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final targetCinemaHeight = width / AppConstants.anamorphicAspectRatio;
          final barHeight = isAnamorphicRatio && height > targetCinemaHeight
              ? (height - targetCinemaHeight) / 2
              : 0.0;

          return Stack(
            children: [
              if (showGrid)
                CustomPaint(
                  size: Size(width, height),
                  painter: _RuleOfThirdsPainter(),
                ),

              AnimatedPositioned(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                top: 0,
                left: 0,
                right: 0,
                height: barHeight,
                child: Container(color: Colors.black.withValues(alpha: 0.92)),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                bottom: 0,
                left: 0,
                right: 0,
                height: barHeight,
                child: Container(color: Colors.black.withValues(alpha: 0.92)),
              ),

              Positioned(
                top: barHeight + 12,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppTheme.cinemaAmber.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: AppTheme.cinemaAmber,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$activeToneName  |  $filmReference',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (isVideoMode)
                Positioned(
                  top: barHeight + 12,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isRecordingVideo
                          ? const Color(0xFFD92D20).withValues(alpha: 0.9)
                          : Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isRecordingVideo
                            ? Colors.redAccent
                            : Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isRecordingVideo) ...[
                          const Icon(Icons.fiber_manual_record,
                              color: Colors.white, size: 10),
                          const SizedBox(width: 5),
                        ],
                        Text(
                          isRecordingVideo
                              ? 'REC ${_formatTimecode(recordingDuration)}'
                              : '24 FPS • 180°',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (focusPoint != null)
                Positioned(
                  left: focusPoint!.dx - 32,
                  top: focusPoint!.dy - 32,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppTheme.cinemaAmber, width: 1.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _RuleOfThirdsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 0.8;

    final thirdW = size.width / 3;
    final thirdH = size.height / 3;

    canvas.drawLine(Offset(thirdW, 0), Offset(thirdW, size.height), paint);
    canvas.drawLine(Offset(thirdW * 2, 0), Offset(thirdW * 2, size.height), paint);
    canvas.drawLine(Offset(0, thirdH), Offset(size.width, thirdH), paint);
    canvas.drawLine(Offset(0, thirdH * 2), Offset(size.width, thirdH * 2), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
