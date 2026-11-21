package com.semanticcraft.koe.ui

import android.content.ComponentName
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

internal fun createRobolectricComposeRule() = run {
    // The release APK omits the debug-only ui-test-manifest. Register the test host in this sandbox.
    val app = RuntimeEnvironment.getApplication()
    shadowOf(app.packageManager).addActivityIfNotPresent(ComponentName(app, ComponentActivity::class.java))
    createAndroidComposeRule<ComponentActivity>()
}
