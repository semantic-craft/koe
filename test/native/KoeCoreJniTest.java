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
  static native long[] sessionIngestBleChunk(long handle, byte[] chunk, long nowEpochSec);
  static native byte[] sessionPopOutboundTx(long handle);
  static native long[] sessionSimulateRealtimePipeline(long handle, long nowEpochSec);
  static native byte[] sessionTakeLivePcm16(long handle);
  static native long[] sessionTakeFinalizedMeta(long handle);
  static native byte[] sessionTakeFinalizedOgg(long handle);
  static native byte[] sessionTakeFinalizedWav(long handle);

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
    long[] step = KoeCoreNative.sessionSimulateRealtimePipeline(session, 1_700_000_000L);
    check(
        step.length == 15 && step[6] == 1L && step[7] == 60L && step[14] == 38400L,
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
  }
}
