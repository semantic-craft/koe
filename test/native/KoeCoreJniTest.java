package com.anker.anker_recorder;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

final class KoeCoreNative {
  static native int checksum(byte[] data);
  static native boolean verifyChecksum(byte[] packet);
  static native byte[] encodeFrame(int cmdType, int cmdId, byte[] payload);
  static native byte[] hkdfSha256(byte[] ikm, byte[] salt, byte[] info, int length);
  static native byte[] muxOggOpus(byte[] rawOpusFrames);
  static native byte[] buildAudiblePreviewWav(long durationMs, long[] marksMs);
  static native byte[] decodeOpusPcm16(byte[] rawOpusFrames, int sampleRate);
  static native byte[] decodeOpusWav(byte[] rawOpusFrames, int sampleRate, long[] marksMs);

  static native long reassemblerNew();
  static native void reassemblerFree(long handle);
  static native void reassemblerReset(long handle);
  static native int reassemblerIngest(long handle, byte[] chunk);
  static native byte[] reassemblerPopPacket(long handle);

  static native long sessionNew();
  static native void sessionFree(long handle);
  static native boolean sessionAcceptEcdhReply(long handle, byte[] replyPayload, byte[] sharedSecret);
  static native byte[] sessionBeginOfflinePull(long handle, int fileId, int durationMs);
  static native void sessionOnTransportInterrupted(long handle);
  static native byte[] sessionResumeOfflinePull(long handle);
  static native long[] sessionStopRealtimeRecording(long handle);
  static native long[] sessionPollTimers(long handle, long elapsedMs, long nowEpochSec);
  static native long[] sessionIngestBleChunk(long handle, byte[] chunk, long nowEpochSec);
  static native byte[] sessionPopOutboundTx(long handle);
  static native long[] sessionSimulateRealtimePipeline(long handle, long nowEpochSec);
  static native byte[] sessionTakeLivePcm16(long handle);
  static native long[] sessionTakeFinalizedMeta(long handle);
  static native byte[] sessionTakeFinalizedOgg(long handle);
  static native byte[] sessionTakeFinalizedWav(long handle);
  static native long[] wifiParseConfigResponse(byte[] raw);
  static native boolean wifiSharesSubnet(byte[] deviceIp, byte[] localIp);
  static native byte[] wifiBuildFileRequestHex(int fileId, int alreadyTransferred);
  static native byte[] wifiBuildTransferCompleteHex();
  static native byte[] wifiKeepalivePayload();
  static native boolean sessionBeginWifiBatch(long handle, long[] fileIds);
  static native long[] sessionIngestWifiChunk(long handle, byte[] chunk, long nowEpochSec);
  static native byte[] sessionPopOutboundWifiWs(long handle);
  static native byte[] sessionPopOutboundWifiUdp(long handle);
  static native long[] sessionGetWifiBatchProgress(long handle);
  static native long[] sessionGetWifiEndpoint(long handle);
  static native boolean sessionOnWifiInterrupted(long handle, long nowEpochSec);
  static native boolean sessionResumeWifiBatch(long handle);
  static native void sessionCancelWifiBatch(long handle);

  static native long libraryNew();
  static native void libraryFree(long handle);
  static native boolean libraryIngestEntry(
      long handle,
      int id,
      int beanFileId,
      long createdAtEpochSec,
      long durationMs,
      int byteCount,
      long[] marksMs);
  static native boolean librarySelect(long handle, int recordingId);
  static native long librarySeekMs(long handle, long positionMs);
  static native long libraryJumpToMark(long handle, long currentMs, int direction);
  static native boolean libraryMoveToTrash(long handle, int recordingId);
  static native int libraryUndoTrash(long handle);
  static native long[] librarySnapshot(long handle);

  static native long spineNew(byte[] sessionId);
  static native void spineFree(long handle);
  static native void spineClearStale(long handle);
  static native long[] spineSnapshot(long handle);
  static native int spineAppendSegment(
      long handle,
      byte[] text,
      long startMs,
      long endMs,
      byte[] sourceLang,
      byte[] provider);
  static native int spineAcceptCumulative(
      long handle,
      byte[] connId,
      byte[] text,
      byte[] sourceLang,
      byte[] translation,
      byte[] targetLang,
      byte[] provider);
  static native boolean spineUpdateSegmentText(long handle, int ordinal, byte[] newText);
  static native boolean spineSetTranslation(
      long handle,
      int ordinal,
      byte[] translation,
      byte[] targetLang);
  static native long[] spineGetSegmentMeta(long handle, int ordinal);
  static native byte[] spineGetSegmentText(long handle, int ordinal);
  static native byte[] spineGetSegmentTranslation(long handle, int ordinal);
  static native byte[] spineFormatCitedSources(long handle);
  static native boolean minutesValidateClaimGrounding(
      long spineHandle,
      byte[] claim,
      long[] citations);
  static native int minutesValidateJson(long spineHandle, byte[] json);
  static native byte[] minutesReplaceTermsUtf8(byte[] text, byte[] fromTerms, byte[] toTerms);
  static native int minutesPlanBatchesCount(long spineHandle, int maxRunes);
  static native int qwenParseTranscriptIntoSpine(long spineHandle, byte[] json);
  static native long[] nativeCicadaSilenceReduce(
      long silenceElapsedMs,
      long deltaMs,
      boolean speechDetected,
      boolean alreadyAutoStopped);
  static native int nativeKoepackVerifyV2(byte[] packBytes);
  static native byte[] nativeKoepackEncodeDemoV2(
      byte[] contentHash,
      byte[] title,
      byte[] source,
      byte[] minutesJson);
}

public final class KoeCoreJniTest {
  private static final byte[] REAL_OPUS_20MS_440HZ = new byte[] {
    0x78, (byte) 0x81, (byte) 0xa7, 0x5d, 0x6c, (byte) 0x9e, (byte) 0x99, (byte) 0xac,
    0x00, 0x00, 0x06, 0x7e, 0x56, 0x39, (byte) 0xf7, 0x3b,
    0x1e, (byte) 0xa2, (byte) 0xdc, 0x31, 0x0f, 0x52, 0x38, 0x39,
    0x39, 0x3e, (byte) 0xa3, (byte) 0xd0, (byte) 0x84, 0x47, (byte) 0xcb, (byte) 0xe1,
    (byte) 0xb6, (byte) 0xb8, (byte) 0xff, 0x44, 0x14, 0x3d, 0x76, 0x21,
    (byte) 0xaf, 0x07, 0x34, (byte) 0xdd, 0x07, (byte) 0x87, (byte) 0xec, (byte) 0x99,
    (byte) 0xfe, (byte) 0xc0, (byte) 0xf5, 0x44, 0x18, (byte) 0x9d, 0x5f, 0x48,
    0x29, 0x42, (byte) 0xde, (byte) 0xd8, 0x2f, (byte) 0x85, (byte) 0xb6, 0x18,
    (byte) 0xf4, 0x3b, 0x64, (byte) 0x92, (byte) 0xde, (byte) 0x94, 0x70, 0x50,
    (byte) 0xe0, (byte) 0x97, 0x68, 0x7d, 0x6c, 0x10, (byte) 0xd0, (byte) 0xaf,
    0x63, (byte) 0x85, 0x53, (byte) 0xa2, 0x71, 0x65, (byte) 0xe7, (byte) 0x91,
    0x29, 0x01, (byte) 0x80, 0x53, 0x15, 0x04
  };

  private static void check(boolean cond, String msg) {
    if (!cond) {
      System.err.println("JNI FAIL: " + msg);
      System.exit(1);
    }
  }

  private static void writeU32Le(byte[] buf, int offset, int value) {
    buf[offset] = (byte) (value & 0xFF);
    buf[offset + 1] = (byte) ((value >>> 8) & 0xFF);
    buf[offset + 2] = (byte) ((value >>> 16) & 0xFF);
    buf[offset + 3] = (byte) ((value >>> 24) & 0xFF);
  }

  private static byte[] makeShortHead(int fileId, int fileSize, int errorCode) {
    int payloadLen = errorCode != 0 ? 87 : 8;
    int totalLen = 9 + payloadLen + 1;
    byte[] frame = new byte[totalLen];
    frame[0] = 0x09;
    frame[1] = (byte) 0xFF;
    frame[4] = 0x01;
    frame[5] = 0x1A;
    frame[6] = 0x07;
    frame[7] = (byte) (totalLen & 0xFF);
    frame[8] = (byte) ((totalLen >>> 8) & 0xFF);
    writeU32Le(frame, 9, fileId);
    writeU32Le(frame, 13, fileSize);
    if (errorCode != 0) {
      frame[95] = (byte) errorCode;
    }
    frame[totalLen - 1] = (byte) KoeCoreNative.checksum(Arrays.copyOf(frame, totalLen - 1));
    return frame;
  }

  private static byte[] makeSliceFrame(int sliceCount, int markedSeq) {
    int payloadLen = sliceCount * 166;
    int totalLen = 9 + payloadLen + 1;
    byte[] frame = new byte[totalLen];
    frame[0] = 0x09;
    frame[1] = (byte) 0xFF;
    frame[4] = 0x01;
    frame[5] = 0x1A;
    frame[6] = 0x08;
    frame[7] = (byte) (totalLen & 0xFF);
    frame[8] = (byte) ((totalLen >>> 8) & 0xFF);
    for (int seq = 0; seq < sliceCount; seq++) {
      int base = 9 + seq * 166;
      writeU32Le(frame, base, seq);
      frame[base + 4] = (byte) (seq == markedSeq ? 1 : 0);
      System.arraycopy(REAL_OPUS_20MS_440HZ, 0, frame, base + 5, REAL_OPUS_20MS_440HZ.length);
      frame[base + 165] = 0x00;
    }
    frame[totalLen - 1] = (byte) KoeCoreNative.checksum(Arrays.copyOf(frame, totalLen - 1));
    return frame;
  }

  public static void main(String[] args) {
    check(args.length >= 1, "expected path to libkoe_core_ffi.dylib");
    System.load(args[0]);

    byte[] tx = KoeCoreNative.encodeFrame(0x01, 0x01, new byte[0]);
    check(tx.length == 10 && (tx[0] & 0xFF) == 0x08 && (tx[1] & 0xFF) == 0xEE, "encodeFrame 01/01");
    check(KoeCoreNative.verifyChecksum(tx), "verifyChecksum on encoded TX");

    byte[] key = KoeCoreNative.hkdfSha256(new byte[32], new byte[] {1, 2, 3}, new byte[] {1, 2, 3}, 32);
    check(key.length == 32, "hkdfSha256 must return 32 bytes");

    byte[] wav = KoeCoreNative.buildAudiblePreviewWav(600L, new long[] {300L});
    check(
        wav.length > 44
            && new String(wav, 0, 4, StandardCharsets.US_ASCII).equals("RIFF"),
        "buildAudiblePreviewWav must return RIFF WAV");

    long reassembler = KoeCoreNative.reassemblerNew();
    byte[] rx = new byte[] {0x09, (byte) 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x0A, 0x00, 0x00};
    rx[9] = (byte) KoeCoreNative.checksum(Arrays.copyOf(rx, 9));
    check(KoeCoreNative.reassemblerIngest(reassembler, Arrays.copyOf(rx, 5)) == 0, "partial rx");
    check(
        KoeCoreNative.reassemblerIngest(reassembler, Arrays.copyOfRange(rx, 5, 10)) == 1,
        "completed rx");
    byte[] popped = KoeCoreNative.reassemblerPopPacket(reassembler);
    check(popped != null && popped.length == 10, "reassemblerPopPacket length 10");
    KoeCoreNative.reassemblerFree(reassembler);

    long session = KoeCoreNative.sessionNew();
    byte[] pullTx = KoeCoreNative.sessionBeginOfflinePull(session, 501, 2000);
    check(pullTx != null && pullTx.length == 19, "sessionBeginOfflinePull 19B TX");
    long[] w1 = KoeCoreNative.sessionPollTimers(session, 5000L, 1_700_000_010L);
    check(w1.length == 18 && w1[10] == 2L && w1[16] == 1L, "sessionPollTimers retry 1");
    byte[] retryTx = KoeCoreNative.sessionPopOutboundTx(session);
    check(retryTx != null && retryTx.length == 19, "sessionPopOutboundTx retry TX");
    KoeCoreNative.sessionOnTransportInterrupted(session);
    byte[] resumeTx = KoeCoreNative.sessionResumeOfflinePull(session);
    check(resumeTx != null && resumeTx.length == 19, "sessionResumeOfflinePull 19B TX");
    long[] stopOut = KoeCoreNative.sessionStopRealtimeRecording(session);
    check(stopOut != null && stopOut.length == 18 && stopOut[9] == 1L, "sessionStopRealtimeRecording queues pause TX");
    byte[] pauseTx = KoeCoreNative.sessionPopOutboundTx(session);
    check(pauseTx != null && pauseTx.length == 11, "pauseRecord TX length 11");

    long[] step = KoeCoreNative.sessionSimulateRealtimePipeline(session, 1_700_000_000L);
    check(
        step.length == 18 && step[6] == 1L && step[7] == 60L && step[14] == 38400L,
        "sessionSimulateRealtimePipeline 60 slices + 38400B live PCM16");
    byte[] livePcm = KoeCoreNative.sessionTakeLivePcm16(session);
    check(livePcm != null && livePcm.length == 38400, "sessionTakeLivePcm16 length 38400");
    short sample130 = (short) ((livePcm[130 * 2] & 0xFF) | (livePcm[130 * 2 + 1] << 8));
    check(Math.abs(sample130 - (-4130)) <= 16, "livePcm sample 130 near -4130");
    long[] meta = KoeCoreNative.sessionTakeFinalizedMeta(session);
    check(meta != null && meta[0] == 20261107L && meta[3] == 1200L && meta[5] == 2L, "finalized meta");
    check(meta[6] == 300L && meta[7] == 900L, "finalized marks [300, 900]");
    byte[] oggBytes = KoeCoreNative.sessionTakeFinalizedOgg(session);
    byte[] wavBytes = KoeCoreNative.sessionTakeFinalizedWav(session);
    check(
        oggBytes != null
            && new String(oggBytes, 0, 4, StandardCharsets.US_ASCII).equals("OggS"),
        "finalized OggS");
    check(
        wavBytes != null
            && wavBytes.length == 115244
            && new String(wavBytes, 0, 4, StandardCharsets.US_ASCII).equals("RIFF"),
        "finalized 115244-byte RIFF WAV");
    KoeCoreNative.sessionFree(session);

    long library = KoeCoreNative.libraryNew();
    check(
        KoeCoreNative.libraryIngestEntry(
            library, 20261107, 20261107, 1_700_000_000L, 1200L, oggBytes.length, new long[] {300L, 900L}),
        "libraryIngestEntry");
    check(KoeCoreNative.libraryJumpToMark(library, 0L, 1) == 300L, "libraryJumpToMark next -> 300");
    check(KoeCoreNative.libraryJumpToMark(library, 300L, 1) == 900L, "libraryJumpToMark next -> 900");
    check(KoeCoreNative.libraryJumpToMark(library, 900L, -1) == 300L, "libraryJumpToMark prev -> 300");
    check(KoeCoreNative.libraryMoveToTrash(library, 20261107), "libraryMoveToTrash");
    long[] snapTrashed = KoeCoreNative.librarySnapshot(library);
    check(snapTrashed[0] == 0L && snapTrashed[3] == 1L, "snapshot after trash");
    check(KoeCoreNative.libraryUndoTrash(library) == 20261107, "libraryUndoTrash");
    long[] snapRestored = KoeCoreNative.librarySnapshot(library);
    check(snapRestored[0] == 1L && snapRestored[1] == 20261107L, "snapshot after undo");
    KoeCoreNative.libraryFree(library);

    byte[] wifiCfg = new byte[] {
      0x09, (byte) 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x10, 0x00,
      1, 4, (byte) 168, (byte) 192, 0x02, 0x7D, 0x00
    };
    wifiCfg[15] = (byte) KoeCoreNative.checksum(Arrays.copyOf(wifiCfg, 15));
    long[] ep = KoeCoreNative.wifiParseConfigResponse(wifiCfg);
    check(
        ep != null && ep.length == 5 && ep[0] == 192L && ep[1] == 168L && ep[2] == 4L && ep[3] == 1L && ep[4] == 32002L,
        "wifiParseConfigResponse 192.168.4.1:32002");
    check(
        KoeCoreNative.wifiSharesSubnet(
            new byte[] {(byte) 192, (byte) 168, 4, 1},
            new byte[] {(byte) 192, (byte) 168, 4, 2}),
        "wifiSharesSubnet /24 match");
    String reqHex = new String(KoeCoreNative.wifiBuildFileRequestHex(1001, 0), StandardCharsets.UTF_8);
    check(reqHex.length() == 36 && reqHex.endsWith("1b"), "wifiBuildFileRequestHex 36 chars ending with 1b");
    String completeHex = new String(KoeCoreNative.wifiBuildTransferCompleteHex(), StandardCharsets.UTF_8);
    check(completeHex.equals("08ee0000001a0a0b000126"), "wifiBuildTransferCompleteHex");
    String keepalive = new String(KoeCoreNative.wifiKeepalivePayload(), StandardCharsets.UTF_8);
    check(keepalive.equals("soundcore-keep-alive-unicast"), "wifiKeepalivePayload");

    long wifiSession = KoeCoreNative.sessionNew();
    KoeCoreNative.sessionIngestBleChunk(wifiSession, wifiCfg, 1_700_000_200L);
    long[] sessEp = KoeCoreNative.sessionGetWifiEndpoint(wifiSession);
    check(sessEp != null && sessEp[0] == 192L && sessEp[4] == 32002L, "sessionGetWifiEndpoint");
    check(
        KoeCoreNative.sessionBeginWifiBatch(wifiSession, new long[] {801L, 802L, 803L}),
        "sessionBeginWifiBatch [801, 802, 803]");
    byte[] wsOut = KoeCoreNative.sessionPopOutboundWifiWs(wifiSession);
    byte[] udpOut = KoeCoreNative.sessionPopOutboundWifiUdp(wifiSession);
    check(wsOut != null && wsOut.length == 36, "sessionPopOutboundWifiWs initial 36-char hex");
    check(udpOut != null && udpOut.length == 28, "sessionPopOutboundWifiUdp initial 28B keepalive");
    long[] wifiProg = KoeCoreNative.sessionGetWifiBatchProgress(wifiSession);
    check(wifiProg.length == 11 && wifiProg[0] == 2L && wifiProg[3] == 3L && wifiProg[4] == 801L, "sessionGetWifiBatchProgress 801");

    KoeCoreNative.sessionIngestWifiChunk(wifiSession, makeShortHead(801, 166, 0), 1_700_000_201L);
    long[] step801 = KoeCoreNative.sessionIngestWifiChunk(wifiSession, makeSliceFrame(1, 0), 1_700_000_201L);
    check(step801[6] == 1L, "file 801 finalized on reaching expected_wire_bytes");
    String ws802 = new String(KoeCoreNative.sessionPopOutboundWifiWs(wifiSession), StandardCharsets.UTF_8);
    check(
        ws802.equals(new String(KoeCoreNative.wifiBuildFileRequestHex(802, 0), StandardCharsets.UTF_8)),
        "completing 801 queues 1A/07 for 802");

    KoeCoreNative.sessionIngestWifiChunk(wifiSession, makeShortHead(802, 166, 1), 1_700_000_202L);
    long[] progAfter802 = KoeCoreNative.sessionGetWifiBatchProgress(wifiSession);
    check(progAfter802[9] == 1L && progAfter802[4] == 803L, "error_code 1 skips 802 and advances to 803");
    String ws803 = new String(KoeCoreNative.sessionPopOutboundWifiWs(wifiSession), StandardCharsets.UTF_8);
    check(
        ws803.equals(new String(KoeCoreNative.wifiBuildFileRequestHex(803, 0), StandardCharsets.UTF_8)),
        "skipping 802 queues 1A/07 for 803");

    KoeCoreNative.sessionIngestWifiChunk(wifiSession, makeShortHead(803, 20 * 166, 0), 1_700_000_203L);
    KoeCoreNative.sessionIngestWifiChunk(wifiSession, makeSliceFrame(19, 5), 1_700_000_203L);
    check(
        KoeCoreNative.sessionOnWifiInterrupted(wifiSession, 1_700_000_204L),
        "sessionOnWifiInterrupted salvages 803 at 95% (3154/3320 bytes)");
    long[] progInt = KoeCoreNative.sessionGetWifiBatchProgress(wifiSession);
    check(
        progInt[0] == 3L && progInt[7] == 1L && progInt[8] == 1L && progInt[9] == 1L && progInt[10] == 0L,
        "batch progress after salvage: phase=Interrupted(3), finalized=1, salvaged=1, skipped=1, remaining=0");

    long wifiLib = KoeCoreNative.libraryNew();
    long[] meta801 = KoeCoreNative.sessionTakeFinalizedMeta(wifiSession);
    byte[] ogg801 = KoeCoreNative.sessionTakeFinalizedOgg(wifiSession);
    byte[] wav801 = KoeCoreNative.sessionTakeFinalizedWav(wifiSession);
    check(meta801 != null && meta801[0] == 801L && ogg801 != null && wav801 != null, "drain 801");
    check(
        KoeCoreNative.libraryIngestEntry(
            wifiLib, (int) meta801[0], (int) meta801[1], meta801[2], meta801[3], (int) meta801[4], new long[] {0L}),
        "ingest 801 into library");

    long[] meta803 = KoeCoreNative.sessionTakeFinalizedMeta(wifiSession);
    byte[] ogg803 = KoeCoreNative.sessionTakeFinalizedOgg(wifiSession);
    byte[] wav803 = KoeCoreNative.sessionTakeFinalizedWav(wifiSession);
    check(
        meta803 != null && meta803[0] == 803L && meta803[5] == 1L && meta803[6] == 100L && ogg803 != null && wav803 != null,
        "drain salvaged 803 with mark at 100ms");
    check(
        KoeCoreNative.libraryIngestEntry(
            wifiLib, (int) meta803[0], (int) meta803[1], meta803[2], meta803[3], (int) meta803[4], new long[] {100L}),
        "ingest 803 into library");
    long[] wifiLibSnap = KoeCoreNative.librarySnapshot(wifiLib);
    check(wifiLibSnap[0] == 2L && wifiLibSnap[1] == 803L, "wifiLib holds both 801 and 803");
    KoeCoreNative.libraryFree(wifiLib);
    KoeCoreNative.sessionCancelWifiBatch(wifiSession);
    KoeCoreNative.sessionFree(wifiSession);

    long spine = KoeCoreNative.spineNew("jni-spine".getBytes(StandardCharsets.UTF_8));
    int s1 = KoeCoreNative.spineAppendSegment(
        spine,
        "基本工资是3910元。".getBytes(StandardCharsets.UTF_8),
        0L,
        2000L,
        "zh".getBytes(StandardCharsets.UTF_8),
        "qwen".getBytes(StandardCharsets.UTF_8));
    int s2 = KoeCoreNative.spineAppendSegment(
        spine,
        "绩效比例按80%发放。".getBytes(StandardCharsets.UTF_8),
        2000L,
        4000L,
        "zh".getBytes(StandardCharsets.UTF_8),
        "qwen".getBytes(StandardCharsets.UTF_8));
    check(s1 == 1 && s2 == 2, "spineAppendSegment assigns S1 and S2");
    check(
        KoeCoreNative.spineSetTranslation(
            spine,
            1,
            "Base salary is 3910 CNY.".getBytes(StandardCharsets.UTF_8),
            "en".getBytes(StandardCharsets.UTF_8)),
        "spineSetTranslation on S1");
    byte[] tr1 = KoeCoreNative.spineGetSegmentTranslation(spine, 1);
    check(
        tr1 != null && new String(tr1, StandardCharsets.UTF_8).equals("Base salary is 3910 CNY."),
        "spineGetSegmentTranslation returns S1 translation");
    check(
        KoeCoreNative.spineUpdateSegmentText(
            spine, 1, "基本工资调整为4200元。".getBytes(StandardCharsets.UTF_8)),
        "spineUpdateSegmentText on S1");
    long[] spineSnap = KoeCoreNative.spineSnapshot(spine);
    check(spineSnap.length == 3 && spineSnap[0] == 2L && spineSnap[2] == 1L, "spineSnapshot reports stale=1 after edit");
    long[] meta1 = KoeCoreNative.spineGetSegmentMeta(spine, 1);
    check(meta1 != null && meta1[1] == 2L && meta1[5] == 0L, "S1 revision=2 and translation cleared after edit");
    KoeCoreNative.spineClearStale(spine);
    check(KoeCoreNative.spineSnapshot(spine)[2] == 0L, "spineClearStale resets stale to 0");
    int s3 = KoeCoreNative.spineAcceptCumulative(
        spine,
        "c1".getBytes(StandardCharsets.UTF_8),
        "所以实发工资按4200元乘以80%折算。".getBytes(StandardCharsets.UTF_8),
        "zh".getBytes(StandardCharsets.UTF_8),
        new byte[0],
        new byte[0],
        "qwen".getBytes(StandardCharsets.UTF_8));
    check(s3 == 3, "spineAcceptCumulative appends S3");
    String cited = new String(KoeCoreNative.spineFormatCitedSources(spine), StandardCharsets.UTF_8);
    check(cited.contains("[S1] 基本工资调整为4200元。") && cited.contains("[S3]"), "spineFormatCitedSources emits [S1]..[S3]");
    check(
        !KoeCoreNative.minutesValidateClaimGrounding(
            spine,
            "实发工资按4200元乘以80%计算".getBytes(StandardCharsets.UTF_8),
            new long[] {1L, 2L}),
        "minutesValidateClaimGrounding rejects stitched S1+S2 wage*percentage");
    check(
        KoeCoreNative.minutesValidateClaimGrounding(
            spine,
            "实发工资按4200元乘以80%计算".getBytes(StandardCharsets.UTF_8),
            new long[] {3L}),
        "minutesValidateClaimGrounding accepts single-segment grounded S3");
    String validJson =
        "{\"schemaVersion\":2,\"title\":\"周会\",\"overview\":\"讨论安排\",\"topics\":[{\"text\":\"工资确认\",\"sources\":[\"S3\"]}],\"decisions\":[],\"actions\":[],\"questions\":[]}";
    check(
        KoeCoreNative.minutesValidateJson(spine, validJson.getBytes(StandardCharsets.UTF_8)) == 1,
        "minutesValidateJson returns 1 on grounded JSON");
    String badHeardJson =
        "{\"schemaVersion\":2,\"title\":\"周会\",\"overview\":\"讨论安排\",\"topics\":[{\"text\":\"工资确认\",\"sources\":[\"S3\"]}],\"decisions\":[],\"actions\":[],\"questions\":[],\"terms\":[{\"name\":\"声刻\",\"note\":\"品牌\",\"heard\":[\"深科\"],\"sources\":[\"S3\"]}]}";
    check(
        KoeCoreNative.minutesValidateJson(spine, badHeardJson.getBytes(StandardCharsets.UTF_8)) == -2,
        "minutesValidateJson returns -2 on ungrounded heard variant");
    String badCalcJson =
        "{\"schemaVersion\":2,\"title\":\"周会\",\"overview\":\"讨论安排\",\"topics\":[{\"text\":\"实发工资按4200元乘以80%计算\",\"sources\":[\"S1\",\"S2\"]}],\"decisions\":[],\"actions\":[],\"questions\":[]}";
    check(
        KoeCoreNative.minutesValidateJson(spine, badCalcJson.getBytes(StandardCharsets.UTF_8)) == -3,
        "minutesValidateJson returns -3 on ungrounded cross-segment wage calculation");
    check(
        KoeCoreNative.minutesPlanBatchesCount(spine, 6000) == 1,
        "minutesPlanBatchesCount returns 1 for small spine");
    byte[] replacedBytes =
        KoeCoreNative.minutesReplaceTermsUtf8(
            "深科的深科Work录音豆".getBytes(StandardCharsets.UTF_8),
            "深科\n深科Work".getBytes(StandardCharsets.UTF_8),
            "声刻\nSoundcore Work".getBytes(StandardCharsets.UTF_8));
    check(
        replacedBytes != null
            && new String(replacedBytes, StandardCharsets.UTF_8).equals("声刻的Soundcore Work录音豆"),
        "minutesReplaceTermsUtf8 longest-match single-pass replacement");
    long qwenSpine = KoeCoreNative.spineNew("qwen-jni".getBytes(StandardCharsets.UTF_8));
    String qwenRaw =
        "{\"transcripts\":[{\"sentences\":[{\"text\":\"第一句。\",\"begin_time\":0,\"end_time\":1000,\"speaker_id\":0},{\"text\":\"第二句。\",\"begin_time\":1000,\"end_time\":2000,\"speaker_id\":1}]}]}";
    check(
        KoeCoreNative.qwenParseTranscriptIntoSpine(
                qwenSpine, qwenRaw.getBytes(StandardCharsets.UTF_8))
            == 2,
        "qwenParseTranscriptIntoSpine appends 2 segments");
    KoeCoreNative.spineFree(qwenSpine);
    KoeCoreNative.spineFree(spine);

    long[] sil1 = KoeCoreNative.nativeCicadaSilenceReduce(0L, 15_000L, false, false);
    check(sil1 != null && sil1.length == 3 && sil1[0] == 15_000L && sil1[1] == 0L && sil1[2] == 0L, "15s silence accumulates");
    long[] sil2 = KoeCoreNative.nativeCicadaSilenceReduce(sil1[0], 15_000L, false, false);
    check(sil2 != null && sil2[0] == 30_000L && sil2[1] == 1L && sil2[2] == 1L, "30s silence triggers auto-stop");

    String demoHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    String demoMinutes =
        "{\"schemaVersion\":2,\"title\":\"资料包纪要\",\"overview\":\"概述\",\"topics\":[{\"text\":\"讨论事项\",\"sources\":[\"S1\"]}],\"decisions\":[],\"actions\":[],\"questions\":[]}";
    byte[] packBytes =
        KoeCoreNative.nativeKoepackEncodeDemoV2(
            demoHash.getBytes(StandardCharsets.UTF_8),
            "周会资料包".getBytes(StandardCharsets.UTF_8),
            "第一段会议记录".getBytes(StandardCharsets.UTF_8),
            demoMinutes.getBytes(StandardCharsets.UTF_8));
    check(
        packBytes != null
            && packBytes.length > 16
            && new String(packBytes, 0, 8, StandardCharsets.US_ASCII).equals("KOEPACK1"),
        "nativeKoepackEncodeDemoV2 emits KOEPACK1");
    check(
        KoeCoreNative.nativeKoepackVerifyV2(packBytes) == 2,
        "nativeKoepackVerifyV2 returns version 2 on valid pack");
    byte[] tampered = Arrays.copyOf(packBytes, packBytes.length);
    tampered[tampered.length - 1] ^= (byte) 0xFF;
    check(
        KoeCoreNative.nativeKoepackVerifyV2(tampered) < 0,
        "nativeKoepackVerifyV2 rejects tampered pack");
  }
}
