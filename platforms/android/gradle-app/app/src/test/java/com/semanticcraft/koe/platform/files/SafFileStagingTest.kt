package com.semanticcraft.koe.platform.files

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SafFileStagingTest {
    @Test
    fun resolveImportFileNameAcceptsAllowedExtensionsCaseInsensitively() {
        assertEquals(256L * 1024L * 1024L, MAX_IMPORT_BYTES)
        assertEquals(setOf("wav", "txt", "md", "koepack"), ALLOWED_IMPORT_EXTENSIONS)

        assertEquals(ImportFileNameResult.Valid("meeting.wav"), resolveImportFileName("meeting.wav", null))
        assertEquals(ImportFileNameResult.Valid("notes.txt"), resolveImportFileName("notes.txt", "text/plain"))
        assertEquals(ImportFileNameResult.Valid("summary.md"), resolveImportFileName("summary.md", "text/markdown"))
        assertEquals(
            ImportFileNameResult.Valid("archive.koepack"),
            resolveImportFileName("archive.koepack", "application/octet-stream"),
        )
        assertEquals(ImportFileNameResult.Valid("VOICE.WAV"), resolveImportFileName("VOICE.WAV", null))
        assertEquals(ImportFileNameResult.Valid("周会纪要.MD"), resolveImportFileName("  周会纪要.MD  ", null))
    }

    @Test
    fun resolveImportFileNameInfersExtensionFromMimeForMissingExtensionOrBlankName() {
        assertEquals(ImportFileNameResult.Valid("会议录音.wav"), resolveImportFileName("会议录音", "audio/wav"))
        assertEquals(ImportFileNameResult.Valid("会议录音.wav"), resolveImportFileName("会议录音", "audio/x-wav"))
        assertEquals(ImportFileNameResult.Valid("项目笔记.md"), resolveImportFileName("项目笔记", "text/markdown"))
        assertEquals(
            ImportFileNameResult.Valid("项目笔记.md"),
            resolveImportFileName("项目笔记", "text/x-markdown; charset=utf-8"),
        )
        assertEquals(
            ImportFileNameResult.Valid("速记.txt"),
            resolveImportFileName("速记", "text/plain; charset=utf-8"),
        )

        assertEquals(ImportFileNameResult.Valid("导入音频.wav"), resolveImportFileName(null, "audio/wav"))
        assertEquals(ImportFileNameResult.Valid("导入音频.wav"), resolveImportFileName("   ", "audio/x-wav"))
        assertEquals(ImportFileNameResult.Valid("导入文稿.md"), resolveImportFileName("", "text/markdown"))
        assertEquals(ImportFileNameResult.Valid("导入文稿.md"), resolveImportFileName(null, "text/x-markdown"))
        assertEquals(ImportFileNameResult.Valid("导入文本.txt"), resolveImportFileName("", "text/plain"))

        assertEquals(ImportFileNameResult.UnsupportedExtension, resolveImportFileName(null, "application/pdf"))
        assertEquals(ImportFileNameResult.UnsupportedExtension, resolveImportFileName("", null))
    }

    @Test
    fun resolveImportFileNameRejectsUnsupportedExtensions() {
        assertEquals(ImportFileNameResult.UnsupportedExtension, resolveImportFileName("clip.mp3", "audio/mpeg"))
        assertEquals(ImportFileNameResult.UnsupportedExtension, resolveImportFileName("clip.mp3", "audio/wav"))
        assertEquals(ImportFileNameResult.UnsupportedExtension, resolveImportFileName("doc.pdf", "application/pdf"))
        assertEquals(ImportFileNameResult.UnsupportedExtension, resolveImportFileName("notes.", "text/plain"))
        assertEquals(
            ImportFileNameResult.UnsupportedExtension,
            resolveImportFileName("untitled", "application/octet-stream"),
        )
    }

    @Test
    fun resolveImportFileNameRejectsTraversalSlashDotPrefixAndControlChars() {
        val rejectedNames = listOf(
            "../secret.wav",
            "dir/file.wav",
            "dir\\file.wav",
            ".",
            "..",
            ".hidden.wav",
            "..hidden.wav",
            "foo..bar.txt",
            "bad\u0000name.wav",
            "\u0000name.wav",
            "name.wav\u0000",
            "bad\nname.txt",
            "bad\u001fname.md",
        )
        rejectedNames.forEach { raw ->
            assertEquals("expected InvalidPath for $raw", ImportFileNameResult.InvalidPath, resolveImportFileName(raw, "audio/wav"))
        }
    }

    @Test
    fun sanitizeExportFileNameMatchesMacRulesAndStripsUnsafeCharacters() {
        assertEquals("Koe 记录.md", sanitizeExportFileName(null))
        assertEquals("Koe 记录.md", sanitizeExportFileName("   "))
        assertEquals("Koe 记录.md", sanitizeExportFileName(".md"))
        assertEquals("Koe 记录.md", sanitizeExportFileName("..."))
        assertEquals("周会纪要.md", sanitizeExportFileName("周会纪要"))
        assertEquals("周会纪要.md", sanitizeExportFileName("周会纪要.md"))
        assertEquals("周会纪要.md", sanitizeExportFileName("周会纪要.MD"))
        assertEquals("Koe-2026-11-20.md", sanitizeExportFileName("  Koe-2026-11-20.md  "))
        assertEquals("leading.dot.md", sanitizeExportFileName("..leading.dot.md"))
        assertEquals(
            "Q1-Q2- 复盘-整理------a-.md",
            sanitizeExportFileName("Q1/Q2: 复盘*整理?\"<>|\\a\u0007"),
        )
    }

    @Test
    fun stageInputStreamToFilePreservesExactFileNameInIsolatedRunDirs() {
        val root = Files.createTempDirectory("koe-saf-stage-ok").toFile()
        try {
            val payload = "第一段会议原文\n第二段结论".toByteArray(Charsets.UTF_8)
            val first = stageInputStreamToFile(ByteArrayInputStream(payload), root, "周会纪要.md")
            val second = stageInputStreamToFile(ByteArrayInputStream(payload), root, "周会纪要.md")

            assertTrue(first is StageImportResult.Success)
            assertTrue(second is StageImportResult.Success)
            val s1 = first as StageImportResult.Success
            val s2 = second as StageImportResult.Success

            assertEquals("周会纪要.md", s1.file.name)
            assertEquals(s1.runDir.canonicalFile, s1.file.parentFile)
            assertArrayEquals(payload, s1.file.readBytes())
            assertNotEquals(s1.runDir.canonicalPath, s2.runDir.canonicalPath)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun stageInputStreamToFileEnforcesMaxBytesAndDeletesRunDirOnOverflow() {
        val root = Files.createTempDirectory("koe-saf-stage-limit").toFile()
        try {
            val exactBytes = ByteArray(1024) { (it % 127).toByte() }
            val exactResult = stageInputStreamToFile(
                input = ByteArrayInputStream(exactBytes),
                stagingRoot = root,
                fileName = "exact.wav",
                maxBytes = 1024L,
            )
            assertTrue(exactResult is StageImportResult.Success)
            (exactResult as StageImportResult.Success).runDir.deleteRecursively()

            val overBytes = ByteArray(150 * 1024) { 42 }
            val overResult = stageInputStreamToFile(
                input = ByteArrayInputStream(overBytes),
                stagingRoot = root,
                fileName = "too-big.wav",
                maxBytes = 100L * 1024L,
            )
            assertEquals(StageImportResult.TooLarge, overResult)
            assertTrue("overflow staging dir must be removed", root.listFiles().orEmpty().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun stageInputStreamToFileCleansUpOnReadFailureAndUnsafeTargetName() {
        val root = Files.createTempDirectory("koe-saf-stage-err").toFile()
        try {
            val failingStream = object : InputStream() {
                private var reads = 0
                override fun read(): Int = throw IOException("simulated failure")
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (reads == 0) {
                        reads += 1
                        b[off] = 1
                        return 1
                    }
                    throw IOException("stream interrupted")
                }
            }
            val ioErr = stageInputStreamToFile(failingStream, root, "broken.wav")
            assertTrue(ioErr is StageImportResult.IoError)
            assertTrue("io error staging dir must be removed", root.listFiles().orEmpty().isEmpty())

            val traversalErr = stageInputStreamToFile(ByteArrayInputStream(byteArrayOf(1, 2)), root, "../escape.wav")
            assertTrue(traversalErr is StageImportResult.IoError)
            assertTrue("traversal staging dir must be removed", root.listFiles().orEmpty().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }
}
