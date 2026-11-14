import 'dart:typed_data';

import '../../features/cinema_camera/domain/entities/cinema_tone.dart';

enum MediaCaptureType { photo, video }

/// Extra payload used by the `/preview` route.
class CapturedPreviewArgs {
  final MediaCaptureType mediaType;
  final Uint8List? imageBytes;
  final String? imageFilePath;
  final String? videoFilePath;
  final CinemaTone tone;
  final double intensity;
  final bool isAnamorphic;

  const CapturedPreviewArgs.photo({
    required Uint8List this.imageBytes,
    required this.tone,
    required this.intensity,
    required this.isAnamorphic,
  })  : mediaType = MediaCaptureType.photo,
        imageFilePath = null,
        videoFilePath = null;

  /// Same as [CapturedPreviewArgs.photo] but reads the still from disk, which
  /// is what the gallery uses to avoid loading every capture into memory.
  const CapturedPreviewArgs.photoFile({
    required String this.imageFilePath,
    required this.tone,
    required this.intensity,
    required this.isAnamorphic,
  })  : mediaType = MediaCaptureType.photo,
        imageBytes = null,
        videoFilePath = null;

  const CapturedPreviewArgs.video({
    required String this.videoFilePath,
    required this.tone,
    required this.intensity,
    required this.isAnamorphic,
  })  : mediaType = MediaCaptureType.video,
        imageBytes = null,
        imageFilePath = null;
}
