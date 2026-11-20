package com.semanticcraft.koe.core

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.semanticcraft.koe.bridge.KoeNativeBridge
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.util.Locale
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface SecretStorageBackend {
    fun read(reference: String): ByteArray?
    fun write(reference: String, plaintext: ByteArray)
    fun delete(reference: String)
    fun verifyAvailable()
}

class KeystoreAesGcmBackend(
    private val storageDir: File,
    private val keyAlias: String = DEFAULT_KEY_ALIAS,
) : SecretStorageBackend {
    override fun read(reference: String): ByteArray? {
        val file = resolveSafeFile(reference)
        if (!file.exists()) return null
        val blob = file.readBytes()
        if (blob.size < 1 + GCM_IV_BYTES + GCM_TAG_BYTES) {
            throw GeneralSecurityException("corrupt encrypted credential blob")
        }
        val ivLen = blob[0].toInt() and 0xFF
        if (ivLen != GCM_IV_BYTES || blob.size < 1 + ivLen + GCM_TAG_BYTES) {
            throw GeneralSecurityException("invalid GCM IV length")
        }
        val iv = blob.copyOfRange(1, 1 + ivLen)
        val ciphertext = blob.copyOfRange(1 + ivLen, blob.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateSecretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        val plaintext = cipher.doFinal(ciphertext)
        if (plaintext.size > AndroidCredentials.MAX_SECRET_BYTES) {
            throw GeneralSecurityException("decrypted credential exceeds limit")
        }
        return plaintext
    }

    override fun write(reference: String, plaintext: ByteArray) {
        if (!storageDir.exists() && !storageDir.mkdirs()) {
            throw IOException("failed to create credential storage directory")
        }
        val target = resolveSafeFile(reference)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
        val iv = cipher.iv
        if (iv == null || iv.size != GCM_IV_BYTES) {
            throw GeneralSecurityException("unexpected Keystore GCM IV length")
        }
        val ciphertext = cipher.doFinal(plaintext)
        val blob = ByteArray(1 + iv.size + ciphertext.size)
        blob[0] = iv.size.toByte()
        System.arraycopy(iv, 0, blob, 1, iv.size)
        System.arraycopy(ciphertext, 0, blob, 1 + iv.size, ciphertext.size)

        val tempFile = File(storageDir, ".${target.name}.${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(tempFile).use { stream ->
                stream.write(blob)
                stream.flush()
                stream.fd.sync()
            }
            try {
                Files.move(
                    tempFile.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    tempFile.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } catch (ex: Exception) {
            tempFile.delete()
            throw ex
        }
    }

    override fun delete(reference: String) {
        val file = resolveSafeFile(reference)
        if (file.exists() && !file.delete()) {
            throw IOException("failed to delete encrypted credential file")
        }
    }

    override fun verifyAvailable() {
        getOrCreateSecretKey()
    }

    private fun resolveSafeFile(reference: String): File {
        val canonicalDir = storageDir.canonicalFile
        val target = File(canonicalDir, "$reference.bin").canonicalFile
        if (target.parentFile != canonicalDir) {
            throw IllegalArgumentException("credential reference escapes storage directory")
        }
        return target
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE)
        keyStore.load(null)
        val existing = keyStore.getKey(keyAlias, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val DEFAULT_KEY_ALIAS = "com.semanticcraft.koe.provider.credentials.aes256gcm"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_BITS / 8
    }
}

class AndroidCredentials private constructor(
    val isolated: Boolean,
    private val backend: SecretStorageBackend?,
) : KoeNativeBridge.CredentialBridge {
    private val lock = Any()
    private val memory = HashMap<String, ByteArray>()

    override fun onCredential(
        operation: Int,
        reference: ByteArray?,
        value: ByteArray?,
    ): ByteArray? = synchronized(lock) {
        val ref = decodeValidatedUtf8(reference, allowEmpty = true)
        when (operation) {
            OP_READ -> {
                validateReference(ref)
                if (isolated) {
                    memory[ref]?.copyOf()
                } else {
                    val result = requireBackend().read(ref) ?: return@synchronized null
                    validatePayloadBytes(result)
                    result
                }
            }
            OP_CREATE -> {
                validateReference(ref)
                val rawValue = value ?: ByteArray(0)
                validatePayloadBytes(rawValue)
                decodeValidatedUtf8(rawValue, allowEmpty = true)
                if (isolated) {
                    memory[ref] = rawValue.copyOf()
                } else {
                    requireBackend().write(ref, rawValue)
                }
                ref.toByteArray(StandardCharsets.UTF_8)
            }
            OP_DELETE -> {
                validateReference(ref)
                if (isolated) {
                    memory.remove(ref)
                } else {
                    requireBackend().delete(ref)
                }
                ByteArray(0)
            }
            OP_READ_LEGACY -> null
            OP_AUTHORIZE -> {
                if (ref.isNotEmpty()) {
                    validateReference(ref)
                }
                if (!isolated) {
                    requireBackend().verifyAvailable()
                }
                ByteArray(0)
            }
            OP_PREPARE -> {
                val slotTag = normalizeSlot(ref)
                val prefix = if (isolated) ISOLATED_PREFIX else KEYSTORE_PREFIX
                val fresh = "$prefix-$slotTag-${UUID.randomUUID().toString().lowercase(Locale.US)}"
                fresh.toByteArray(StandardCharsets.UTF_8)
            }
            else -> throw IllegalArgumentException("unsupported credential operation: $operation")
        }
    }

    private fun requireBackend(): SecretStorageBackend =
        backend ?: throw IllegalStateException("keystore credential backend not configured")

    private fun normalizeSlot(rawSlot: String): String =
        when (rawSlot) {
            "" -> "default"
            "qwen" -> "qwen"
            "deepseek" -> "deepseek"
            else -> throw IllegalArgumentException("unsupported credential slot")
        }

    private fun validateReference(reference: String) {
        val pattern = if (isolated) ISOLATED_REF_REGEX else KEYSTORE_REF_REGEX
        if (!pattern.matches(reference)) {
            throw IllegalArgumentException("invalid credential reference")
        }
    }

    private fun validatePayloadBytes(bytes: ByteArray) {
        if (bytes.size > MAX_SECRET_BYTES) {
            throw IllegalArgumentException("credential payload exceeds max length")
        }
        if (bytes.any { it == 0.toByte() }) {
            throw IllegalArgumentException("credential payload contains NUL byte")
        }
    }

    private fun decodeValidatedUtf8(bytes: ByteArray?, allowEmpty: Boolean): String {
        if (bytes == null) {
            if (allowEmpty) return ""
            throw IllegalArgumentException("missing UTF-8 credential bytes")
        }
        validatePayloadBytes(bytes)
        val decoder = StandardCharsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return decoder.decode(ByteBuffer.wrap(bytes)).toString()
    }

    companion object {
        const val OP_READ = 0
        const val OP_CREATE = 1
        const val OP_DELETE = 2
        const val OP_READ_LEGACY = 3
        const val OP_AUTHORIZE = 4
        const val OP_PREPARE = 5
        const val MAX_SECRET_BYTES = 65_536

        private const val ISOLATED_PREFIX = "isolated"
        private const val KEYSTORE_PREFIX = "android"
        private const val UUID_PATTERN =
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        private val ISOLATED_REF_REGEX =
            Regex("^$ISOLATED_PREFIX-(?:qwen|deepseek|default)-$UUID_PATTERN$")
        private val KEYSTORE_REF_REGEX =
            Regex("^$KEYSTORE_PREFIX-(?:qwen|deepseek|default)-$UUID_PATTERN$")

        fun forIsolated(): AndroidCredentials = AndroidCredentials(isolated = true, backend = null)

        fun forKeystore(storageDir: File): AndroidCredentials =
            AndroidCredentials(isolated = false, backend = KeystoreAesGcmBackend(storageDir))

        fun forBackend(backend: SecretStorageBackend): AndroidCredentials =
            AndroidCredentials(isolated = false, backend = backend)
    }
}
