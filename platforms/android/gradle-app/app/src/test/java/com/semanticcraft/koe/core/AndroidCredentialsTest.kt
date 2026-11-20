package com.semanticcraft.koe.core

import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AndroidCredentialsTest {
    private fun utf8(text: String): ByteArray = text.toByteArray(StandardCharsets.UTF_8)

    private fun str(bytes: ByteArray?): String {
        assertNotNull(bytes)
        return String(bytes!!, StandardCharsets.UTF_8)
    }

    @Test
    fun isolatedLifecycleSupportsQwenDeepseekAndSupplementaryUtf8() {
        val creds = AndroidCredentials.forIsolated()
        assertTrue(creds.isolated)

        val qwenRef = str(creds.onCredential(AndroidCredentials.OP_PREPARE, utf8("qwen"), utf8("sk-qwen-1")))
        assertTrue(qwenRef.startsWith("isolated-qwen-"))
        assertNull(creds.onCredential(AndroidCredentials.OP_READ, utf8(qwenRef), utf8("")))

        val createdQwen = str(creds.onCredential(AndroidCredentials.OP_CREATE, utf8(qwenRef), utf8("sk-qwen-1")))
        assertEquals(qwenRef, createdQwen)
        assertEquals("sk-qwen-1", str(creds.onCredential(AndroidCredentials.OP_READ, utf8(qwenRef), utf8(""))))

        val supplementarySecret = "sk-ds-\uD840\uDC00-\uD83C\uDF99\uFE0F-密钥"
        val dsRef = str(creds.onCredential(AndroidCredentials.OP_PREPARE, utf8("deepseek"), utf8(supplementarySecret)))
        assertTrue(dsRef.startsWith("isolated-deepseek-"))
        assertEquals(dsRef, str(creds.onCredential(AndroidCredentials.OP_CREATE, utf8(dsRef), utf8(supplementarySecret))))
        assertEquals(
            supplementarySecret,
            str(creds.onCredential(AndroidCredentials.OP_READ, utf8(dsRef), utf8(""))),
        )

        val defaultRef = str(creds.onCredential(AndroidCredentials.OP_PREPARE, utf8(""), utf8("sk-default")))
        assertTrue(defaultRef.startsWith("isolated-default-"))
        assertEquals(defaultRef, str(creds.onCredential(AndroidCredentials.OP_CREATE, utf8(defaultRef), utf8("sk-default"))))

        assertNull(creds.onCredential(AndroidCredentials.OP_READ_LEGACY, utf8(""), utf8("")))
        assertArrayEquals(ByteArray(0), creds.onCredential(AndroidCredentials.OP_AUTHORIZE, utf8(qwenRef), utf8("")))
        assertArrayEquals(ByteArray(0), creds.onCredential(AndroidCredentials.OP_AUTHORIZE, utf8(""), utf8("")))

        assertArrayEquals(ByteArray(0), creds.onCredential(AndroidCredentials.OP_DELETE, utf8(qwenRef), utf8("")))
        assertNull(creds.onCredential(AndroidCredentials.OP_READ, utf8(qwenRef), utf8("")))
        // Deleting an already-absent valid ref stays idempotent.
        assertArrayEquals(ByteArray(0), creds.onCredential(AndroidCredentials.OP_DELETE, utf8(qwenRef), utf8("")))
        assertEquals(supplementarySecret, str(creds.onCredential(AndroidCredentials.OP_READ, utf8(dsRef), utf8(""))))
    }

    @Test
    fun rejectsInvalidReferencesUnsupportedOpsAndNulBytes() {
        val creds = AndroidCredentials.forIsolated()
        val validRef = str(creds.onCredential(AndroidCredentials.OP_PREPARE, utf8("qwen"), utf8("secret")))

        val invalidRefs = listOf(
            "",
            "bad-ref",
            "../escape",
            "isolated-qwen-not-a-uuid",
            "android-qwen-123e4567-e89b-12d3-a456-426614174000",
        )
        for (bad in invalidRefs) {
            for (op in listOf(
                AndroidCredentials.OP_READ,
                AndroidCredentials.OP_CREATE,
                AndroidCredentials.OP_DELETE,
            )) {
                assertThrowsIllegalArgument("op=$op ref=$bad") {
                    creds.onCredential(op, utf8(bad), utf8("secret"))
                }
            }
        }

        assertThrowsIllegalArgument("invalid slot") {
            creds.onCredential(AndroidCredentials.OP_PREPARE, utf8("openai"), utf8("secret"))
        }
        assertThrowsIllegalArgument("embedded NUL in value") {
            creds.onCredential(AndroidCredentials.OP_CREATE, utf8(validRef), byteArrayOf('a'.code.toByte(), 0, 'b'.code.toByte()))
        }
        assertThrowsIllegalArgument("unsupported op 99") {
            creds.onCredential(99, utf8(validRef), utf8(""))
        }
        assertThrowsIllegalArgument("unsupported op -1") {
            creds.onCredential(-1, utf8(validRef), utf8(""))
        }
    }

    @Test
    fun releaseBackendReturnsNullOnlyOnMissingAndPropagatesKeystoreFailures() {
        val storage = HashMap<String, ByteArray>()
        var failReads = false
        var failVerify = false

        val backend = object : SecretStorageBackend {
            override fun read(reference: String): ByteArray? {
                if (failReads) throw GeneralSecurityException("simulated Keystore locked")
                return storage[reference]?.copyOf()
            }

            override fun write(reference: String, plaintext: ByteArray) {
                storage[reference] = plaintext.copyOf()
            }

            override fun delete(reference: String) {
                storage.remove(reference)
            }

            override fun verifyAvailable() {
                if (failVerify) throw GeneralSecurityException("simulated Keystore unavailable")
            }
        }

        val creds = AndroidCredentials.forBackend(backend)
        assertFalse(creds.isolated)

        val ref = str(creds.onCredential(AndroidCredentials.OP_PREPARE, utf8("qwen"), utf8("sk-prod-1")))
        assertTrue(ref.startsWith("android-qwen-"))
        assertNull(creds.onCredential(AndroidCredentials.OP_READ, utf8(ref), utf8("")))

        assertEquals(ref, str(creds.onCredential(AndroidCredentials.OP_CREATE, utf8(ref), utf8("sk-prod-1"))))
        assertEquals("sk-prod-1", str(creds.onCredential(AndroidCredentials.OP_READ, utf8(ref), utf8(""))))

        failReads = true
        try {
            creds.onCredential(AndroidCredentials.OP_READ, utf8(ref), utf8(""))
            fail("expected Keystore failure to throw instead of returning null")
        } catch (expected: GeneralSecurityException) {
            assertTrue(expected.message?.contains("Keystore") == true)
        }
        failReads = false

        failVerify = true
        try {
            creds.onCredential(AndroidCredentials.OP_AUTHORIZE, utf8(ref), utf8(""))
            fail("expected authorize Keystore failure to throw")
        } catch (expected: GeneralSecurityException) {
            assertTrue(expected.message?.contains("Keystore") == true)
        }
        failVerify = false

        assertArrayEquals(ByteArray(0), creds.onCredential(AndroidCredentials.OP_DELETE, utf8(ref), utf8("")))
        assertNull(creds.onCredential(AndroidCredentials.OP_READ, utf8(ref), utf8("")))
    }

    private fun assertThrowsIllegalArgument(label: String, block: () -> Unit) {
        try {
            block()
            fail("expected IllegalArgumentException for $label")
        } catch (_: IllegalArgumentException) {
            // Expected boundary rejection.
        }
    }
}
