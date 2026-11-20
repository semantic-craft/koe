package com.semanticcraft.koe.bridge;

public final class KoeNativeBridge {
  public interface CredentialBridge {
    byte[] onCredential(int operation, byte[] reference, byte[] value);
  }

  private KoeNativeBridge() {}

  public static void loadLibrary(String name) {
    System.loadLibrary(name);
  }

  public static native int nativeApiVersion();

  public static native long nativeSessionCreate(byte[] directoryUtf8);

  public static native long nativeSessionCreateWithCredentials(
      byte[] directoryUtf8, CredentialBridge credentialBridge, boolean isolated);

  public static native boolean nativeSessionDestroy(long handle);

  public static native long nativeSessionGeneration(long handle);

  public static native byte[] nativeSessionSnapshotJson(long handle, long nowEpochSec);

  public static native byte[] nativeSessionDispatchJson(
      long handle, byte[] commandUtf8, long nowEpochSec);

  public static native long nativeSessionIngestBle(
      long handle, byte[] bytes, long nowEpochSec);

  public static native long[] nativeSessionIngestPcm(
      long handle,
      byte[] recordId,
      byte[] sessionId,
      byte[] lane,
      long sequence,
      long epoch,
      long capturedStartNs,
      boolean hasTiming,
      short[] samples,
      int sampleCount,
      long nowEpochSec);

  public static native long[] nativeSessionReportPlaybackProgress(
      long handle,
      byte[] recordId,
      long requestId,
      long positionMs,
      boolean isPlaying,
      long lastProjectedNowSec,
      long nowEpochSec);

  public static native byte[] nativeSessionDrainBleTx(long handle);

  public static native byte[] nativeSessionDrainLocalAsr(long handle);

  public static native long nativeSessionPollTimers(
      long handle, long elapsedMs, long nowEpochSec);
}
