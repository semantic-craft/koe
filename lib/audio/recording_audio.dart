import 'package:path/path.dart' as p;

/// What kind of audio a recording original is.
enum RecordingAudioKind {
  /// Bare fixed-size Opus frames retrieved from the recorder (`.opus`).
  deviceOpus,

  /// The recorder's raw byte stream that still needs decrypting
  /// (`.opus.bin`); it cannot be played or converted as it is.
  deviceRaw,

  /// A PCM WAV the app made from [deviceOpus], or one the user imported.
  wav,

  /// Any other audio the user imported (m4a, mp3, aac, flac, ogg); the player
  /// and the cloud services open these as they are.
  container,
}

/// The file family of one recording original: what kind of audio it is and
/// the paths of every file the app derives from it.
///
/// The kind comes from the name only. Callers that open the bytes still check
/// the header ([OggOpus.isOgg], [OggOpus.isWav]) because an imported `.opus`
/// may already be an Ogg container.
class RecordingAudio {
  RecordingAudio.of(this.path) : kind = _kindOf(path);

  final String path;
  final RecordingAudioKind kind;

  static RecordingAudioKind _kindOf(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.opus.bin')) return RecordingAudioKind.deviceRaw;
    if (lower.endsWith('.opus')) return RecordingAudioKind.deviceOpus;
    if (lower.endsWith('.wav')) return RecordingAudioKind.wav;
    return RecordingAudioKind.container;
  }

  /// The extension that identifies the kind, `.opus.bin` kept whole.
  String get extension => kind == RecordingAudioKind.deviceRaw
      ? '.opus.bin'
      : p.extension(path).toLowerCase();

  /// Recorder frames, encrypted or not: the only originals that need an Ogg
  /// wrapper or a WAV conversion before anything can read them.
  bool get isDeviceFrames =>
      kind == RecordingAudioKind.deviceOpus ||
      kind == RecordingAudioKind.deviceRaw;

  /// Path without the kind's extension: `/a/12.opus` → `/a/12`. For
  /// [RecordingAudioKind.deviceRaw] the whole path is kept, so derived files
  /// read `12.opus.bin.ogg` and never collide with the decrypted `12.opus`.
  String get _stem => kind == RecordingAudioKind.deviceOpus
      ? path.substring(0, path.length - '.opus'.length)
      : path;

  /// Where the Ogg wrapper for playback and upload is written.
  String get oggSidecar => '$_stem.ogg';

  /// Where the WAV converted from device frames is written.
  String get convertedWav => '$_stem.wav';

  /// For a converted WAV, the device frames it was made from (which may not
  /// exist); null for every other kind.
  String? get framesForWav => kind == RecordingAudioKind.wav
      ? '${path.substring(0, path.length - '.wav'.length)}.opus'
      : null;

  /// Every file that can belong to device recording [id] next to this
  /// original: the original kinds, their converted WAV and Ogg wrappers.
  /// Used when the whole recording is removed.
  Set<String> familyFor(int id) {
    final directory = p.dirname(path);
    final originals = {
      path,
      p.join(directory, '$id.wav'),
      p.join(directory, '$id.opus'),
      p.join(directory, '$id.ogg'),
      p.join(directory, '$id.opus.bin'),
    };
    return {
      for (final original in originals) ...{
        original,
        RecordingAudio.of(original).oggSidecar,
      },
    };
  }

  /// Device frames for recording [id] that a playback cache can be rebuilt
  /// from; any one existing is enough.
  List<String> rebuildSourcesFor(int id) {
    final directory = p.dirname(path);
    return [
      if (isDeviceFrames) path,
      p.join(directory, '$id.opus'),
      p.join(directory, '$id.opus.bin'),
    ];
  }

  /// Converted WAVs and Ogg wrappers for recording [id] that can be deleted
  /// and made again; never the original itself.
  Set<String> rebuildableCacheFor(int id) {
    final directory = p.dirname(path);
    return {
      p.join(directory, '$id.wav'),
      p.join(directory, '$id.ogg'),
      '$path.ogg',
      oggSidecar,
    }..remove(path);
  }
}
