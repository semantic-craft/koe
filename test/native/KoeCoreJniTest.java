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
}

public final class KoeCoreJniTest {
  private static void check(boolean cond, String msg) {
    if (!cond) {
      System.err.println("JNI FAIL: " + msg);
      System.exit(1);
    }
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
    check(KoeCoreNative.sessionBeginWifiBatch(wifiSession, new long[] {801L}), "sessionBeginWifiBatch");
    byte[] wsOut = KoeCoreNative.sessionPopOutboundWifiWs(wifiSession);
    byte[] udpOut = KoeCoreNative.sessionPopOutboundWifiUdp(wifiSession);
    check(wsOut != null && wsOut.length == 36, "sessionPopOutboundWifiWs initial 36-char hex");
    check(udpOut != null && udpOut.length == 28, "sessionPopOutboundWifiUdp initial 28B keepalive");
    long[] wifiProg = KoeCoreNative.sessionGetWifiBatchProgress(wifiSession);
    check(wifiProg.length == 11 && wifiProg[0] == 2L && wifiProg[3] == 1L && wifiProg[4] == 801L, "sessionGetWifiBatchProgress");
    KoeCoreNative.sessionCancelWifiBatch(wifiSession);
    KoeCoreNative.sessionFree(wifiSession);
  }
}
