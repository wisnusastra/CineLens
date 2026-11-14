// Tambahkan di bagian import atas camera_screen.dart:
import '../../../options/presentation/widgets/camera_options_sheet.dart';
import '../../../options/presentation/widgets/cinematic_viewfinder_overlay.dart';

// Tambahkan di dalam children: [ ... ] milik Stack layar kamera Anda:
CinematicViewfinderOverlay(
  activeToneName: selectedTone.name, // Sesuaikan dengan variabel preset aktif Anda
),
const SafeArea(
  child: Align(
    alignment: Alignment.topRight,
    child: Padding(
      padding: EdgeInsets.all(14),
      child: CameraOptionsButton(),
    ),
  ),
),
