// lib/features/photo_editor/data/edit_clipboard_store.dart

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../cinema_camera/domain/entities/film_look.dart';
import '../domain/entities/photo_edit.dart';

/// Snapshot copied via Lightroom-style "Copy Settings" and pasted onto another
/// photo or video in the gallery.
class CopiedEditSettings {
  final PhotoEdit edit;
  final String toneId;
  final double toneIntensity;
  final bool stockEffects;
  final FilmLook film;

  const CopiedEditSettings({
    required this.edit,
    required this.toneId,
    required this.toneIntensity,
    required this.stockEffects,
    required this.film,
  });
}

/// Holds the in-session Copy/Paste edit clipboard and persists user-created
/// Lightroom edit presets in [SharedPreferences].
class EditClipboardStore {
  EditClipboardStore._();

  static const String _prefPresetsKey = 'cinelens_editor_saved_presets_v1';

  static CopiedEditSettings? _clipboard;

  static CopiedEditSettings? get clipboard => _clipboard;
  static bool get hasClipboard => _clipboard != null;

  static void copy(CopiedEditSettings settings) {
    _clipboard = settings;
  }

  static Future<List<SavedEditPreset>> loadPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefPresetsKey);
    if (raw == null || raw.isEmpty) return const <SavedEditPreset>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <SavedEditPreset>[];
      return decoded
          .map(SavedEditPreset.tryParse)
          .whereType<SavedEditPreset>()
          .toList();
    } catch (_) {
      return const <SavedEditPreset>[];
    }
  }

  static Future<List<SavedEditPreset>> savePreset(SavedEditPreset preset) async {
    final existing = await loadPresets();
    final updated = <SavedEditPreset>[
      preset,
      ...existing.where((p) => p.id != preset.id),
    ];
    await _persist(updated);
    return updated;
  }

  static Future<List<SavedEditPreset>> deletePreset(String id) async {
    final existing = await loadPresets();
    final updated = existing.where((p) => p.id != id).toList();
    await _persist(updated);
    return updated;
  }

  static Future<void> _persist(List<SavedEditPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefPresetsKey,
      jsonEncode(presets.map((p) => p.toJson()).toList()),
    );
  }
}
