package com.semanticcraft.koe.ui

import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.semanticcraft.koe.KoeApplication
import com.semanticcraft.koe.core.HostSessionStore
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ReleaseTraceTest {
    @Test fun releaseLaunchWritesOnlyWhenGivenAnExplicitTracePath() {
        val app = ApplicationProvider.getApplicationContext<KoeApplication>()
        val workspace = File(app.filesDir, KoeApplication.DEFAULT_WORKSPACE_DIR)
        val store = HostSessionStore(workspace.path, bridge = KoeComposeUiTest.FakeUiBridgeClient())
        // Reuse an open session so the JVM test exercises the launch path without Android JNI.
        KoeApplication::class.java.getDeclaredField("currentStore").apply {
            isAccessible = true
            set(app, store)
        }
        app.applyLaunchIntent(Intent())
        val defaultTrace = File(app.filesDir, KoeApplication.TRACE_FILE_NAME)
        assertFalse(defaultTrace.exists())
        app.applyLaunchIntent(Intent().putExtra("koe_trace_path", "diagnostic.json"))
        val explicitTrace = File(app.filesDir, "traces/diagnostic.json")
        val deadline = System.nanoTime() + 5_000_000_000L
        while (!explicitTrace.isFile && System.nanoTime() < deadline) Thread.sleep(10)
        assertTrue(explicitTrace.readText().startsWith("["))
        assertFalse(defaultTrace.exists())
    }
}
