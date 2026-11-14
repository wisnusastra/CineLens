// lib/features/cinema_camera/presentation/screens/camera_screen.dart

import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:cinelens_ios/features/options/presentation/providers/camera_options_provider.dart';
import 'package:cinelens_ios/features/options/presentation/widgets/camera_options_sheet.dart';
import 'package:cinelens_ios/features/options/presentation/widgets/cinematic_viewfinder_overlay.dart';
import '../providers/cinema_camera_provider.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  FlashMode _flashMode = FlashMode.off;
  bool _isInitializing = true;
  String? _errorMessage;
  Offset? _focusPoint;
  Timer? _focusTimer;
  Timer? _recordTimer;
  int _recordSeconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _recordTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      final index = ref.read(cinemaCameraProvider).cameraIndex;
      if (_cameras.isNotEmpty) {
        _setupCameraController(_cameras[index % _cameras.length]);
      }
    }
  }

  Future<void> _initCameras() async {
    try {
      setState(() {
        _isInitializing = true;
        _errorMessage = null;
      });
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Kamera tidak ditemukan pada perangkat ini.';
        });
        return;
      }
      await _setupCameraController(_cameras.first);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = 'Gagal mengakses kamera: $e';
      });
    }
  }

  Future<void> _setupCameraController(CameraDescription description) async {
    final oldController = _controller;
    final newController = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    try {
      await oldController?.dispose();
      await newController.initialize();
      await newController.setFlashMode(_flashMode);

      if (!mounted) {
        await newController.dispose();
        return;
      }

      setState(() {
        _controller = newController;
        _isInitializing = false;
        _errorMessage = null;
      });
    } catch (e) {
      await newController.dispose();
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = 'Inisialisasi kamera gagal: $e';
      });
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    final cameraState = ref.read(cinemaCameraProvider);
    if (cameraState.isRecording) return;

    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;
    if (hapticEnabled) HapticFeedback.lightImpact();

    final nextIndex = (cameraState.cameraIndex + 1) % _cameras.length;
    ref.read(cinemaCameraProvider.notifier).setCameraIndex(nextIndex);

    setState(() => _isInitializing = true);
    await _setupCameraController(_cameras[nextIndex]);
  }

  Future<void> _cycleFlashMode() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;
    if (hapticEnabled) HapticFeedback.selectionClick();

    final nextMode = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      FlashMode.always => FlashMode.torch,
      FlashMode.torch => FlashMode.off,
    };

    try {
      await controller.setFlashMode(nextMode);
      setState(() => _flashMode = nextMode);
    } catch (_) {}
  }

  Future<void> _onTapToFocus(
    TapDownDetails details,
    BoxConstraints constraints,
  ) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final dx = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final dy =
        (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    try {
      await controller.setFocusPoint(Offset(dx, dy));
      await controller.setExposurePoint(Offset(dx, dy));
    } catch (_) {}

    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;
    if (hapticEnabled) HapticFeedback.selectionClick();

    _focusTimer?.cancel();
    setState(() => _focusPoint = details.localPosition);
    _focusTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  Future<void> _handleShutterPressed() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final cameraState = ref.read(cinemaCameraProvider);
    final notifier = ref.read(cinemaCameraProvider.notifier);
    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;

    if (hapticEnabled) HapticFeedback.mediumImpact();

    if (cameraState.isVideoMode) {
      if (cameraState.isRecording) {
        try {
          _recordTimer?.cancel();
          final XFile videoFile = await controller.stopVideoRecording();
          notifier.setRecording(false);
          setState(() => _recordSeconds = 0);

          await Gal.putVideo(videoFile.path);
          _showStatusToast('Video tersimpan ke Galeri');
        } catch (e) {
          notifier.setRecording(false);
          _showStatusToast('Gagal menyimpan video: $e', isError: true);
        }
      } else {
        try {
          await controller.startVideoRecording();
          notifier.setRecording(true);
          setState(() => _recordSeconds = 0);
          _recordTimer?.cancel();
          _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() => _recordSeconds++);
          });
        } catch (e) {
          _showStatusToast('Gagal mulai merekam: $e', isError: true);
        }
      }
      return;
    }

    if (cameraState.isCapturing) return;
    try {
      notifier.setCapturing(true);
      final XFile photoFile = await controller.takePicture();
      await Gal.putImage(photoFile.path);
      _showStatusToast('Foto (${cameraState.activeTone.name}) tersimpan');
    } catch (e) {
      _showStatusToast('Gagal memotret: $e', isError: true);
    } finally {
      notifier.setCapturing(false);
    }
  }

  void _showStatusToast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF232328),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  IconData get _flashIcon => switch (_flashMode) {
        FlashMode.off => Icons.flash_off_rounded,
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.always => Icons.flash_on_rounded,
        FlashMode.torch => Icons.highlight_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cinemaCameraProvider);
    final options = ref.watch(cameraOptionsProvider);
    final activeTone = cameraState.activeTone;

    return Scaffold(
      backgroundColor: Colors.black,
      body: OrientationBuilder(
        builder: (context, orientation) {
          final isLandscape = orientation == Orientation.landscape;

          return LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  // 1. Pratinjau Kamera Fullscreen Responsif + LUT Filter Real-Time
                  _buildCameraViewport(
                    isLandscape: isLandscape,
                    activeToneMatrix: activeTone.matrix,
                    constraints: constraints,
                  ),

                  // 2. Overlay Grid Komposisi, Rasio Sinematik, & HUD
                  CinematicViewfinderOverlay(
                    activeToneName: activeTone.name,
                  ),

                  // 3. Indikator Fokus Sentuh
                  if (_focusPoint != null)
                    Positioned(
                      left: _focusPoint!.dx - 32,
                      top: _focusPoint!.dy - 32,
                      child: IgnorePointer(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.amberAccent,
                              width: 1.6,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),

                  // 4. Indikator Timer Rekaman Video
                  if (cameraState.isRecording)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          margin: const EdgeInsets.only(top: 14),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.88),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.fiber_manual_record,
                                color: Colors.white,
                                size: 12,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'REC ${_formatDuration(_recordSeconds)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // 5. Tombol Flash & Option di Pojok Kanan Atas
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildCircleActionButton(
                              icon: _flashIcon,
                              color: _flashMode == FlashMode.off
                                  ? Colors.white70
                                  : Colors.amberAccent,
                              onTap: _cycleFlashMode,
                            ),
                            const SizedBox(width: 10),
                            const CameraOptionsButton(),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 6. Panel Kontrol LUT & Shutter (Adaptif Portrait & Landscape)
                  if (isLandscape)
                    _buildLandscapeControls(cameraState, options.hapticFeedback)
                  else
                    _buildPortraitControls(cameraState, options.hapticFeedback),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildCameraViewport({
    required bool isLandscape,
    required List<double> activeToneMatrix,
    required BoxConstraints constraints,
  }) {
    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.amberAccent),
      );
    }

    if (_errorMessage != null ||
        _controller == null ||
        !_controller!.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_rounded,
                color: Colors.white54,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage ?? 'Kamera belum siap.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                ),
                onPressed: _initCameras,
                child: const Text('Coba Lagi'),
              ),
            ],
          ),
        ),
      );
    }

    final previewSize =
        _controller!.value.previewSize ?? const Size(1920, 1080);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _onTapToFocus(details, constraints),
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(activeToneMatrix),
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: isLandscape ? previewSize.width : previewSize.height,
              height: isLandscape ? previewSize.height : previewSize.width,
              child: CameraPreview(_controller!),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitControls(
    CinemaCameraState cameraState,
    bool hapticEnabled,
  ) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withOpacity(0.85),
                Colors.black.withOpacity(0.35),
                Colors.transparent,
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pemilih Preset LUT Horizontal
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: cameraState.presets.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final preset = cameraState.presets[index];
                    final selected = index == cameraState.selectedToneIndex;
                    return GestureDetector(
                      onTap: () {
                        if (hapticEnabled) HapticFeedback.selectionClick();
                        ref
                            .read(cinemaCameraProvider.notifier)
                            .selectTone(index);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.amber
                              : Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected ? Colors.amber : Colors.white24,
                          ),
                        ),
                        child: Text(
                          preset.name,
                          style: TextStyle(
                            color: selected ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),

              // Switch Mode Foto / Video
              _buildModeSwitcher(cameraState, hapticEnabled),
              const SizedBox(height: 16),

              // Baris Shutter & Ganti Kamera
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  const SizedBox(width: 48),
                  _buildShutterButton(cameraState),
                  _buildCircleActionButton(
                    icon: Icons.cameraswitch_rounded,
                    color: Colors.white,
                    size: 24,
                    onTap: _switchCamera,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeControls(
    CinemaCameraState cameraState,
    bool hapticEnabled,
  ) {
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          width: 190,
          margin: const EdgeInsets.only(top: 52, right: 8, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.62),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              // Daftar LUT Vertikal di Sisi Kiri Panel
              Expanded(
                child: ListView.separated(
                  itemCount: cameraState.presets.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final preset = cameraState.presets[index];
                    final selected = index == cameraState.selectedToneIndex;
                    return GestureDetector(
                      onTap: () {
                        if (hapticEnabled) HapticFeedback.selectionClick();
                        ref
                            .read(cinemaCameraProvider.notifier)
                            .selectTone(index);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.amber
                              : Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          preset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),

              // Kolom Tombol Switch Kamera, Shutter, & Mode Foto/Video
              Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildCircleActionButton(
                    icon: Icons.cameraswitch_rounded,
                    color: Colors.white,
                    size: 20,
                    onTap: _switchCamera,
                  ),
                  _buildShutterButton(cameraState, diameter: 64),
                  GestureDetector(
                    onTap: () {
                      if (hapticEnabled) HapticFeedback.selectionClick();
                      ref
                          .read(cinemaCameraProvider.notifier)
                          .setVideoMode(!cameraState.isVideoMode);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        cameraState.isVideoMode ? 'VIDEO' : 'FOTO',
                        style: const TextStyle(
                          color: Colors.amberAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeSwitcher(
    CinemaCameraState cameraState,
    bool hapticEnabled,
  ) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeChip(
            label: 'FOTO',
            selected: !cameraState.isVideoMode,
            onTap: () {
              if (hapticEnabled) HapticFeedback.selectionClick();
              ref.read(cinemaCameraProvider.notifier).setVideoMode(false);
            },
          ),
          _buildModeChip(
            label: 'VIDEO',
            selected: cameraState.isVideoMode,
            onTap: () {
              if (hapticEnabled) HapticFeedback.selectionClick();
              ref.read(cinemaCameraProvider.notifier).setVideoMode(true);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildModeChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.amber : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildShutterButton(
    CinemaCameraState cameraState, {
    double diameter = 74,
  }) {
    final isVideo = cameraState.isVideoMode;
    final isRecording = cameraState.isRecording;

    return GestureDetector(
      onTap: _handleShutterPressed,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: isRecording ? diameter * 0.42 : diameter * 0.78,
            height: isRecording ? diameter * 0.42 : diameter * 0.78,
            decoration: BoxDecoration(
              color: isVideo ? Colors.redAccent : Colors.white,
              borderRadius: BorderRadius.circular(
                isRecording ? 8 : diameter,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCircleActionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    double size = 22,
  }) {
    return Material(
      color: Colors.black.withOpacity(0.55),
      shape: const CircleBorder(
        side: BorderSide(color: Colors.white24, width: 1),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }
}
