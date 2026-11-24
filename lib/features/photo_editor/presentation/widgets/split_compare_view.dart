// lib/features/photo_editor/presentation/widgets/split_compare_view.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Draggable vertical Before / After split-screen comparator.
class SplitCompareView extends StatefulWidget {
  final Uint8List original;
  final Uint8List edited;

  const SplitCompareView({
    super.key,
    required this.original,
    required this.edited,
  });

  @override
  State<SplitCompareView> createState() => _SplitCompareViewState();
}

class _SplitCompareViewState extends State<SplitCompareView> {
  double _split = 0.5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(1.0, double.infinity);
        final dividerX = width * _split;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) {
            setState(() {
              _split = (details.localPosition.dx / width).clamp(0.05, 0.95);
            });
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Right side: Edited
              Image.memory(
                widget.edited,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
              // Left side: Original clipped at split
              ClipRect(
                clipper: _LeftClipper(_split),
                child: Image.memory(
                  widget.original,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
              // Vertical divider line
              Positioned(
                left: dividerX - 1,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: AppTheme.cinemaAmber,
                ),
              ),
              // Center drag handle
              Positioned(
                left: dividerX - 16,
                top: constraints.maxHeight / 2 - 16,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.cinemaAmber, width: 1.6),
                  ),
                  child: const Icon(
                    Icons.compare_arrows_rounded,
                    color: AppTheme.cinemaAmber,
                    size: 16,
                  ),
                ),
              ),
              // Badges
              Positioned(
                left: 10,
                top: 10,
                child: _badge('ASLI'),
              ),
              Positioned(
                right: 10,
                top: 10,
                child: _badge('EDIT'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _badge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 8,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  final double fraction;

  const _LeftClipper(this.fraction);

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(covariant _LeftClipper oldClipper) =>
      oldClipper.fraction != fraction;
}
