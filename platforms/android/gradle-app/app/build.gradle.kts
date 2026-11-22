import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.semanticcraft.koe"
    compileSdk = 36
    buildToolsVersion = "35.0.0"
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.semanticcraft.koe"
        minSdk = 29
        targetSdk = 36
        versionCode = 17
        versionName = "2.7.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    val keystorePath = providers.environmentVariable("KOE_ANDROID_KEYSTORE_PATH").orNull
    val keystorePassword = providers.environmentVariable("KOE_ANDROID_KEYSTORE_PASSWORD").orNull
    val alias = providers.environmentVariable("KOE_ANDROID_KEY_ALIAS").orNull
    val aliasPassword = providers.environmentVariable("KOE_ANDROID_KEY_PASSWORD").orNull
    val releaseSigning = if (listOf(keystorePath, keystorePassword, alias, aliasPassword).all { !it.isNullOrBlank() }) {
        signingConfigs.create("environmentRelease") {
            storeFile = file(requireNotNull(keystorePath))
            storePassword = keystorePassword
            keyAlias = alias
            keyPassword = aliasPassword
        }
    } else null

    buildTypes {
        release {
            signingConfig = releaseSigning
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("github") {
            dimension = "distribution"
            buildConfigField("String", "KOE_DISTRIBUTION", "\"github\"")
            buildConfigField("boolean", "ALLOW_SELF_UPDATE", "true")
        }
        create("play") {
            dimension = "distribution"
            buildConfigField("String", "KOE_DISTRIBUTION", "\"play\"")
            buildConfigField("boolean", "ALLOW_SELF_UPDATE", "false")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    sourceSets.getByName("main").jniLibs.srcDirs("../../../../target/android/jniLibs")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        abortOnError = true
        warningsAsErrors = true
        checkReleaseBuilds = true
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}

composeCompiler {
    reportsDestination = layout.buildDirectory.dir("compose_compiler")
    metricsDestination = layout.buildDirectory.dir("compose_compiler")
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.04.01")
    implementation(composeBom)
    testImplementation(composeBom)

    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")

    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.compose.ui:ui-test-junit4")

    lintChecks("com.slack.lint.compose:compose-lint-checks:1.4.2")
}
