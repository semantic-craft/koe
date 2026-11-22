package com.semanticcraft.koe.ui

import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.semanticcraft.koe.KoeApplication
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
        app.resetSessionForTests()
        try {
            app.bridgeFactory = { KoeComposeUiTest.FakeUiBridgeClient() }
            val firstStore = app.applyLaunchIntent(Intent())
            val defaultTrace = File(app.filesDir, KoeApplication.TRACE_FILE_NAME)
            assertFalse(defaultTrace.exists())
            assertTrue(firstStore.handle != 0L)

            app.applyLaunchIntent(Intent().putExtra("koe_trace_path", "diagnostic.json"))
            val explicitTrace = File(app.filesDir, "traces/diagnostic.json")
            val deadline = System.nanoTime() + 5_000_000_000L
            while (!explicitTrace.isFile && System.nanoTime() < deadline) Thread.sleep(10)
            val content = explicitTrace.readText()
            assertTrue(content.startsWith("["))
            assertTrue(content.contains("sync_app_metadata"))
            assertFalse(defaultTrace.exists())
        } finally {
            app.resetSessionForTests()
        }
    }
}
