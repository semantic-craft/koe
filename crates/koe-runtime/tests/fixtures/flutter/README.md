# Flutter migration fixtures

Synthetic, non-personal data follows the serializers at `b43b092`:

- `lib/state/recording_library.dart:179` and `:319` define version 1 assets.
- `lib/state/transcript_store.dart:479` defines version 4 transcript maps, manual/incoming versions and speaker overrides.
- `lib/state/recording_analysis.dart:410` and `:1225` define current, previous and historical analysis results.
- `lib/state/context/context_file.dart:39` and `lib/state/recorder/library.dart:83` define the AnkerRecorder root and exports/imports layout.
- `lib/state/recorder/library.dart:355` uses microsecond prefixes for local imports; `lib/state/export_catalog.dart:15` derives the full numeric key.
- `lib/audio/recording_audio.dart:7` distinguishes bare device Opus frames from Ogg containers.
- `lib/ai/stt_types.dart:78` applies speaker aliases only at canonical line starts.

`legacy_restore.rs` creates valid PCM WAV and Opus bytes in isolated temporary directories, changes fixture fields for failure cases, imports through the production JSON command, and reopens ProductStore. No user files or credentials are used.
