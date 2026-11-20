# Keep JNI bridge entry points and callback interfaces invoked from native C++.
-keep class com.semanticcraft.koe.bridge.KoeNativeBridge { *; }
-keep interface com.semanticcraft.koe.bridge.KoeNativeBridge$CredentialBridge { *; }
-keep class * implements com.semanticcraft.koe.bridge.KoeNativeBridge$CredentialBridge {
    byte[] onCredential(int, byte[], byte[]);
}
