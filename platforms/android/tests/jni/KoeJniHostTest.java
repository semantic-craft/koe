package com.semanticcraft.koe.bridge;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class KoeJniHostTest {
  private static native int nativeStressDetachedThread(
      KoeNativeBridge.CredentialBridge bridge, int iterations);

  private static native boolean nativeTestPendingExceptionPreserved(
      KoeNativeBridge.CredentialBridge bridge);

  public static void main(String[] args) throws Exception {
    KoeNativeBridge.loadLibrary("koe_android_test");

    testApiVersion();
    testDetachedThreadStressAndExceptionRecovery();
    testPendingExceptionPreserved();
    testRealRuntimeSessionEndToEnd();
    testPlainSessionCreateAndDestroy();
    testNegativeLongInputsRejected();
    testConcurrentSessionDestroy();

    System.out.println("KoeJniHostTest: all checks passed.");
  }

  private static void testApiVersion() {
    int version = KoeNativeBridge.nativeApiVersion();
    assertEquals(2, version, "nativeApiVersion must be 2");
  }

  private static void testDetachedThreadStressAndExceptionRecovery() {
    AtomicInteger calls = new AtomicInteger();
    Set<Integer> observedOps = Collections.synchronizedSet(new HashSet<>());
    AtomicBoolean sawSupplementaryUtf8 = new AtomicBoolean(false);
    AtomicInteger thrownCount = new AtomicInteger();

    KoeNativeBridge.CredentialBridge bridge = (op, refBytes, valBytes) -> {
      calls.incrementAndGet();
      observedOps.add(op);
      String ref = refBytes == null ? "" : new String(refBytes, StandardCharsets.UTF_8);
      String val = valBytes == null ? "" : new String(valBytes, StandardCharsets.UTF_8);

      if (ref.contains("\uD840\uDC00") && val.contains("\uD83C\uDF99\uFE0F")) {
        sawSupplementaryUtf8.set(true);
      }
      if (ref.startsWith("missing-")) {
        return null;
      }
      if (ref.startsWith("throw-")) {
        thrownCount.incrementAndGet();
        throw new IllegalArgumentException("simulated keystore failure for " + ref);
      }
      if (ref.equals("empty-ok")) {
        return new byte[0];
      }
      if (ref.equals("nul-byte")) {
        return new byte[] {'a', 0, 'b'};
      }
      return ("echo:" + op + ":" + ref + ":" + val).getBytes(StandardCharsets.UTF_8);
    };

    int rc = nativeStressDetachedThread(bridge, 200);
    assertEquals(0, rc, "detached thread stress test returned error code " + rc);
    assertTrue(calls.get() >= 200, "expected >= 200 credential callbacks, got " + calls.get());
    assertEquals(6, observedOps.size(), "expected all ops 0..5 observed");
    assertTrue(sawSupplementaryUtf8.get(), "expected 4-byte UTF-8 round-trip on detached thread");
    assertTrue(thrownCount.get() > 0, "expected exception path exercised on detached thread");
  }

  private static void testPendingExceptionPreserved() {
    AtomicInteger invoked = new AtomicInteger();
    KoeNativeBridge.CredentialBridge bridge = (op, ref, val) -> {
      invoked.incrementAndGet();
      return "unexpected".getBytes(StandardCharsets.UTF_8);
    };

    boolean caught = false;
    try {
      nativeTestPendingExceptionPreserved(bridge);
    } catch (IllegalStateException ex) {
      assertEquals("pre-existing-pending", ex.getMessage(), "pending exception message changed");
      caught = true;
    }
    assertTrue(caught, "expected pre-existing IllegalStateException to remain pending");
    assertEquals(0, invoked.get(), "bridge must not be invoked when exception is pending");
  }

  private static void testRealRuntimeSessionEndToEnd() throws IOException {
    Path tempDir = Files.createTempDirectory("koe-jni-host-");
    long handle = 0;
    try {
      Map<String, String> store = Collections.synchronizedMap(new HashMap<>());
      List<String> preparedSlots = Collections.synchronizedList(new ArrayList<>());
      AtomicInteger nextRef = new AtomicInteger();
      AtomicBoolean failNextPrepare = new AtomicBoolean(false);

      KoeNativeBridge.CredentialBridge keystore = (op, refBytes, valBytes) -> {
        String ref = refBytes == null ? "" : new String(refBytes, StandardCharsets.UTF_8);
        String val = valBytes == null ? "" : new String(valBytes, StandardCharsets.UTF_8);
        switch (op) {
          case 0: {
            String secret = store.get(ref);
            return secret == null ? null : secret.getBytes(StandardCharsets.UTF_8);
          }
          case 1:
            store.put(ref, val);
            return ref.getBytes(StandardCharsets.UTF_8);
          case 2:
            store.remove(ref);
            return new byte[0];
          case 3:
            return null;
          case 4:
            return new byte[0];
          case 5: {
            if (failNextPrepare.getAndSet(false)) {
              throw new RuntimeException("simulated Android Keystore lock");
            }
            preparedSlots.add(ref);
            String slot = ref.isEmpty() ? "default" : ref;
            String fresh = "android-" + slot + "-" + nextRef.incrementAndGet();
            return fresh.getBytes(StandardCharsets.UTF_8);
          }
          default:
            throw new IllegalArgumentException("unknown op: " + op);
        }
      };

      byte[] dirUtf8 = utf8(tempDir.toString());
      handle = KoeNativeBridge.nativeSessionCreateWithCredentials(dirUtf8, keystore, false);
      assertTrue(handle != 0, "nativeSessionCreateWithCredentials must return nonzero handle");

      long duplicateHandle =
          KoeNativeBridge.nativeSessionCreateWithCredentials(dirUtf8, keystore, false);
      assertEquals(0L, duplicateHandle, "duplicate workspace open must return 0");

      long now = 1_800_010_000L;
      long initialGen = KoeNativeBridge.nativeSessionGeneration(handle);
      assertTrue(initialGen > 0, "initial generation must be > 0");

      String initialSnap = utf8String(KoeNativeBridge.nativeSessionSnapshotJson(handle, now));
      assertContains(initialSnap, "\"version\":2", "snapshot must report ABI v2");

      String synced = dispatch(
          handle,
          "{\"type\":\"sync_app_metadata\",\"version\":\"2.9.0\",\"build\":\"101\",\"platform\":\"android\"}",
          now + 1);
      assertContains(synced, "\"error\":null", "sync_app_metadata must succeed");
      assertContains(synced, "\"id\":\"android\"", "platform.id must be android");
      assertContains(synced, "\"canIncludeSystemAudio\":false", "android must disable system audio");
      assertContains(synced, "\"nativeSpeechLabel\":\"Android 本机\"", "android speech label");

      String updateSnap = dispatch(handle, "{\"type\":\"check_app_update\"}", now + 2);
      assertContains(updateSnap, "\"error\":null", "check_app_update must not error");
      assertContains(updateSnap, "\"phase\":\"unavailable\"", "android self-update must be unavailable");

      String providerSnap = dispatch(
          handle,
          "{\"type\":\"configure_provider\",\"apiKey\":\"sk-qwen-jni-12345678\",\"deepseekApiKey\":\"sk-deepseek-jni-87654321\",\"model\":\"qwen-plus\"}",
          now + 3);
      assertContains(providerSnap, "\"error\":null", "configure_provider must succeed");
      assertTrue(preparedSlots.contains("qwen"), "expected op=5 prepare_for_slot for qwen");
      assertTrue(preparedSlots.contains("deepseek"), "expected op=5 prepare_for_slot for deepseek");

      failNextPrepare.set(true);
      String failedProviderSnap = dispatch(
          handle,
          "{\"type\":\"configure_provider\",\"apiKey\":\"sk-qwen-retry-999999\",\"model\":\"qwen-plus\"}",
          now + 4);
      assertContains(
          failedProviderSnap,
          "\"error\":\"无法读取或保存安全凭据，请重试读取安全配置。\"",
          "Java exception in onCredential must surface as sanitized runtime error");
      assertTrue(
          !failedProviderSnap.contains("simulated Android Keystore lock"),
          "raw Java exception text must not leak into snapshot");

      String supplementary = "闪记测试 \uD840\uDC00 \uD83C\uDF99\uFE0F";
      String noteCmd =
          "{\"type\":\"create_note\",\"title\":\"" + supplementary
              + "\",\"text\":\"" + supplementary + "\",\"stayOnPage\":true}";
      String noteSnap = dispatch(handle, noteCmd, now + 5);
      assertContains(noteSnap, "\"error\":null", "create_note with 4-byte UTF-8 must succeed");
      String refreshedSnap = utf8String(KoeNativeBridge.nativeSessionSnapshotJson(handle, now + 5));
      assertContains(refreshedSnap, supplementary, "4-byte supplementary UTF-8 must round-trip intact");

      String startedMic = dispatch(
          handle,
          "{\"type\":\"start_microphone\",\"inputId\":\"unlisted-android-mic\",\"clockNs\":1000000000}",
          now + 6);
      assertContains(startedMic, "\"error\":null", "start_microphone must succeed");
      String micObj = extractJsonObject(startedMic, "microphone");
      String recId = extractJsonString(micObj, "\"recordId\"\\s*:\\s*\"([^\"]+)\"");
      String sesId = extractJsonString(micObj, "\"sessionId\"\\s*:\\s*\"([^\"]+)\"");

      String readyMic = dispatch(
          handle,
          "{\"type\":\"microphone_started\",\"recordId\":\"" + recId
              + "\",\"sessionId\":\"" + sesId
              + "\",\"lane\":\"microphone\",\"sampleRate\":16000}",
          now + 6);
      assertContains(readyMic, "\"error\":null", "microphone_started must succeed");

      short[] pcmChunk = new short[1600];
      for (int i = 0; i < pcmChunk.length; i++) {
        pcmChunk[i] = (short) ((i * 29) - 1000);
      }
      long[] accepted = KoeNativeBridge.nativeSessionIngestPcm(
          handle,
          utf8(recId),
          utf8(sesId),
          utf8("microphone"),
          0L,
          0L,
          1_000_000_000L,
          true,
          pcmChunk,
          pcmChunk.length,
          now + 6);
      assertEquals(3, accepted.length, "PCM receipt must have 3 elements");
      assertTrue(accepted[0] > 0, "accepted PCM receipt generation must be > 0");
      assertEquals(1L, accepted[1], "accepted PCM next_sequence must be 1");
      assertEquals(0L, accepted[2], "accepted PCM status must be 0");

      long[] stale = KoeNativeBridge.nativeSessionIngestPcm(
          handle,
          utf8("stale-record-id"),
          utf8(sesId),
          utf8("microphone"),
          0L,
          0L,
          1_000_000_000L,
          true,
          pcmChunk,
          320,
          now + 6);
      assertEquals(0L, stale[1], "stale PCM next_sequence must be 0");
      assertEquals(1L, stale[2], "stale PCM status must be 1");

      short[] oversized = new short[8193];
      long[] rejectedOversized = KoeNativeBridge.nativeSessionIngestPcm(
          handle,
          utf8(recId),
          utf8(sesId),
          utf8("microphone"),
          1L,
          0L,
          1_100_000_000L,
          true,
          oversized,
          8193,
          now + 6);
      assertEquals(0L, rejectedOversized[0], "oversized PCM generation must be 0");
      assertEquals(0L, rejectedOversized[1], "oversized PCM next_sequence must be 0");
      assertEquals(2L, rejectedOversized[2], "oversized PCM status must be 2 (Rejected)");

      long[] rejectedShortLen = KoeNativeBridge.nativeSessionIngestPcm(
          handle,
          utf8(recId),
          utf8(sesId),
          utf8("microphone"),
          1L,
          0L,
          1_100_000_000L,
          true,
          new short[16],
          32,
          now + 6);
      assertEquals(2L, rejectedShortLen[2], "sampleCount > samples.length must be rejected");

      dispatch(handle, "{\"type\":\"stop_microphone\"}", now + 7);
      String savedMic = dispatch(
          handle,
          "{\"type\":\"microphone_stopped\",\"recordId\":\"" + recId
              + "\",\"sessionId\":\"" + sesId
              + "\",\"lane\":\"microphone\",\"sequence\":1,\"epoch\":0}",
          now + 7);
      assertContains(savedMic, "\"error\":null", "microphone_stopped must succeed");
      assertContains(savedMic, "\"source\":\"Android 麦克风\"", "saved mic record must use Android 麦克风 label");
      assertContains(savedMic, "\"title\":\"Android 麦克风录音\"", "saved mic record must use Android title");

      String playingSnap = dispatch(handle, "{\"type\":\"playback\",\"isPlaying\":true}", now + 8);
      String playbackObj = extractJsonObject(playingSnap, "playback");
      long reqId = Long.parseLong(
          extractJsonString(playbackObj, "\"requestId\"\\s*:\\s*([0-9]+)"));
      long[] playbackReceipt = KoeNativeBridge.nativeSessionReportPlaybackProgress(
          handle, utf8(recId), reqId, 45L, true, now + 8, now + 8);
      assertEquals(7, playbackReceipt.length, "playback receipt must have 7 elements");
      assertTrue(playbackReceipt[0] > playbackReceipt[1], "playback progress must advance generation");
      assertEquals(45L, playbackReceipt[2], "playback positionMs must be 45");
      assertEquals(now + 8, playbackReceipt[3], "playback nowEpochSec must match");
      assertEquals(1L, playbackReceipt[4], "playback isPlaying must be 1");
      assertEquals(1L, playbackReceipt[5], "playback applied must be 1");
      assertEquals(0L, playbackReceipt[6], "playback needsFullSnapshot must be 0");

      for (String event : new String[] {"scanning", "connecting", "ready"}) {
        String bleSnap = dispatch(
            handle,
            "{\"type\":\"device_event\",\"event\":\"" + event
                + "\",\"connectionId\":\"ble-jni\",\"deviceName\":\"D3200\"}",
            now + 9);
        assertContains(bleSnap, "\"error\":null", "device_event " + event + " must succeed");
      }
      byte[] bleTx = KoeNativeBridge.nativeSessionDrainBleTx(handle);
      assertTrue(bleTx != null && bleTx.length >= 4, "drainBleTx must return length-prefixed frames");
      int firstFrameLen = ByteBuffer.wrap(bleTx, 0, 4).order(ByteOrder.LITTLE_ENDIAN).getInt();
      assertTrue(firstFrameLen > 0 && 4 + firstFrameLen <= bleTx.length, "invalid BLE frame framing");
      byte[] bleTxEmpty = KoeNativeBridge.nativeSessionDrainBleTx(handle);
      assertEquals(0, bleTxEmpty.length, "second drainBleTx must be empty");

      long bleGen = KoeNativeBridge.nativeSessionIngestBle(
          handle, new byte[] {0x01, 0x02, 0x03, 0x04}, now + 10);
      assertTrue(bleGen > 0, "ingestBle must return generation > 0");

      dispatch(
          handle,
          "{\"type\":\"local_asr_readiness\",\"state\":\"ready\",\"message\":\"ok\"}",
          now + 11);
      dispatch(handle, "{\"type\":\"configure_speech\",\"engine\":\"apple_speech\"}", now + 11);
      String asrStart = dispatch(
          handle,
          "{\"type\":\"start_capture_mode\",\"mode\":\"quick_note\",\"stayOnPage\":true}",
          now + 11);
      String asrMicObj = extractJsonObject(asrStart, "microphone");
      String asrRec = extractJsonString(asrMicObj, "\"recordId\"\\s*:\\s*\"([^\"]+)\"");
      String asrSes = extractJsonString(asrMicObj, "\"sessionId\"\\s*:\\s*\"([^\"]+)\"");
      dispatch(
          handle,
          "{\"type\":\"microphone_started\",\"recordId\":\"" + asrRec
              + "\",\"sessionId\":\"" + asrSes
              + "\",\"lane\":\"microphone\",\"sampleRate\":16000}",
          now + 11);
      long[] asrPcm = KoeNativeBridge.nativeSessionIngestPcm(
          handle,
          utf8(asrRec),
          utf8(asrSes),
          utf8("microphone"),
          0L,
          0L,
          0L,
          false,
          new short[] {11, -22, 33, -44},
          4,
          now + 11);
      assertEquals(0L, asrPcm[2], "ASR PCM chunk must be accepted");
      dispatch(handle, "{\"type\":\"capture_action\",\"action\":\"end\"}", now + 11);
      dispatch(
          handle,
          "{\"type\":\"microphone_stopped\",\"recordId\":\"" + asrRec
              + "\",\"sessionId\":\"" + asrSes
              + "\",\"lane\":\"microphone\",\"sequence\":1,\"epoch\":0}",
          now + 11);

      byte[] asrBytes = KoeNativeBridge.nativeSessionDrainLocalAsr(handle);
      assertTrue(asrBytes != null && asrBytes.length > 0 && asrBytes[0] == 1,
          "drainLocalAsr must return non-empty binary effect");
      byte[] asrEmpty = KoeNativeBridge.nativeSessionDrainLocalAsr(handle);
      assertEquals(0, asrEmpty.length, "second drainLocalAsr must be empty");

      long polledGen = KoeNativeBridge.nativeSessionPollTimers(handle, 500L, now + 12);
      assertTrue(polledGen > 0, "pollTimers must return generation > 0");

      byte[] withNul = new byte[] {'{', 0, '}'};
      assertTrue(
          KoeNativeBridge.nativeSessionDispatchJson(handle, withNul, now + 12) == null,
          "dispatchJson must reject embedded NUL bytes");
      byte[] tooLarge = new byte[(4 * 1024 * 1024) + 1];
      assertTrue(
          KoeNativeBridge.nativeSessionDispatchJson(handle, tooLarge, now + 12) == null,
          "dispatchJson must reject commands > 4 MiB");

      assertTrue(KoeNativeBridge.nativeSessionDestroy(handle), "first destroy must return true");
      long destroyedHandle = handle;
      handle = 0;
      assertTrue(
          !KoeNativeBridge.nativeSessionDestroy(destroyedHandle),
          "second destroy must return false");
      assertEquals(
          0L,
          KoeNativeBridge.nativeSessionGeneration(destroyedHandle),
          "generation after destroy must be 0");
    } finally {
      if (handle != 0) {
        KoeNativeBridge.nativeSessionDestroy(handle);
      }
      deleteRecursively(tempDir);
    }
  }

  private static void testPlainSessionCreateAndDestroy() throws IOException {
    Path tempDir = Files.createTempDirectory("koe-jni-plain-");
    long handle = 0;
    try {
      handle = KoeNativeBridge.nativeSessionCreate(utf8(tempDir.toString()));
      assertTrue(handle != 0, "nativeSessionCreate must return nonzero handle");
      assertTrue(KoeNativeBridge.nativeSessionDestroy(handle), "plain destroy must return true");
      handle = 0;
    } finally {
      if (handle != 0) {
        KoeNativeBridge.nativeSessionDestroy(handle);
      }
      deleteRecursively(tempDir);
    }
  }

  private static void testNegativeLongInputsRejected() throws IOException {
    Path tempDir = Files.createTempDirectory("koe-jni-neg-");
    long handle = 0;
    try {
      handle = KoeNativeBridge.nativeSessionCreate(utf8(tempDir.toString()));
      assertTrue(handle > 0, "session handle must be positive");
      long now = 1_800_020_000L;

      assertTrue(!KoeNativeBridge.nativeSessionDestroy(-1L), "negative handle destroy must return false");
      assertTrue(!KoeNativeBridge.nativeSessionDestroy(0L), "zero handle destroy must return false");
      assertEquals(0L, KoeNativeBridge.nativeSessionGeneration(-1L), "negative handle generation must be 0");

      assertTrue(
          KoeNativeBridge.nativeSessionSnapshotJson(-1L, now) == null,
          "negative handle snapshotJson must return null");
      assertTrue(
          KoeNativeBridge.nativeSessionSnapshotJson(handle, -1L) == null,
          "negative nowEpochSec snapshotJson must return null");

      byte[] navCmd = utf8("{\"type\":\"navigate\",\"section\":\"records\"}");
      assertTrue(
          KoeNativeBridge.nativeSessionDispatchJson(-1L, navCmd, now) == null,
          "negative handle dispatchJson must return null");
      assertTrue(
          KoeNativeBridge.nativeSessionDispatchJson(handle, navCmd, -1L) == null,
          "negative nowEpochSec dispatchJson must return null");

      assertEquals(
          0L,
          KoeNativeBridge.nativeSessionIngestBle(-1L, new byte[] {1, 2}, now),
          "negative handle ingestBle must return 0");
      assertEquals(
          0L,
          KoeNativeBridge.nativeSessionIngestBle(handle, new byte[] {1, 2}, -1L),
          "negative nowEpochSec ingestBle must return 0");

      String startedMic = dispatch(
          handle,
          "{\"type\":\"start_microphone\",\"inputId\":\"mic\",\"clockNs\":1000000000}",
          now);
      String micObj = extractJsonObject(startedMic, "microphone");
      String recId = extractJsonString(micObj, "\"recordId\"\\s*:\\s*\"([^\"]+)\"");
      String sesId = extractJsonString(micObj, "\"sessionId\"\\s*:\\s*\"([^\"]+)\"");
      dispatch(
          handle,
          "{\"type\":\"microphone_started\",\"recordId\":\"" + recId
              + "\",\"sessionId\":\"" + sesId
              + "\",\"lane\":\"microphone\",\"sampleRate\":16000}",
          now);

      short[] pcm = new short[] {1, 2, 3, 4};
      long[][] badPcmReceipts = new long[][] {
          KoeNativeBridge.nativeSessionIngestPcm(
              -1L, utf8(recId), utf8(sesId), utf8("microphone"), 0L, 0L, 1L, true, pcm, 4, now),
          KoeNativeBridge.nativeSessionIngestPcm(
              handle, utf8(recId), utf8(sesId), utf8("microphone"), -1L, 0L, 1L, true, pcm, 4, now),
          KoeNativeBridge.nativeSessionIngestPcm(
              handle, utf8(recId), utf8(sesId), utf8("microphone"), 0L, -1L, 1L, true, pcm, 4, now),
          KoeNativeBridge.nativeSessionIngestPcm(
              handle, utf8(recId), utf8(sesId), utf8("microphone"), 0L, 0L, -1L, true, pcm, 4, now),
          KoeNativeBridge.nativeSessionIngestPcm(
              handle, utf8(recId), utf8(sesId), utf8("microphone"), 0L, 0L, 1L, true, pcm, 4, -1L),
      };
      for (int i = 0; i < badPcmReceipts.length; i++) {
        long[] r = badPcmReceipts[i];
        assertEquals(3, r.length, "rejected PCM receipt length at index " + i);
        assertEquals(0L, r[0], "rejected PCM generation must be 0 at index " + i);
        assertEquals(0L, r[1], "rejected PCM nextSequence must be 0 at index " + i);
        assertEquals(2L, r[2], "rejected PCM status must be 2 at index " + i);
      }

      long[] okPcm = KoeNativeBridge.nativeSessionIngestPcm(
          handle, utf8(recId), utf8(sesId), utf8("microphone"), 0L, 0L, 1_000_000_000L, true, pcm, 4, now);
      assertEquals(0L, okPcm[2], "valid PCM after rejected negative inputs must still succeed");

      dispatch(handle, "{\"type\":\"stop_microphone\"}", now + 1);
      dispatch(
          handle,
          "{\"type\":\"microphone_stopped\",\"recordId\":\"" + recId
              + "\",\"sessionId\":\"" + sesId
              + "\",\"lane\":\"microphone\",\"sequence\":1,\"epoch\":0}",
          now + 1);
      String playingSnap = dispatch(handle, "{\"type\":\"playback\",\"isPlaying\":true}", now + 2);
      long reqId = Long.parseLong(
          extractJsonString(extractJsonObject(playingSnap, "playback"), "\"requestId\"\\s*:\\s*([0-9]+)"));

      long[][] badPlaybackReceipts = new long[][] {
          KoeNativeBridge.nativeSessionReportPlaybackProgress(-1L, utf8(recId), reqId, 10L, true, now + 2, now + 2),
          KoeNativeBridge.nativeSessionReportPlaybackProgress(handle, utf8(recId), -1L, 10L, true, now + 2, now + 2),
          KoeNativeBridge.nativeSessionReportPlaybackProgress(handle, utf8(recId), reqId, -1L, true, now + 2, now + 2),
          KoeNativeBridge.nativeSessionReportPlaybackProgress(handle, utf8(recId), reqId, 10L, true, -1L, now + 2),
          KoeNativeBridge.nativeSessionReportPlaybackProgress(handle, utf8(recId), reqId, 10L, true, now + 2, -1L),
      };
      for (int i = 0; i < badPlaybackReceipts.length; i++) {
        long[] r = badPlaybackReceipts[i];
        assertEquals(7, r.length, "rejected playback receipt length at index " + i);
        assertEquals(0L, r[0], "rejected playback generation must be 0 at index " + i);
        assertEquals(0L, r[5], "rejected playback applied must be 0 at index " + i);
      }

      assertEquals(0L, KoeNativeBridge.nativeSessionPollTimers(-1L, 100L, now + 3), "negative handle pollTimers must return 0");
      assertEquals(0L, KoeNativeBridge.nativeSessionPollTimers(handle, -1L, now + 3), "negative elapsedMs pollTimers must return 0");
      assertEquals(0L, KoeNativeBridge.nativeSessionPollTimers(handle, 100L, -1L), "negative nowEpochSec pollTimers must return 0");

      byte[] badBleTx = KoeNativeBridge.nativeSessionDrainBleTx(-1L);
      assertTrue(badBleTx != null && badBleTx.length == 0, "negative handle drainBleTx must return empty bytes");
      byte[] badAsr = KoeNativeBridge.nativeSessionDrainLocalAsr(-1L);
      assertTrue(badAsr != null && badAsr.length == 0, "negative handle drainLocalAsr must return empty bytes");
    } finally {
      if (handle != 0) {
        KoeNativeBridge.nativeSessionDestroy(handle);
      }
      deleteRecursively(tempDir);
    }
  }

  private static void testConcurrentSessionDestroy() throws Exception {
    final int rounds = 12;
    final int threads = 8;
    for (int round = 0; round < rounds; round++) {
      Path tempDir = Files.createTempDirectory("koe-jni-concurrent-destroy-");
      long handle = 0;
      try {
        Map<String, String> store = Collections.synchronizedMap(new HashMap<>());
        KoeNativeBridge.CredentialBridge bridge = (op, refBytes, valBytes) -> {
          String ref = refBytes == null ? "" : new String(refBytes, StandardCharsets.UTF_8);
          String val = valBytes == null ? "" : new String(valBytes, StandardCharsets.UTF_8);
          if (op == 0) {
            String found = store.get(ref);
            return found == null ? null : found.getBytes(StandardCharsets.UTF_8);
          }
          if (op == 1) {
            store.put(ref, val);
            return ref.getBytes(StandardCharsets.UTF_8);
          }
          if (op == 5) {
            return ("slot-" + ref).getBytes(StandardCharsets.UTF_8);
          }
          return new byte[0];
        };
        handle = KoeNativeBridge.nativeSessionCreateWithCredentials(utf8(tempDir.toString()), bridge, false);
        assertTrue(handle > 0, "concurrent destroy session creation must succeed");
        dispatch(
            handle,
            "{\"type\":\"configure_provider\",\"apiKey\":\"sk-concurrent-12345678\",\"model\":\"qwen-plus\"}",
            1_800_030_000L);

        final long targetHandle = handle;
        CyclicBarrier barrier = new CyclicBarrier(threads);
        AtomicInteger destroyedCount = new AtomicInteger();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        List<Thread> workers = new ArrayList<>();
        for (int t = 0; t < threads; t++) {
          Thread worker = new Thread(() -> {
            try {
              barrier.await();
              if (KoeNativeBridge.nativeSessionDestroy(targetHandle)) {
                destroyedCount.incrementAndGet();
              }
            } catch (Throwable ex) {
              failure.compareAndSet(null, ex);
            }
          }, "destroy-racer-" + round + "-" + t);
          workers.add(worker);
          worker.start();
        }
        for (Thread worker : workers) {
          worker.join(10_000);
          assertTrue(!worker.isAlive(), "concurrent destroy worker timed out");
        }
        if (failure.get() != null) {
          throw new AssertionError("concurrent destroy threw", failure.get());
        }
        assertEquals(1L, destroyedCount.get(), "exactly one thread must destroy session in round " + round);
        handle = 0;
      } finally {
        if (handle != 0) {
          KoeNativeBridge.nativeSessionDestroy(handle);
        }
        deleteRecursively(tempDir);
      }
    }
  }

  private static String dispatch(long handle, String commandJson, long nowEpochSec) {
    byte[] raw = KoeNativeBridge.nativeSessionDispatchJson(handle, utf8(commandJson), nowEpochSec);
    assertTrue(raw != null && raw.length > 0, "dispatchJson returned null/empty for " + commandJson);
    return utf8String(raw);
  }

  private static byte[] utf8(String text) {
    return text.getBytes(StandardCharsets.UTF_8);
  }

  private static String utf8String(byte[] bytes) {
    assertTrue(bytes != null, "unexpected null byte array");
    return new String(bytes, StandardCharsets.UTF_8);
  }

  private static String extractJsonObject(String json, String key) {
    String marker = "\"" + key + "\":{";
    int idx = json.indexOf(marker);
    assertTrue(idx >= 0, "object key not found in JSON: " + key);
    int start = idx + marker.length() - 1;
    int depth = 0;
    boolean inString = false;
    boolean escaped = false;
    for (int i = start; i < json.length(); i++) {
      char c = json.charAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
      } else if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          return json.substring(start, i + 1);
        }
      }
    }
    throw new AssertionError("unterminated JSON object for key: " + key);
  }

  private static String extractJsonString(String json, String regex) {
    Matcher matcher = Pattern.compile(regex).matcher(json);
    assertTrue(matcher.find(), "regex not found in JSON: " + regex + " in " + json);
    return matcher.group(1);
  }

  private static void assertContains(String haystack, String needle, String message) {
    if (!haystack.contains(needle)) {
      throw new AssertionError(message + " (expected substring " + needle + " in: " + haystack + ")");
    }
  }

  private static void assertTrue(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }

  private static void assertEquals(long expected, long actual, String message) {
    if (expected != actual) {
      throw new AssertionError(message + " (expected=" + expected + ", actual=" + actual + ")");
    }
  }

  private static void assertEquals(String expected, String actual, String message) {
    if ((expected == null && actual != null) || (expected != null && !expected.equals(actual))) {
      throw new AssertionError(message + " (expected=" + expected + ", actual=" + actual + ")");
    }
  }

  private static void deleteRecursively(Path root) throws IOException {
    if (!Files.exists(root)) {
      return;
    }
    Files.walkFileTree(root, new SimpleFileVisitor<Path>() {
      @Override
      public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
        Files.deleteIfExists(file);
        return FileVisitResult.CONTINUE;
      }

      @Override
      public FileVisitResult postVisitDirectory(Path dir, IOException exc) throws IOException {
        Files.deleteIfExists(dir);
        return FileVisitResult.CONTINUE;
      }
    });
  }
}
