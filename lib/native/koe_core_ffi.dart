import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import '../crypto/device_crypto.dart';
import '../protocol/models.dart';

final class _KoeDeviceInfoNative extends Struct {
  @Int32()
  external int connectStatus;

  @Int32()
  external int battery;

  @Uint8()
  external int charging;

  @Int32()
  external int boxBattery;

  @Uint8()
  external int boxCharging;

  @Uint8()
  external int recordingStatus;

  @Uint8()
  external int hasMemory;

  @Uint32()
  external int totalMemoryKb;

  @Uint32()
  external int freeMemoryKb;

  @Array(16)
  external Array<Uint8> firmwareVersion;

  @Array(32)
  external Array<Uint8> serialNumber;

  @Array(24)
  external Array<Uint8> boxMac;

  @Array(16)
  external Array<Uint8> boxFirmware;

  @Array(16)
  external Array<Uint8> wifiFirmware;
}

final class _KoeOfflineFileEntryNative extends Struct {
  @Uint32()
  external int fileId;

  @Uint32()
  external int durationMs;

  @Uint8()
  external int hasEndTime;

  @Array(3)
  external Array<Uint8> reserved;

  @Uint32()
  external int endTime;
}

final class _KoeOfflineFileListHeaderNative extends Struct {
  @Uint16()
  external int fileCount;

  @Uint16()
  external int parsedEntries;

  @Uint8()
  external int hasTransportState;

  @Array(3)
  external Array<Uint8> reserved;

  @Uint32()
  external int currentTransportTimestamp;

  @Uint32()
  external int currentTransportDuration;
}

final class _KoeSliceMarkTransitionNative extends Struct {
  @Uint8()
  external int cmdId;

  @Uint8()
  external int flags;

  @Array(2)
  external Array<Uint8> reserved;

  @Uint32()
  external int sequence;
}

final class _KoeAudioFileHeadNative extends Struct {
  @Uint32()
  external int fileId;

  @Uint32()
  external int fileSize;

  @Uint8()
  external int errorCode;

  @Uint8()
  external int unfinished;

  @Uint8()
  external int hasFileKey;

  @Uint8()
  external int reserved;

  @Array(16)
  external Array<Uint8> nonce;

  @Array(46)
  external Array<Uint8> encryptedFileKey;

  @Array(16)
  external Array<Uint8> sessionNonce;

  @Array(32)
  external Array<Uint8> fileKey;
}

class KoeParsedFileHead {
  const KoeParsedFileHead({
    required this.secret,
    required this.unfinished,
    this.fileKey,
  });

  final AudioFileSecretKey secret;
  final bool unfinished;
  final Uint8List? fileKey;
}

class KoeUnpackedSliceBatch {
  const KoeUnpackedSliceBatch({
    required this.opusBytes,
    required this.markedSequences,
    required this.sliceCount,
  });

  final Uint8List opusBytes;
  final List<int> markedSequences;
  final int sliceCount;

  int get wireRecordBytes => sliceCount * 166;
}

final class _KoeWifiEndpointNative extends Struct {
  @Array(4)
  external Array<Uint8> ip;

  @Uint16()
  external int port;

  @Array(2)
  external Array<Uint8> reserved;
}

class KoeWifiEndpoint {
  const KoeWifiEndpoint({
    required this.ip,
    required this.port,
  });

  final String ip;
  final int port;
}

final class _KoeUtteranceSpineSnapshotNative extends Struct {
  @Uint32()
  external int segmentCount;

  @Uint8()
  external int isStale;

  @Array(3)
  external Array<Uint8> reserved;

  @Uint64()
  external int revision;
}

final class _KoeUtteranceSegmentHeaderNative extends Struct {
  @Uint32()
  external int ordinal;

  @Uint32()
  external int revision;

  @Uint64()
  external int startMs;

  @Uint64()
  external int endMs;

  @Uint8()
  external int isFinal;

  @Uint8()
  external int hasTranslation;

  @Array(2)
  external Array<Uint8> reserved;

  @Uint32()
  external int textLen;

  @Uint32()
  external int translationLen;

  @Array(16)
  external Array<Uint8> sourceLanguage;

  @Array(16)
  external Array<Uint8> targetLanguage;
}

class KoeUtteranceSpineSnapshot {
  const KoeUtteranceSpineSnapshot({
    required this.segmentCount,
    required this.revision,
    required this.isStale,
  });

  final int segmentCount;
  final int revision;
  final bool isStale;
}

class KoeUtteranceSegment {
  const KoeUtteranceSegment({
    required this.ordinal,
    required this.revision,
    required this.startMs,
    required this.endMs,
    required this.isFinal,
    required this.text,
    this.translation,
    required this.sourceLanguage,
    this.targetLanguage,
  });

  final int ordinal;
  final int revision;
  final int startMs;
  final int endMs;
  final bool isFinal;
  final String text;
  final String? translation;
  final String sourceLanguage;
  final String? targetLanguage;

  String get citationId => 'S$ordinal';
}

final class _KoeCicadaRollingStatusNative extends Struct {
  @Uint8()
  external int paused;

  @Uint8()
  external int closed;

  @Uint8()
  external int edited;

  @Uint8()
  external int hasCandidate;

  @Uint8()
  external int requestStatus;

  @Array(3)
  external Array<Uint8> reserved;

  @Uint32()
  external int watermark;

  @Uint32()
  external int callsThisHour;

  @Uint64()
  external int generation;
}

class KoeCicadaRollingStatus {
  const KoeCicadaRollingStatus({
    required this.paused,
    required this.closed,
    required this.edited,
    required this.hasCandidate,
    required this.requestStatus,
    required this.watermark,
    required this.callsThisHour,
    required this.generation,
  });

  final bool paused;
  final bool closed;
  final bool edited;
  final bool hasCandidate;
  final int requestStatus;
  final int watermark;
  final int callsThisHour;
  final int generation;
}

class KoeCicadaRollingTicket {
  const KoeCicadaRollingTicket({
    required this.fromIndex,
    required this.endIndex,
    required this.generation,
    required this.payload,
  });

  final int fromIndex;
  final int endIndex;
  final int generation;
  final String payload;
}

typedef _ChecksumNative = Uint8 Function(Pointer<Uint8>, Size);
typedef _ChecksumDart = int Function(Pointer<Uint8>, int);

typedef _EncodeNative = Size Function(
  Uint8,
  Uint8,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _EncodeDart = int Function(
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _BatteryRemainingNative = Int32 Function(Int32);
typedef _BatteryRemainingDart = int Function(int);

typedef _DeviceInfoParseNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<_KoeDeviceInfoNative>,
);
typedef _DeviceInfoParseDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<_KoeDeviceInfoNative>,
);

typedef _OfflineFileListParseNative = Size Function(
  Pointer<Uint8>,
  Size,
  Uint8,
  Pointer<_KoeOfflineFileListHeaderNative>,
  Pointer<_KoeOfflineFileEntryNative>,
  Size,
);
typedef _OfflineFileListParseDart = int Function(
  Pointer<Uint8>,
  int,
  int,
  Pointer<_KoeOfflineFileListHeaderNative>,
  Pointer<_KoeOfflineFileEntryNative>,
  int,
);

typedef _SliceMarkInspectNative = Size Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<_KoeSliceMarkTransitionNative>,
  Size,
);
typedef _SliceMarkInspectDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<_KoeSliceMarkTransitionNative>,
  int,
);

typedef _ParseFileHeadNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<_KoeAudioFileHeadNative>,
);
typedef _ParseFileHeadDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<_KoeAudioFileHeadNative>,
);

typedef _UnpackSlicesNative = Size Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint32>,
  Size,
  Pointer<Size>,
);
typedef _UnpackSlicesDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  int,
  Pointer<Size>,
);

typedef _HkdfNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _HkdfDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _AesCtrNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _AesCtrDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _DecryptChunksNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Uint32,
);
typedef _DecryptChunksDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);

typedef _OggCrcNative = Uint32 Function(Pointer<Uint8>, Size);
typedef _OggCrcDart = int Function(Pointer<Uint8>, int);

typedef _OggMuxNative = Pointer<Uint8> Function(
  Pointer<Uint8>,
  Size,
  Pointer<Size>,
);
typedef _OggMuxDart = Pointer<Uint8> Function(
  Pointer<Uint8>,
  int,
  Pointer<Size>,
);

typedef _BufferFreeNative = Void Function(Pointer<Uint8>, Size);
typedef _BufferFreeDart = void Function(Pointer<Uint8>, int);

typedef _WavHeaderNative = Int32 Function(Uint32, Pointer<Uint8>);
typedef _WavHeaderDart = int Function(int, Pointer<Uint8>);

typedef _OpusDecodePcm16Native = Pointer<Uint8> Function(
  Pointer<Uint8>,
  Size,
  Uint32,
  Pointer<Size>,
);
typedef _OpusDecodePcm16Dart = Pointer<Uint8> Function(
  Pointer<Uint8>,
  int,
  int,
  Pointer<Size>,
);

typedef _OpusDecodeWavNative = Pointer<Uint8> Function(
  Pointer<Uint8>,
  Size,
  Uint32,
  Pointer<Uint64>,
  Size,
  Pointer<Size>,
);
typedef _OpusDecodeWavDart = Pointer<Uint8> Function(
  Pointer<Uint8>,
  int,
  int,
  Pointer<Uint64>,
  int,
  Pointer<Size>,
);

typedef _WifiParseConfigNative = Uint8 Function(
  Pointer<Uint8>,
  Size,
  Pointer<_KoeWifiEndpointNative>,
);
typedef _WifiParseConfigDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<_KoeWifiEndpointNative>,
);

typedef _WifiSharesSubnetNative = Uint8 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _WifiSharesSubnetDart = int Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
);

typedef _WifiBuildFileRequestHexNative = Size Function(
  Uint32,
  Uint32,
  Pointer<Uint8>,
  Size,
);
typedef _WifiBuildFileRequestHexDart = int Function(
  int,
  int,
  Pointer<Uint8>,
  int,
);

typedef _WifiOutBufNative = Size Function(
  Pointer<Uint8>,
  Size,
);
typedef _WifiOutBufDart = int Function(
  Pointer<Uint8>,
  int,
);

typedef _SpineNewNative = Uint64 Function(Pointer<Uint8>, Size);
typedef _SpineNewDart = int Function(Pointer<Uint8>, int);

typedef _SpineHandleVoidNative = Void Function(Uint64);
typedef _SpineHandleVoidDart = void Function(int);

typedef _SpineSnapshotNative = Int32 Function(
  Uint64,
  Pointer<_KoeUtteranceSpineSnapshotNative>,
);
typedef _SpineSnapshotDart = int Function(
  int,
  Pointer<_KoeUtteranceSpineSnapshotNative>,
);

typedef _SpineAppendSegmentNative = Uint32 Function(
  Uint64,
  Pointer<Uint8>,
  Size,
  Uint64,
  Uint64,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _SpineAppendSegmentDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _SpineAcceptCumulativeNative = Uint32 Function(
  Uint64,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _SpineAcceptCumulativeDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _SpineUpdateSegmentTextNative = Uint8 Function(
  Uint64,
  Uint32,
  Pointer<Uint8>,
  Size,
);
typedef _SpineUpdateSegmentTextDart = int Function(
  int,
  int,
  Pointer<Uint8>,
  int,
);

typedef _SpineSetTranslationNative = Uint8 Function(
  Uint64,
  Uint32,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _SpineSetTranslationDart = int Function(
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _SpineGetSegmentNative = Uint8 Function(
  Uint64,
  Uint32,
  Pointer<_KoeUtteranceSegmentHeaderNative>,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _SpineGetSegmentDart = int Function(
  int,
  int,
  Pointer<_KoeUtteranceSegmentHeaderNative>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _SpineFormatCitedSourcesNative = Pointer<Uint8> Function(
  Uint64,
  Pointer<Size>,
);
typedef _SpineFormatCitedSourcesDart = Pointer<Uint8> Function(
  int,
  Pointer<Size>,
);

typedef _MinutesValidateClaimGroundingNative = Uint8 Function(
  Uint64,
  Pointer<Uint8>,
  Size,
  Pointer<Uint32>,
  Size,
);
typedef _MinutesValidateClaimGroundingDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  int,
);

typedef _MinutesValidateJsonNative = Int32 Function(
  Uint64,
  Pointer<Uint8>,
  Size,
);
typedef _MinutesValidateJsonDart = int Function(
  int,
  Pointer<Uint8>,
  int,
);

typedef _MinutesReplaceTermsUtf8Native = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _MinutesReplaceTermsUtf8Dart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

typedef _MinutesPlanBatchesCountNative = Int32 Function(Uint64, Uint32);
typedef _MinutesPlanBatchesCountDart = int Function(int, int);

typedef _QwenParseTranscriptNative = Int32 Function(
  Uint64,
  Pointer<Uint8>,
  Size,
);
typedef _QwenParseTranscriptDart = int Function(
  int,
  Pointer<Uint8>,
  int,
);

typedef _CicadaRollingNewNative = Uint64 Function(Pointer<Uint8>, Size);
typedef _CicadaRollingNewDart = int Function(Pointer<Uint8>, int);

typedef _CicadaRollingFreeNative = Void Function(Uint64);
typedef _CicadaRollingFreeDart = void Function(int);

typedef _CicadaRollingAddSegmentNative = Uint8 Function(
  Uint64,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Uint64,
);
typedef _CicadaRollingAddSegmentDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);

typedef _CicadaRollingPollTickNative = Pointer<Uint8> Function(
  Uint64,
  Uint64,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint64>,
  Pointer<Size>,
);
typedef _CicadaRollingPollTickDart = Pointer<Uint8> Function(
  int,
  int,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint64>,
  Pointer<Size>,
);

typedef _CicadaRollingCompleteNative = Int32 Function(
  Uint64,
  Uint64,
  Uint32,
  Uint32,
  Pointer<Uint8>,
  Size,
);
typedef _CicadaRollingCompleteDart = int Function(
  int,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
);

typedef _CicadaRollingEditNative = Int32 Function(
  Uint64,
  Pointer<Uint8>,
  Size,
);
typedef _CicadaRollingEditDart = int Function(
  int,
  Pointer<Uint8>,
  int,
);

typedef _CicadaRollingAcceptCandidateNative = Uint8 Function(Uint64);
typedef _CicadaRollingAcceptCandidateDart = int Function(int);

typedef _CicadaRollingGetActiveNative = Pointer<Uint8> Function(
  Uint64,
  Pointer<Size>,
);
typedef _CicadaRollingGetActiveDart = Pointer<Uint8> Function(
  int,
  Pointer<Size>,
);

typedef _CicadaRollingStatusNative = Uint8 Function(
  Uint64,
  Pointer<_KoeCicadaRollingStatusNative>,
);
typedef _CicadaRollingStatusDart = int Function(
  int,
  Pointer<_KoeCicadaRollingStatusNative>,
);

typedef _CicadaSilenceReduceNative = Uint8 Function(
  Uint64,
  Uint64,
  Uint8,
  Uint8,
  Pointer<Uint64>,
  Pointer<Uint8>,
);
typedef _CicadaSilenceReduceDart = int Function(
  int,
  int,
  int,
  int,
  Pointer<Uint64>,
  Pointer<Uint8>,
);

typedef _KoepackVerifyV2Native = Int32 Function(Pointer<Uint8>, Size);
typedef _KoepackVerifyV2Dart = int Function(Pointer<Uint8>, int);

typedef _KoepackEncodeDemoV2Native = Pointer<Uint8> Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Size>,
);
typedef _KoepackEncodeDemoV2Dart = Pointer<Uint8> Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Size>,
);

/// Dart FFI bindings to the `#![forbid(unsafe_code)]` `koe_core` Rust kernel
/// exposed via `libkoe_core_ffi`.
final class KoeCoreFfi {
  KoeCoreFfi._(DynamicLibrary lib)
    : _checksum = lib.lookupFunction<_ChecksumNative, _ChecksumDart>(
        'koe_protocol_checksum',
        isLeaf: true,
      ),
      _encode = lib.lookupFunction<_EncodeNative, _EncodeDart>(
        'koe_protocol_encode',
        isLeaf: true,
      ),
      _batteryRemaining =
          lib.lookupFunction<_BatteryRemainingNative, _BatteryRemainingDart>(
            'koe_battery_remaining',
            isLeaf: true,
          ),
      _deviceInfoParsePacket =
          lib.lookupFunction<_DeviceInfoParseNative, _DeviceInfoParseDart>(
            'koe_device_info_parse_packet',
            isLeaf: true,
          ),
      _deviceInfoParsePayload =
          lib.lookupFunction<_DeviceInfoParseNative, _DeviceInfoParseDart>(
            'koe_device_info_parse_payload',
            isLeaf: true,
          ),
      _offlineFileListParse =
          lib.lookupFunction<
            _OfflineFileListParseNative,
            _OfflineFileListParseDart
          >('koe_offline_file_list_parse', isLeaf: true),
      _sliceMarkInspect =
          lib.lookupFunction<_SliceMarkInspectNative, _SliceMarkInspectDart>(
            'koe_slice_mark_inspect_transitions',
            isLeaf: true,
          ),
      _parseFileHead =
          lib.lookupFunction<_ParseFileHeadNative, _ParseFileHeadDart>(
            'koe_transport_parse_file_head',
            isLeaf: true,
          ),
      _unpackSlices =
          lib.lookupFunction<_UnpackSlicesNative, _UnpackSlicesDart>(
            'koe_transport_unpack_slices',
            isLeaf: true,
          ),
      _hkdf = lib.lookupFunction<_HkdfNative, _HkdfDart>(
        'koe_crypto_hkdf_sha256',
        isLeaf: true,
      ),
      _aesCtr = lib.lookupFunction<_AesCtrNative, _AesCtrDart>(
        'koe_crypto_aes_ctr_in_place',
        isLeaf: true,
      ),
      _decryptChunks =
          lib.lookupFunction<_DecryptChunksNative, _DecryptChunksDart>(
            'koe_crypto_decrypt_chunks_in_place',
            isLeaf: true,
          ),
      _oggCrc32 = lib.lookupFunction<_OggCrcNative, _OggCrcDart>(
        'koe_ogg_crc32',
        isLeaf: true,
      ),
      _oggMux = lib.lookupFunction<_OggMuxNative, _OggMuxDart>(
        'koe_ogg_opus_mux_raw_frames',
        isLeaf: true,
      ),
      _bufferFree = lib.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
        'koe_buffer_free',
        isLeaf: true,
      ),
      _wavHeader = lib.lookupFunction<_WavHeaderNative, _WavHeaderDart>(
        'koe_wav_header',
        isLeaf: true,
      ),
      _opusDecodePcm16 =
          lib.lookupFunction<_OpusDecodePcm16Native, _OpusDecodePcm16Dart>(
            'koe_opus_decode_pcm16',
            isLeaf: true,
          ),
      _opusDecodeWav =
          lib.lookupFunction<_OpusDecodeWavNative, _OpusDecodeWavDart>(
            'koe_opus_decode_wav',
            isLeaf: true,
          ),
      _wifiParseConfig =
          lib.lookupFunction<_WifiParseConfigNative, _WifiParseConfigDart>(
            'koe_wifi_parse_config_response',
            isLeaf: true,
          ),
      _wifiSharesSubnet =
          lib.lookupFunction<_WifiSharesSubnetNative, _WifiSharesSubnetDart>(
            'koe_wifi_shares_subnet',
            isLeaf: true,
          ),
      _wifiBuildFileRequestHex =
          lib.lookupFunction<
            _WifiBuildFileRequestHexNative,
            _WifiBuildFileRequestHexDart
          >('koe_wifi_build_file_request_hex', isLeaf: true),
      _wifiBuildTransferCompleteHex =
          lib.lookupFunction<_WifiOutBufNative, _WifiOutBufDart>(
            'koe_wifi_build_transfer_complete_hex',
            isLeaf: true,
          ),
      _wifiKeepalivePayload =
          lib.lookupFunction<_WifiOutBufNative, _WifiOutBufDart>(
            'koe_wifi_keepalive_payload',
            isLeaf: true,
          ),
      _spineNew = lib.lookupFunction<_SpineNewNative, _SpineNewDart>(
        'koe_spine_new',
        isLeaf: true,
      ),
      _spineFree =
          lib.lookupFunction<_SpineHandleVoidNative, _SpineHandleVoidDart>(
            'koe_spine_free',
            isLeaf: true,
          ),
      _spineClearStale =
          lib.lookupFunction<_SpineHandleVoidNative, _SpineHandleVoidDart>(
            'koe_spine_clear_stale',
            isLeaf: true,
          ),
      _spineSnapshot =
          lib.lookupFunction<_SpineSnapshotNative, _SpineSnapshotDart>(
            'koe_spine_snapshot',
            isLeaf: true,
          ),
      _spineAppendSegment =
          lib.lookupFunction<
            _SpineAppendSegmentNative,
            _SpineAppendSegmentDart
          >('koe_spine_append_segment', isLeaf: true),
      _spineAcceptCumulative =
          lib.lookupFunction<
            _SpineAcceptCumulativeNative,
            _SpineAcceptCumulativeDart
          >('koe_spine_accept_cumulative', isLeaf: true),
      _spineUpdateSegmentText =
          lib.lookupFunction<
            _SpineUpdateSegmentTextNative,
            _SpineUpdateSegmentTextDart
          >('koe_spine_update_segment_text', isLeaf: true),
      _spineSetTranslation =
          lib.lookupFunction<
            _SpineSetTranslationNative,
            _SpineSetTranslationDart
          >('koe_spine_set_translation', isLeaf: true),
      _spineGetSegment =
          lib.lookupFunction<_SpineGetSegmentNative, _SpineGetSegmentDart>(
            'koe_spine_get_segment',
            isLeaf: true,
          ),
      _spineFormatCitedSources =
          lib.lookupFunction<
            _SpineFormatCitedSourcesNative,
            _SpineFormatCitedSourcesDart
          >('koe_spine_format_cited_sources', isLeaf: true),
      _minutesValidateClaimGrounding =
          lib.lookupFunction<
            _MinutesValidateClaimGroundingNative,
            _MinutesValidateClaimGroundingDart
          >('koe_minutes_validate_claim_grounding', isLeaf: true),
      _minutesValidateJson =
          lib.lookupFunction<
            _MinutesValidateJsonNative,
            _MinutesValidateJsonDart
          >('koe_minutes_validate_json', isLeaf: true),
      _minutesReplaceTermsUtf8 =
          lib.lookupFunction<
            _MinutesReplaceTermsUtf8Native,
            _MinutesReplaceTermsUtf8Dart
          >('koe_minutes_replace_terms_utf8', isLeaf: true),
      _minutesPlanBatchesCount =
          lib.lookupFunction<
            _MinutesPlanBatchesCountNative,
            _MinutesPlanBatchesCountDart
          >('koe_minutes_plan_batches_count', isLeaf: true),
      _qwenParseTranscript =
          lib.lookupFunction<
            _QwenParseTranscriptNative,
            _QwenParseTranscriptDart
          >('koe_qwen_parse_transcript_into_spine', isLeaf: true),
      _cicadaRollingNew =
          lib.lookupFunction<_CicadaRollingNewNative, _CicadaRollingNewDart>(
            'koe_cicada_rolling_new',
            isLeaf: true,
          ),
      _cicadaRollingFree =
          lib.lookupFunction<_CicadaRollingFreeNative, _CicadaRollingFreeDart>(
            'koe_cicada_rolling_free',
            isLeaf: true,
          ),
      _cicadaRollingAddSegment =
          lib.lookupFunction<
            _CicadaRollingAddSegmentNative,
            _CicadaRollingAddSegmentDart
          >('koe_cicada_rolling_add_segment', isLeaf: true),
      _cicadaRollingPollTick =
          lib.lookupFunction<
            _CicadaRollingPollTickNative,
            _CicadaRollingPollTickDart
          >('koe_cicada_rolling_poll_tick', isLeaf: true),
      _cicadaRollingComplete =
          lib.lookupFunction<
            _CicadaRollingCompleteNative,
            _CicadaRollingCompleteDart
          >('koe_cicada_rolling_complete', isLeaf: true),
      _cicadaRollingEdit =
          lib.lookupFunction<_CicadaRollingEditNative, _CicadaRollingEditDart>(
            'koe_cicada_rolling_edit',
            isLeaf: true,
          ),
      _cicadaRollingAcceptCandidate =
          lib.lookupFunction<
            _CicadaRollingAcceptCandidateNative,
            _CicadaRollingAcceptCandidateDart
          >('koe_cicada_rolling_accept_candidate', isLeaf: true),
      _cicadaRollingGetActive =
          lib.lookupFunction<
            _CicadaRollingGetActiveNative,
            _CicadaRollingGetActiveDart
          >('koe_cicada_rolling_get_active', isLeaf: true),
      _cicadaRollingStatus =
          lib.lookupFunction<
            _CicadaRollingStatusNative,
            _CicadaRollingStatusDart
          >('koe_cicada_rolling_status', isLeaf: true),
      _cicadaSilenceReduce =
          lib.lookupFunction<
            _CicadaSilenceReduceNative,
            _CicadaSilenceReduceDart
          >('koe_cicada_silence_reduce', isLeaf: true),
      _koepackVerifyV2 =
          lib.lookupFunction<_KoepackVerifyV2Native, _KoepackVerifyV2Dart>(
            'koe_koepack_verify_v2',
            isLeaf: true,
          ),
      _koepackEncodeDemoV2 =
          lib.lookupFunction<
            _KoepackEncodeDemoV2Native,
            _KoepackEncodeDemoV2Dart
          >('koe_koepack_encode_demo_v2', isLeaf: true);

  static final KoeCoreFfi? instance = _load();

  bool get isAvailable => true;

  static KoeCoreFfi? _load() {
    for (final candidate in _candidateLibraries()) {
      try {
        return KoeCoreFfi._(candidate());
      } on Object {
        continue;
      }
    }
    return null;
  }

  static Iterable<DynamicLibrary Function()> _candidateLibraries() sync* {
    final envPath = Platform.environment['KOE_CORE_FFI_PATH'];
    if (envPath != null && envPath.isNotEmpty) {
      yield () => DynamicLibrary.open(envPath);
    }
    if (Platform.isMacOS || Platform.isIOS) {
      final execDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$execDir/../Frameworks/libkoe_core_ffi.dylib';
      if (File(bundled).existsSync()) {
        yield () => DynamicLibrary.open(bundled);
      }
      final cwd = Directory.current.path;
      for (final rel in [
        '$cwd/rust/target/release/libkoe_core_ffi.dylib',
        '$cwd/rust/target/debug/libkoe_core_ffi.dylib',
      ]) {
        if (File(rel).existsSync()) {
          yield () => DynamicLibrary.open(rel);
        }
      }
      yield DynamicLibrary.process;
    } else if (Platform.isAndroid || Platform.isLinux) {
      final cwd = Directory.current.path;
      for (final rel in [
        '$cwd/rust/target/release/libkoe_core_ffi.so',
        '$cwd/rust/target/debug/libkoe_core_ffi.so',
      ]) {
        if (File(rel).existsSync()) {
          yield () => DynamicLibrary.open(rel);
        }
      }
      yield () => DynamicLibrary.open('libkoe_core_ffi.so');
    }
  }

  final _ChecksumDart _checksum;
  final _EncodeDart _encode;
  final _BatteryRemainingDart _batteryRemaining;
  final _DeviceInfoParseDart _deviceInfoParsePacket;
  final _DeviceInfoParseDart _deviceInfoParsePayload;
  final _OfflineFileListParseDart _offlineFileListParse;
  final _SliceMarkInspectDart _sliceMarkInspect;
  final _ParseFileHeadDart _parseFileHead;
  final _UnpackSlicesDart _unpackSlices;
  final _HkdfDart _hkdf;
  final _AesCtrDart _aesCtr;
  final _DecryptChunksDart _decryptChunks;
  final _OggCrcDart _oggCrc32;
  final _OggMuxDart _oggMux;
  final _BufferFreeDart _bufferFree;
  final _WavHeaderDart _wavHeader;
  final _OpusDecodePcm16Dart _opusDecodePcm16;
  final _OpusDecodeWavDart _opusDecodeWav;
  final _WifiParseConfigDart _wifiParseConfig;
  final _WifiSharesSubnetDart _wifiSharesSubnet;
  final _WifiBuildFileRequestHexDart _wifiBuildFileRequestHex;
  final _WifiOutBufDart _wifiBuildTransferCompleteHex;
  final _WifiOutBufDart _wifiKeepalivePayload;
  final _SpineNewDart _spineNew;
  final _SpineHandleVoidDart _spineFree;
  final _SpineHandleVoidDart _spineClearStale;
  final _SpineSnapshotDart _spineSnapshot;
  final _SpineAppendSegmentDart _spineAppendSegment;
  final _SpineAcceptCumulativeDart _spineAcceptCumulative;
  final _SpineUpdateSegmentTextDart _spineUpdateSegmentText;
  final _SpineSetTranslationDart _spineSetTranslation;
  final _SpineGetSegmentDart _spineGetSegment;
  final _SpineFormatCitedSourcesDart _spineFormatCitedSources;
  final _MinutesValidateClaimGroundingDart _minutesValidateClaimGrounding;
  final _MinutesValidateJsonDart _minutesValidateJson;
  final _MinutesReplaceTermsUtf8Dart _minutesReplaceTermsUtf8;
  final _MinutesPlanBatchesCountDart _minutesPlanBatchesCount;
  final _QwenParseTranscriptDart _qwenParseTranscript;
  final _CicadaRollingNewDart _cicadaRollingNew;
  final _CicadaRollingFreeDart _cicadaRollingFree;
  final _CicadaRollingAddSegmentDart _cicadaRollingAddSegment;
  final _CicadaRollingPollTickDart _cicadaRollingPollTick;
  final _CicadaRollingCompleteDart _cicadaRollingComplete;
  final _CicadaRollingEditDart _cicadaRollingEdit;
  final _CicadaRollingAcceptCandidateDart _cicadaRollingAcceptCandidate;
  final _CicadaRollingGetActiveDart _cicadaRollingGetActive;
  final _CicadaRollingStatusDart _cicadaRollingStatus;
  final _CicadaSilenceReduceDart _cicadaSilenceReduce;
  final _KoepackVerifyV2Dart _koepackVerifyV2;
  final _KoepackEncodeDemoV2Dart _koepackEncodeDemoV2;

  int protocolChecksum(List<int> data) {
    if (data.isEmpty) return 0;
    final ptr = malloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _checksum(ptr, data.length);
    } finally {
      malloc.free(ptr);
    }
  }

  Uint8List protocolEncode({
    required int cmdType,
    required int cmdId,
    List<int> payload = const [],
  }) {
    final outCap = payload.length + 10;
    final payloadPtr = payload.isEmpty
        ? nullptr
        : malloc<Uint8>(payload.length);
    final outPtr = malloc<Uint8>(outCap);
    try {
      if (payload.isNotEmpty) {
        payloadPtr.asTypedList(payload.length).setAll(0, payload);
      }
      final written = _encode(
        cmdType & 0xFF,
        cmdId & 0xFF,
        payloadPtr,
        payload.length,
        outPtr,
        outCap,
      );
      return Uint8List.fromList(outPtr.asTypedList(written));
    } finally {
      if (payloadPtr != nullptr) malloc.free(payloadPtr);
      malloc.free(outPtr);
    }
  }

  int? batteryRemaining(int? raw) {
    if (raw == null) return null;
    final pct = _batteryRemaining(raw);
    return pct < 0 ? null : pct;
  }

  DeviceInfoModel parseDeviceInfoPacket(Uint8List raw, {String rawHex = ''}) {
    final rawPtr = raw.isEmpty ? nullptr : malloc<Uint8>(raw.length);
    final outPtr = calloc<_KoeDeviceInfoNative>(1);
    try {
      if (raw.isNotEmpty) rawPtr.asTypedList(raw.length).setAll(0, raw);
      _deviceInfoParsePacket(rawPtr, raw.length, outPtr);
      return _decodeDeviceInfo(outPtr.ref, rawHex);
    } finally {
      if (rawPtr != nullptr) malloc.free(rawPtr);
      calloc.free(outPtr);
    }
  }

  DeviceInfoModel parseDeviceInfoPayload(
    Uint8List payload, {
    String rawHex = '',
  }) {
    final payPtr = payload.isEmpty ? nullptr : malloc<Uint8>(payload.length);
    final outPtr = calloc<_KoeDeviceInfoNative>(1);
    try {
      if (payload.isNotEmpty) {
        payPtr.asTypedList(payload.length).setAll(0, payload);
      }
      _deviceInfoParsePayload(payPtr, payload.length, outPtr);
      return _decodeDeviceInfo(outPtr.ref, rawHex);
    } finally {
      if (payPtr != nullptr) malloc.free(payPtr);
      calloc.free(outPtr);
    }
  }

  OfflineFileList parseOfflineFileList(
    Uint8List payload, {
    bool withEndTime = false,
  }) {
    final payPtr = payload.isEmpty ? nullptr : malloc<Uint8>(payload.length);
    final hdrPtr = calloc<_KoeOfflineFileListHeaderNative>(1);
    Pointer<_KoeOfflineFileEntryNative> entriesPtr = nullptr;
    try {
      if (payload.isNotEmpty) {
        payPtr.asTypedList(payload.length).setAll(0, payload);
      }
      final flag = withEndTime ? 1 : 0;
      final total = _offlineFileListParse(
        payPtr,
        payload.length,
        flag,
        hdrPtr,
        nullptr,
        0,
      );
      final files = <OfflineFileEntry>[];
      if (total > 0) {
        entriesPtr = calloc<_KoeOfflineFileEntryNative>(total);
        _offlineFileListParse(
          payPtr,
          payload.length,
          flag,
          hdrPtr,
          entriesPtr,
          total,
        );
        for (var i = 0; i < total; i++) {
          final e = (entriesPtr + i).ref;
          files.add(
            OfflineFileEntry(
              fileId: e.fileId,
              durationMs: e.durationMs,
              endTime: e.hasEndTime != 0 ? e.endTime : null,
            ),
          );
        }
      }
      final hdr = hdrPtr.ref;
      return OfflineFileList(
        files: files,
        fileCount: hdr.fileCount,
        currentTransportTimestamp: hdr.hasTransportState != 0
            ? hdr.currentTransportTimestamp
            : null,
        currentTransportDuration: hdr.hasTransportState != 0
            ? hdr.currentTransportDuration
            : null,
      );
    } finally {
      if (payPtr != nullptr) malloc.free(payPtr);
      if (entriesPtr != nullptr) calloc.free(entriesPtr);
      calloc.free(hdrPtr);
    }
  }

  (int, int, List<(int, int, int)>) inspectSliceMarkTransitions({
    required Uint8List raw,
    required int lastCmdId,
    required int lastFlags,
  }) {
    if (raw.length < 10) return (lastCmdId, lastFlags, const []);
    final maxSlices = (raw.length ~/ 165) + 1;
    final rawPtr = malloc<Uint8>(raw.length);
    final cmdPtr = calloc<Uint8>(1);
    final flagsPtr = calloc<Uint8>(1);
    final outPtr = calloc<_KoeSliceMarkTransitionNative>(maxSlices);
    try {
      rawPtr.asTypedList(raw.length).setAll(0, raw);
      cmdPtr.value = lastCmdId & 0xFF;
      flagsPtr.value = lastFlags & 0xFF;
      final count = _sliceMarkInspect(
        rawPtr,
        raw.length,
        cmdPtr,
        flagsPtr,
        outPtr,
        maxSlices,
      );
      final list = <(int, int, int)>[];
      for (var i = 0; i < count; i++) {
        final t = (outPtr + i).ref;
        list.add((t.cmdId, t.sequence, t.flags));
      }
      return (cmdPtr.value, flagsPtr.value, list);
    } finally {
      malloc.free(rawPtr);
      calloc.free(cmdPtr);
      calloc.free(flagsPtr);
      calloc.free(outPtr);
    }
  }

  KoeParsedFileHead? parseFileHead(Uint8List raw, {Uint8List? sessionKey}) {
    if (raw.length < 97) return null;
    final rawPtr = malloc<Uint8>(raw.length);
    final skPtr = (sessionKey != null && sessionKey.isNotEmpty)
        ? malloc<Uint8>(sessionKey.length)
        : nullptr;
    final outPtr = calloc<_KoeAudioFileHeadNative>(1);
    try {
      rawPtr.asTypedList(raw.length).setAll(0, raw);
      if (skPtr != nullptr && sessionKey != null) {
        skPtr.asTypedList(sessionKey.length).setAll(0, sessionKey);
      }
      final ok = _parseFileHead(
        rawPtr,
        raw.length,
        skPtr,
        sessionKey?.length ?? 0,
        outPtr,
      );
      if (ok != 1) return null;
      final c = outPtr.ref;
      final secret = AudioFileSecretKey(
        fileId: c.fileId,
        fileSize: c.fileSize,
        nonce: _readFixedBytes(c.nonce, 16),
        encryptedFileKey: _readFixedBytes(c.encryptedFileKey, 46),
        sessionNonce: _readFixedBytes(c.sessionNonce, 16),
        errorCode: c.errorCode,
      );
      return KoeParsedFileHead(
        secret: secret,
        unfinished: c.unfinished != 0,
        fileKey: c.hasFileKey != 0 ? _readFixedBytes(c.fileKey, 32) : null,
      );
    } finally {
      malloc.free(rawPtr);
      if (skPtr != nullptr) malloc.free(skPtr);
      calloc.free(outPtr);
    }
  }

  KoeUnpackedSliceBatch unpackSlices(
    Uint8List frame, {
    Uint8List? fileKey,
    Uint8List? nonce,
  }) {
    if (frame.length < 174) {
      return KoeUnpackedSliceBatch(
        opusBytes: Uint8List(0),
        markedSequences: const [],
        sliceCount: 0,
      );
    }
    final maxSlices = (frame.length - 9) ~/ 165;
    final framePtr = malloc<Uint8>(frame.length);
    final fkPtr = (fileKey != null && fileKey.isNotEmpty)
        ? malloc<Uint8>(fileKey.length)
        : nullptr;
    final noncePtr = (nonce != null && nonce.isNotEmpty)
        ? malloc<Uint8>(nonce.length)
        : nullptr;
    final opusCap = maxSlices * 160;
    final opusPtr = malloc<Uint8>(opusCap);
    final marksPtr = calloc<Uint32>(maxSlices);
    final marksCountPtr = calloc<Size>(1);
    try {
      framePtr.asTypedList(frame.length).setAll(0, frame);
      if (fkPtr != nullptr && fileKey != null) {
        fkPtr.asTypedList(fileKey.length).setAll(0, fileKey);
      }
      if (noncePtr != nullptr && nonce != null) {
        noncePtr.asTypedList(nonce.length).setAll(0, nonce);
      }
      final sliceCount = _unpackSlices(
        framePtr,
        frame.length,
        fkPtr,
        fileKey?.length ?? 0,
        noncePtr,
        nonce?.length ?? 0,
        opusPtr,
        opusCap,
        marksPtr,
        maxSlices,
        marksCountPtr,
      );
      final marksCount = marksCountPtr.value;
      final marks = <int>[
        for (var i = 0; i < marksCount; i++) (marksPtr + i).value,
      ];
      return KoeUnpackedSliceBatch(
        opusBytes: Uint8List.fromList(opusPtr.asTypedList(sliceCount * 160)),
        markedSequences: marks,
        sliceCount: sliceCount,
      );
    } finally {
      malloc.free(framePtr);
      if (fkPtr != nullptr) malloc.free(fkPtr);
      if (noncePtr != nullptr) malloc.free(noncePtr);
      malloc.free(opusPtr);
      calloc.free(marksPtr);
      calloc.free(marksCountPtr);
    }
  }

  Uint8List hkdfSha256({
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) {
    final ikmPtr = malloc<Uint8>(ikm.isEmpty ? 1 : ikm.length);
    final saltPtr = malloc<Uint8>(salt.isEmpty ? 1 : salt.length);
    final infoPtr = malloc<Uint8>(info.isEmpty ? 1 : info.length);
    final outPtr = malloc<Uint8>(length);
    try {
      if (ikm.isNotEmpty) ikmPtr.asTypedList(ikm.length).setAll(0, ikm);
      if (salt.isNotEmpty) saltPtr.asTypedList(salt.length).setAll(0, salt);
      if (info.isNotEmpty) infoPtr.asTypedList(info.length).setAll(0, info);
      _hkdf(
        ikmPtr,
        ikm.length,
        saltPtr,
        salt.length,
        infoPtr,
        info.length,
        outPtr,
        length,
      );
      return Uint8List.fromList(outPtr.asTypedList(length));
    } finally {
      malloc.free(ikmPtr);
      malloc.free(saltPtr);
      malloc.free(infoPtr);
      malloc.free(outPtr);
    }
  }

  Uint8List? aesCtrDecrypt({
    required Uint8List data,
    required Uint8List key,
    required Uint8List iv,
  }) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      return null;
    }
    if (data.isEmpty) return Uint8List(0);
    final bufPtr = malloc<Uint8>(data.length);
    final keyPtr = malloc<Uint8>(key.length);
    final ivPtr = malloc<Uint8>(iv.isEmpty ? 1 : iv.length);
    try {
      bufPtr.asTypedList(data.length).setAll(0, data);
      keyPtr.asTypedList(key.length).setAll(0, key);
      if (iv.isNotEmpty) ivPtr.asTypedList(iv.length).setAll(0, iv);
      final ok = _aesCtr(
        bufPtr,
        data.length,
        keyPtr,
        key.length,
        ivPtr,
        iv.length,
      );
      if (ok != 1) return null;
      return Uint8List.fromList(bufPtr.asTypedList(data.length));
    } finally {
      malloc.free(bufPtr);
      malloc.free(keyPtr);
      malloc.free(ivPtr);
    }
  }

  Uint8List? decryptChunks({
    required Uint8List data,
    required Uint8List fileKey,
    required Uint8List nonce,
    required int startSequence,
  }) {
    if (data.isEmpty) return Uint8List(0);
    final bufPtr = malloc<Uint8>(data.length);
    final keyPtr = malloc<Uint8>(fileKey.length);
    final noncePtr = malloc<Uint8>(nonce.isEmpty ? 1 : nonce.length);
    try {
      bufPtr.asTypedList(data.length).setAll(0, data);
      keyPtr.asTypedList(fileKey.length).setAll(0, fileKey);
      if (nonce.isNotEmpty) noncePtr.asTypedList(nonce.length).setAll(0, nonce);
      final ok = _decryptChunks(
        bufPtr,
        data.length,
        keyPtr,
        fileKey.length,
        noncePtr,
        nonce.length,
        startSequence,
      );
      if (ok != 1) return null;
      return Uint8List.fromList(bufPtr.asTypedList(data.length));
    } finally {
      malloc.free(bufPtr);
      malloc.free(keyPtr);
      malloc.free(noncePtr);
    }
  }

  int oggCrc32(Uint8List data) {
    if (data.isEmpty) return 0;
    final ptr = malloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _oggCrc32(ptr, data.length);
    } finally {
      malloc.free(ptr);
    }
  }

  Uint8List oggOpusMuxRawFrames(Uint8List raw) {
    final rawPtr = malloc<Uint8>(raw.length);
    final outLenPtr = calloc<Size>(1);
    Pointer<Uint8> muxPtr = nullptr;
    var muxLen = 0;
    try {
      rawPtr.asTypedList(raw.length).setAll(0, raw);
      muxPtr = _oggMux(rawPtr, raw.length, outLenPtr);
      muxLen = outLenPtr.value;
      if (muxPtr == nullptr || muxLen == 0) {
        throw StateError('无音频数据');
      }
      return Uint8List.fromList(muxPtr.asTypedList(muxLen));
    } finally {
      if (muxPtr != nullptr && muxLen > 0) {
        _bufferFree(muxPtr, muxLen);
      }
      malloc.free(rawPtr);
      calloc.free(outLenPtr);
    }
  }

  Uint8List wavHeader(int pcmLength) {
    final outPtr = malloc<Uint8>(44);
    try {
      _wavHeader(pcmLength, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(44));
    } finally {
      malloc.free(outPtr);
    }
  }

  Uint8List? decodeOpusPcm16(Uint8List rawOpus, {int sampleRate = 16000}) {
    if (rawOpus.isEmpty) return null;
    final rawPtr = malloc<Uint8>(rawOpus.length);
    final outLenPtr = calloc<Size>(1);
    Pointer<Uint8> pcmPtr = nullptr;
    var pcmLen = 0;
    try {
      rawPtr.asTypedList(rawOpus.length).setAll(0, rawOpus);
      pcmPtr = _opusDecodePcm16(rawPtr, rawOpus.length, sampleRate, outLenPtr);
      pcmLen = outLenPtr.value;
      if (pcmPtr == nullptr || pcmLen == 0) return null;
      return Uint8List.fromList(pcmPtr.asTypedList(pcmLen));
    } finally {
      if (pcmPtr != nullptr && pcmLen > 0) {
        _bufferFree(pcmPtr, pcmLen);
      }
      malloc.free(rawPtr);
      calloc.free(outLenPtr);
    }
  }

  Uint8List? decodeOpusWav(
    Uint8List rawOpus, {
    int sampleRate = 48000,
    List<int> marksMs = const [],
  }) {
    if (rawOpus.isEmpty) return null;
    final rawPtr = malloc<Uint8>(rawOpus.length);
    final marksPtr = marksMs.isEmpty
        ? nullptr
        : calloc<Uint64>(marksMs.length);
    final outLenPtr = calloc<Size>(1);
    Pointer<Uint8> wavPtr = nullptr;
    var wavLen = 0;
    try {
      rawPtr.asTypedList(rawOpus.length).setAll(0, rawOpus);
      for (var i = 0; i < marksMs.length; i++) {
        (marksPtr + i).value = marksMs[i];
      }
      wavPtr = _opusDecodeWav(
        rawPtr,
        rawOpus.length,
        sampleRate,
        marksPtr,
        marksMs.length,
        outLenPtr,
      );
      wavLen = outLenPtr.value;
      if (wavPtr == nullptr || wavLen == 0) return null;
      return Uint8List.fromList(wavPtr.asTypedList(wavLen));
    } finally {
      if (wavPtr != nullptr && wavLen > 0) {
        _bufferFree(wavPtr, wavLen);
      }
      malloc.free(rawPtr);
      if (marksPtr != nullptr) calloc.free(marksPtr);
      calloc.free(outLenPtr);
    }
  }

  KoeWifiEndpoint? parseWifiConfigResponse(Uint8List raw) {
    if (raw.length < 15) return null;
    final rawPtr = malloc<Uint8>(raw.length);
    final outPtr = calloc<_KoeWifiEndpointNative>(1);
    try {
      rawPtr.asTypedList(raw.length).setAll(0, raw);
      final ok = _wifiParseConfig(rawPtr, raw.length, outPtr);
      if (ok == 0) return null;
      final ref = outPtr.ref;
      final ipStr =
          '${ref.ip[0]}.${ref.ip[1]}.${ref.ip[2]}.${ref.ip[3]}';
      return KoeWifiEndpoint(ip: ipStr, port: ref.port);
    } finally {
      malloc.free(rawPtr);
      calloc.free(outPtr);
    }
  }

  bool sharesIpv4Subnet(List<int> deviceIp, List<int> localIp) {
    if (deviceIp.length < 4 || localIp.length < 4) return false;
    final devPtr = malloc<Uint8>(4);
    final locPtr = malloc<Uint8>(4);
    try {
      for (var i = 0; i < 4; i++) {
        (devPtr + i).value = deviceIp[i] & 0xFF;
        (locPtr + i).value = localIp[i] & 0xFF;
      }
      return _wifiSharesSubnet(devPtr, locPtr) != 0;
    } finally {
      malloc.free(devPtr);
      malloc.free(locPtr);
    }
  }

  String buildWifiFileRequestHex({
    required int fileId,
    int alreadyTransferred = 0,
  }) {
    final outPtr = malloc<Uint8>(64);
    try {
      final len = _wifiBuildFileRequestHex(
        fileId,
        alreadyTransferred,
        outPtr,
        64,
      );
      return utf8.decode(outPtr.asTypedList(len));
    } finally {
      malloc.free(outPtr);
    }
  }

  String wifiTransferCompleteHex() {
    final outPtr = malloc<Uint8>(64);
    try {
      final len = _wifiBuildTransferCompleteHex(outPtr, 64);
      return utf8.decode(outPtr.asTypedList(len));
    } finally {
      malloc.free(outPtr);
    }
  }

  Uint8List wifiKeepalivePayload() {
    final outPtr = malloc<Uint8>(64);
    try {
      final len = _wifiKeepalivePayload(outPtr, 64);
      return Uint8List.fromList(outPtr.asTypedList(len));
    } finally {
      malloc.free(outPtr);
    }
  }

  int spineNew({String sessionId = 'default'}) {
    final bytes = utf8.encode(sessionId);
    final ptr = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      if (bytes.isNotEmpty) ptr.asTypedList(bytes.length).setAll(0, bytes);
      return _spineNew(ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  void spineFree(int handle) => _spineFree(handle);

  void spineClearStale(int handle) => _spineClearStale(handle);

  KoeUtteranceSpineSnapshot spineSnapshot(int handle) {
    final outPtr = calloc<_KoeUtteranceSpineSnapshotNative>(1);
    try {
      _spineSnapshot(handle, outPtr);
      final ref = outPtr.ref;
      return KoeUtteranceSpineSnapshot(
        segmentCount: ref.segmentCount,
        revision: ref.revision,
        isStale: ref.isStale != 0,
      );
    } finally {
      calloc.free(outPtr);
    }
  }

  int spineAppendSegment({
    required int handle,
    required String text,
    int startMs = 0,
    int endMs = 0,
    String sourceLanguage = 'zh',
    String provider = 'qwen',
  }) {
    final textBytes = utf8.encode(text);
    final langBytes = utf8.encode(sourceLanguage);
    final provBytes = utf8.encode(provider);
    final textPtr = malloc<Uint8>(textBytes.isEmpty ? 1 : textBytes.length);
    final langPtr = malloc<Uint8>(langBytes.isEmpty ? 1 : langBytes.length);
    final provPtr = malloc<Uint8>(provBytes.isEmpty ? 1 : provBytes.length);
    try {
      if (textBytes.isNotEmpty) {
        textPtr.asTypedList(textBytes.length).setAll(0, textBytes);
      }
      if (langBytes.isNotEmpty) {
        langPtr.asTypedList(langBytes.length).setAll(0, langBytes);
      }
      if (provBytes.isNotEmpty) {
        provPtr.asTypedList(provBytes.length).setAll(0, provBytes);
      }
      return _spineAppendSegment(
        handle,
        textPtr,
        textBytes.length,
        startMs,
        endMs,
        langPtr,
        langBytes.length,
        provPtr,
        provBytes.length,
      );
    } finally {
      malloc.free(textPtr);
      malloc.free(langPtr);
      malloc.free(provPtr);
    }
  }

  int spineAcceptCumulative({
    required int handle,
    required String connectionId,
    required String text,
    String sourceLanguage = 'zh',
    String? translation,
    String? targetLanguage,
    String provider = 'qwen',
  }) {
    final connBytes = utf8.encode(connectionId);
    final textBytes = utf8.encode(text);
    final langBytes = utf8.encode(sourceLanguage);
    final trBytes = utf8.encode(translation ?? '');
    final tlBytes = utf8.encode(targetLanguage ?? '');
    final provBytes = utf8.encode(provider);
    final connPtr = malloc<Uint8>(connBytes.isEmpty ? 1 : connBytes.length);
    final textPtr = malloc<Uint8>(textBytes.isEmpty ? 1 : textBytes.length);
    final langPtr = malloc<Uint8>(langBytes.isEmpty ? 1 : langBytes.length);
    final trPtr = malloc<Uint8>(trBytes.isEmpty ? 1 : trBytes.length);
    final tlPtr = malloc<Uint8>(tlBytes.isEmpty ? 1 : tlBytes.length);
    final provPtr = malloc<Uint8>(provBytes.isEmpty ? 1 : provBytes.length);
    try {
      if (connBytes.isNotEmpty) {
        connPtr.asTypedList(connBytes.length).setAll(0, connBytes);
      }
      if (textBytes.isNotEmpty) {
        textPtr.asTypedList(textBytes.length).setAll(0, textBytes);
      }
      if (langBytes.isNotEmpty) {
        langPtr.asTypedList(langBytes.length).setAll(0, langBytes);
      }
      if (trBytes.isNotEmpty) {
        trPtr.asTypedList(trBytes.length).setAll(0, trBytes);
      }
      if (tlBytes.isNotEmpty) {
        tlPtr.asTypedList(tlBytes.length).setAll(0, tlBytes);
      }
      if (provBytes.isNotEmpty) {
        provPtr.asTypedList(provBytes.length).setAll(0, provBytes);
      }
      return _spineAcceptCumulative(
        handle,
        connPtr,
        connBytes.length,
        textPtr,
        textBytes.length,
        langPtr,
        langBytes.length,
        trPtr,
        trBytes.length,
        tlPtr,
        tlBytes.length,
        provPtr,
        provBytes.length,
      );
    } finally {
      malloc.free(connPtr);
      malloc.free(textPtr);
      malloc.free(langPtr);
      malloc.free(trPtr);
      malloc.free(tlPtr);
      malloc.free(provPtr);
    }
  }

  bool spineUpdateSegmentText({
    required int handle,
    required int ordinal,
    required String newText,
  }) {
    final bytes = utf8.encode(newText);
    final ptr = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      if (bytes.isNotEmpty) ptr.asTypedList(bytes.length).setAll(0, bytes);
      return _spineUpdateSegmentText(handle, ordinal, ptr, bytes.length) != 0;
    } finally {
      malloc.free(ptr);
    }
  }

  bool spineSetTranslation({
    required int handle,
    required int ordinal,
    required String translation,
    String targetLanguage = 'en',
  }) {
    final trBytes = utf8.encode(translation);
    final tlBytes = utf8.encode(targetLanguage);
    final trPtr = malloc<Uint8>(trBytes.isEmpty ? 1 : trBytes.length);
    final tlPtr = malloc<Uint8>(tlBytes.isEmpty ? 1 : tlBytes.length);
    try {
      if (trBytes.isNotEmpty) trPtr.asTypedList(trBytes.length).setAll(0, trBytes);
      if (tlBytes.isNotEmpty) tlPtr.asTypedList(tlBytes.length).setAll(0, tlBytes);
      return _spineSetTranslation(
            handle,
            ordinal,
            trPtr,
            trBytes.length,
            tlPtr,
            tlBytes.length,
          ) !=
          0;
    } finally {
      malloc.free(trPtr);
      malloc.free(tlPtr);
    }
  }

  KoeUtteranceSegment? spineGetSegment({
    required int handle,
    required int ordinal,
  }) {
    final hdrPtr = calloc<_KoeUtteranceSegmentHeaderNative>(1);
    Pointer<Uint8> textPtr = nullptr;
    Pointer<Uint8> trPtr = nullptr;
    try {
      final ok = _spineGetSegment(
        handle,
        ordinal,
        hdrPtr,
        nullptr,
        0,
        nullptr,
        0,
      );
      if (ok == 0) return null;
      final hdr = hdrPtr.ref;
      textPtr = malloc<Uint8>(hdr.textLen == 0 ? 1 : hdr.textLen);
      trPtr = malloc<Uint8>(hdr.translationLen == 0 ? 1 : hdr.translationLen);
      _spineGetSegment(
        handle,
        ordinal,
        hdrPtr,
        textPtr,
        hdr.textLen,
        trPtr,
        hdr.translationLen,
      );
      final text = utf8.decode(textPtr.asTypedList(hdr.textLen));
      final translation = hdr.hasTranslation != 0
          ? utf8.decode(trPtr.asTypedList(hdr.translationLen))
          : null;
      final srcLang = _readFixedUtf8(hdr.sourceLanguage, 16);
      final tgtLang = _readFixedUtf8(hdr.targetLanguage, 16);
      return KoeUtteranceSegment(
        ordinal: hdr.ordinal,
        revision: hdr.revision,
        startMs: hdr.startMs,
        endMs: hdr.endMs,
        isFinal: hdr.isFinal != 0,
        text: text,
        translation: translation,
        sourceLanguage: srcLang,
        targetLanguage: tgtLang.isEmpty ? null : tgtLang,
      );
    } finally {
      if (textPtr != nullptr) malloc.free(textPtr);
      if (trPtr != nullptr) malloc.free(trPtr);
      calloc.free(hdrPtr);
    }
  }

  String spineFormatCitedSources(int handle) {
    final outLenPtr = calloc<Size>(1);
    Pointer<Uint8> ptr = nullptr;
    var len = 0;
    try {
      ptr = _spineFormatCitedSources(handle, outLenPtr);
      len = outLenPtr.value;
      if (ptr == nullptr || len == 0) return '';
      return utf8.decode(ptr.asTypedList(len));
    } finally {
      if (ptr != nullptr && len > 0) {
        _bufferFree(ptr, len);
      }
      calloc.free(outLenPtr);
    }
  }

  bool minutesValidateClaimGrounding({
    required int spineHandle,
    required String claim,
    required List<int> citations,
  }) {
    if (claim.isEmpty || citations.isEmpty) return false;
    final claimBytes = utf8.encode(claim);
    final claimPtr = malloc<Uint8>(claimBytes.length);
    final citesPtr = calloc<Uint32>(citations.length);
    try {
      claimPtr.asTypedList(claimBytes.length).setAll(0, claimBytes);
      for (var i = 0; i < citations.length; i++) {
        (citesPtr + i).value = citations[i];
      }
      return _minutesValidateClaimGrounding(
            spineHandle,
            claimPtr,
            claimBytes.length,
            citesPtr,
            citations.length,
          ) !=
          0;
    } finally {
      malloc.free(claimPtr);
      calloc.free(citesPtr);
    }
  }

  int minutesValidateJson({
    required int spineHandle,
    required String json,
  }) {
    if (json.isEmpty) return 0;
    final bytes = utf8.encode(json);
    final ptr = malloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return _minutesValidateJson(spineHandle, ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  String minutesReplaceTerms({
    required String text,
    required Map<String, String> replacements,
  }) {
    if (text.isEmpty || replacements.isEmpty) return text;
    final fromJoined = utf8.encode(replacements.keys.join('\n'));
    final toJoined = utf8.encode(replacements.values.join('\n'));
    final textBytes = utf8.encode(text);
    final textPtr = malloc<Uint8>(textBytes.isEmpty ? 1 : textBytes.length);
    final fromPtr = malloc<Uint8>(fromJoined.isEmpty ? 1 : fromJoined.length);
    final toPtr = malloc<Uint8>(toJoined.isEmpty ? 1 : toJoined.length);
    Pointer<Uint8> outPtr = nullptr;
    try {
      if (textBytes.isNotEmpty) {
        textPtr.asTypedList(textBytes.length).setAll(0, textBytes);
      }
      if (fromJoined.isNotEmpty) {
        fromPtr.asTypedList(fromJoined.length).setAll(0, fromJoined);
      }
      if (toJoined.isNotEmpty) {
        toPtr.asTypedList(toJoined.length).setAll(0, toJoined);
      }
      final needed = _minutesReplaceTermsUtf8(
        textPtr,
        textBytes.length,
        fromPtr,
        fromJoined.length,
        toPtr,
        toJoined.length,
        nullptr,
        0,
      );
      if (needed <= 0) return needed == 0 ? '' : text;
      outPtr = malloc<Uint8>(needed);
      final written = _minutesReplaceTermsUtf8(
        textPtr,
        textBytes.length,
        fromPtr,
        fromJoined.length,
        toPtr,
        toJoined.length,
        outPtr,
        needed,
      );
      if (written < 0) return text;
      return utf8.decode(outPtr.asTypedList(written));
    } finally {
      malloc.free(textPtr);
      malloc.free(fromPtr);
      malloc.free(toPtr);
      if (outPtr != nullptr) malloc.free(outPtr);
    }
  }

  int minutesPlanBatchesCount({
    required int spineHandle,
    int maxRunes = 6000,
  }) {
    return _minutesPlanBatchesCount(spineHandle, maxRunes);
  }

  int qwenParseTranscriptIntoSpine({
    required int spineHandle,
    required String json,
  }) {
    if (json.isEmpty) return -1;
    final bytes = utf8.encode(json);
    final ptr = malloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return _qwenParseTranscript(spineHandle, ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  int cicadaRollingNew({String sessionId = 'cicada'}) {
    final bytes = utf8.encode(sessionId);
    final ptr = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      if (bytes.isNotEmpty) {
        ptr.asTypedList(bytes.length).setAll(0, bytes);
      }
      return _cicadaRollingNew(ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  void cicadaRollingFree(int handle) => _cicadaRollingFree(handle);

  bool cicadaRollingAddSegment({
    required int handle,
    required String segId,
    required String text,
    required int nowMs,
  }) {
    final idBytes = utf8.encode(segId);
    final textBytes = utf8.encode(text);
    final idPtr = malloc<Uint8>(idBytes.isEmpty ? 1 : idBytes.length);
    final textPtr = malloc<Uint8>(textBytes.isEmpty ? 1 : textBytes.length);
    try {
      if (idBytes.isNotEmpty) {
        idPtr.asTypedList(idBytes.length).setAll(0, idBytes);
      }
      if (textBytes.isNotEmpty) {
        textPtr.asTypedList(textBytes.length).setAll(0, textBytes);
      }
      return _cicadaRollingAddSegment(
            handle,
            idPtr,
            idBytes.length,
            textPtr,
            textBytes.length,
            nowMs,
          ) !=
          0;
    } finally {
      malloc.free(idPtr);
      malloc.free(textPtr);
    }
  }

  KoeCicadaRollingTicket? cicadaRollingPollTick({
    required int handle,
    required int nowMs,
  }) {
    final fromPtr = calloc<Uint32>();
    final endPtr = calloc<Uint32>();
    final genPtr = calloc<Uint64>();
    final lenPtr = calloc<Size>();
    Pointer<Uint8> bufPtr = nullptr;
    try {
      bufPtr = _cicadaRollingPollTick(
        handle,
        nowMs,
        fromPtr,
        endPtr,
        genPtr,
        lenPtr,
      );
      final len = lenPtr.value;
      if (bufPtr == nullptr || len <= 0) return null;
      final payload = utf8.decode(bufPtr.asTypedList(len));
      return KoeCicadaRollingTicket(
        fromIndex: fromPtr.value,
        endIndex: endPtr.value,
        generation: genPtr.value,
        payload: payload,
      );
    } finally {
      if (bufPtr != nullptr) {
        _bufferFree(bufPtr, lenPtr.value);
      }
      calloc.free(fromPtr);
      calloc.free(endPtr);
      calloc.free(genPtr);
      calloc.free(lenPtr);
    }
  }

  int cicadaRollingComplete({
    required int handle,
    required int generation,
    required int fromIndex,
    required int endIndex,
    required String rawJson,
  }) {
    if (rawJson.isEmpty) return -1;
    final bytes = utf8.encode(rawJson);
    final ptr = malloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return _cicadaRollingComplete(
        handle,
        generation,
        fromIndex,
        endIndex,
        ptr,
        bytes.length,
      );
    } finally {
      malloc.free(ptr);
    }
  }

  int cicadaRollingEdit({
    required int handle,
    required String editedJson,
  }) {
    if (editedJson.isEmpty) return -1;
    final bytes = utf8.encode(editedJson);
    final ptr = malloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return _cicadaRollingEdit(handle, ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  bool cicadaRollingAcceptCandidate(int handle) =>
      _cicadaRollingAcceptCandidate(handle) != 0;

  String? cicadaRollingGetActive(int handle) {
    final lenPtr = calloc<Size>();
    Pointer<Uint8> bufPtr = nullptr;
    try {
      bufPtr = _cicadaRollingGetActive(handle, lenPtr);
      final len = lenPtr.value;
      if (bufPtr == nullptr || len <= 0) return null;
      return utf8.decode(bufPtr.asTypedList(len));
    } finally {
      if (bufPtr != nullptr) {
        _bufferFree(bufPtr, lenPtr.value);
      }
      calloc.free(lenPtr);
    }
  }

  KoeCicadaRollingStatus? cicadaRollingStatus(int handle) {
    final ptr = calloc<_KoeCicadaRollingStatusNative>();
    try {
      if (_cicadaRollingStatus(handle, ptr) == 0) return null;
      final c = ptr.ref;
      return KoeCicadaRollingStatus(
        paused: c.paused != 0,
        closed: c.closed != 0,
        edited: c.edited != 0,
        hasCandidate: c.hasCandidate != 0,
        requestStatus: c.requestStatus,
        watermark: c.watermark,
        callsThisHour: c.callsThisHour,
        generation: c.generation,
      );
    } finally {
      calloc.free(ptr);
    }
  }

  ({int nextElapsedMs, bool autoStopped, bool triggered}) cicadaSilenceReduce({
    required int silenceElapsedMs,
    required int deltaMs,
    required bool speechDetected,
    required bool alreadyAutoStopped,
  }) {
    final nextPtr = calloc<Uint64>();
    final stoppedPtr = calloc<Uint8>();
    try {
      final triggered = _cicadaSilenceReduce(
        silenceElapsedMs,
        deltaMs,
        speechDetected ? 1 : 0,
        alreadyAutoStopped ? 1 : 0,
        nextPtr,
        stoppedPtr,
      );
      return (
        nextElapsedMs: nextPtr.value,
        autoStopped: stoppedPtr.value != 0,
        triggered: triggered != 0,
      );
    } finally {
      calloc.free(nextPtr);
      calloc.free(stoppedPtr);
    }
  }

  int koepackVerifyV2(Uint8List packBytes) {
    if (packBytes.isEmpty) return -1;
    final ptr = malloc<Uint8>(packBytes.length);
    try {
      ptr.asTypedList(packBytes.length).setAll(0, packBytes);
      return _koepackVerifyV2(ptr, packBytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  Uint8List? koepackEncodeDemoV2({
    required String contentHash,
    required String title,
    required String source,
    required String minutesJson,
  }) {
    final hashBytes = utf8.encode(contentHash);
    final titleBytes = utf8.encode(title);
    final srcBytes = utf8.encode(source);
    final minBytes = utf8.encode(minutesJson);
    final hashPtr = malloc<Uint8>(hashBytes.isEmpty ? 1 : hashBytes.length);
    final titlePtr = malloc<Uint8>(titleBytes.isEmpty ? 1 : titleBytes.length);
    final srcPtr = malloc<Uint8>(srcBytes.isEmpty ? 1 : srcBytes.length);
    final minPtr = malloc<Uint8>(minBytes.isEmpty ? 1 : minBytes.length);
    final lenPtr = calloc<Size>();
    Pointer<Uint8> outPtr = nullptr;
    try {
      if (hashBytes.isNotEmpty) {
        hashPtr.asTypedList(hashBytes.length).setAll(0, hashBytes);
      }
      if (titleBytes.isNotEmpty) {
        titlePtr.asTypedList(titleBytes.length).setAll(0, titleBytes);
      }
      if (srcBytes.isNotEmpty) {
        srcPtr.asTypedList(srcBytes.length).setAll(0, srcBytes);
      }
      if (minBytes.isNotEmpty) {
        minPtr.asTypedList(minBytes.length).setAll(0, minBytes);
      }
      outPtr = _koepackEncodeDemoV2(
        hashPtr,
        hashBytes.length,
        titlePtr,
        titleBytes.length,
        srcPtr,
        srcBytes.length,
        minPtr,
        minBytes.length,
        lenPtr,
      );
      final len = lenPtr.value;
      if (outPtr == nullptr || len <= 0) return null;
      return Uint8List.fromList(outPtr.asTypedList(len));
    } finally {
      if (outPtr != nullptr) {
        _bufferFree(outPtr, lenPtr.value);
      }
      malloc.free(hashPtr);
      malloc.free(titlePtr);
      malloc.free(srcPtr);
      malloc.free(minPtr);
      calloc.free(lenPtr);
    }
  }

  static DeviceInfoModel _decodeDeviceInfo(
    _KoeDeviceInfoNative c,
    String rawHex,
  ) {
    return DeviceInfoModel(
      connectStatus: c.connectStatus < 0 ? null : c.connectStatus,
      battery: c.battery < 0 ? null : c.battery,
      charging: c.charging != 0,
      firmwareVersion: _readFixedUtf8(c.firmwareVersion, 16),
      serialNumber: _readFixedUtf8(c.serialNumber, 32),
      totalMemoryKb: c.hasMemory != 0 ? c.totalMemoryKb : null,
      freeMemoryKb: c.hasMemory != 0 ? c.freeMemoryKb : null,
      boxBattery: c.boxBattery < 0 ? null : c.boxBattery,
      boxCharging: c.boxCharging != 0,
      boxMac: _readFixedUtf8(c.boxMac, 24),
      boxFirmware: _readFixedUtf8(c.boxFirmware, 16),
      wifiFirmware: _readFixedUtf8(c.wifiFirmware, 16),
      recordingStatus: c.recordingStatus,
      rawHex: rawHex,
    );
  }

  static String _readFixedUtf8(Array<Uint8> arr, int maxLen) {
    final bytes = <int>[];
    for (var i = 0; i < maxLen; i++) {
      final b = arr[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Uint8List _readFixedBytes(Array<Uint8> arr, int len) {
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = arr[i];
    }
    return out;
  }
}
