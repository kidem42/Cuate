package com.aispotlight.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Kotlin twin of scripts/DocumentContractTest.swift — same cases. */
class DocumentContractTest {
    private val mb = 1024L * 1024

    @Test fun preflightRules() {
        assertEquals(DocumentPreflight.Verdict.Accepted,
            DocumentPreflight.check("pdf", 10 * mb, false, 0, 0))
        assertEquals(DocumentPreflight.Verdict.Accepted,
            DocumentPreflight.check("DOCX", 100, false, 2, 0))
        assertEquals(DocumentPreflight.Verdict.TooManyDocuments(3),
            DocumentPreflight.check("docx", 100, false, 3, 0))
        assertEquals(DocumentPreflight.Verdict.UnsupportedType("exe"),
            DocumentPreflight.check("exe", 100, false, 0, 0))
        assertEquals(DocumentPreflight.Verdict.UnsupportedType("png"),
            DocumentPreflight.check("png", 100, false, 0, 0))
        assertEquals(DocumentPreflight.Verdict.EmptyFile,
            DocumentPreflight.check("pdf", 0, false, 0, 0))
        assertEquals(DocumentPreflight.Verdict.Encrypted,
            DocumentPreflight.check("pdf", 100, true, 0, 0))
        assertEquals(DocumentPreflight.Verdict.FileTooLarge(50 * mb),
            DocumentPreflight.check("pdf", 51 * mb, false, 0, 0))
        assertEquals(DocumentPreflight.Verdict.MessageTooLarge(50 * mb),
            DocumentPreflight.check("pdf", 30 * mb, false, 1, 25 * mb))
        assertTrue(DocumentPreflight.isDocumentMime("application/pdf"))
        assertFalse(DocumentPreflight.isDocumentMime("image/png"))
        assertTrue(DocumentPreflight.isLocallyReadable("application/pdf"))
        assertFalse(DocumentPreflight.isLocallyReadable(DocumentPreflight.mimeType("xlsx")!!))
        assertEquals("application/pdf", DocumentPreflight.documentMime("a.PDF", "application/octet-stream"))
        assertNull(DocumentPreflight.documentMime("a.exe", "application/octet-stream"))
    }

    private val joined = DocumentTextQuery.join(listOf("First page text.", "", "Third page.\n\nSecond paragraph."))

    @Test fun pageMarkersRoundTrip() {
        val pages = DocumentTextQuery.pages(joined)
        assertEquals(3, pages.size)
        assertEquals("First page text.", pages[0])
        assertEquals("", pages[1])
        assertTrue(pages[2].startsWith("Third page."))
        assertEquals(1, DocumentTextQuery.pages("plain text without markers").size)
    }

    @Test fun pageRanges() {
        assertEquals(3..5, DocumentTextQuery.parsePageRange("3-5", 10))
        assertEquals(7..7, DocumentTextQuery.parsePageRange("7", 10))
        assertEquals(2..4, DocumentTextQuery.parsePageRange(" 2 – 4 ", 10))
        assertEquals(8..10, DocumentTextQuery.parsePageRange("8-20", 10))
        assertNull(DocumentTextQuery.parsePageRange("12", 10))
        assertNull(DocumentTextQuery.parsePageRange("abc", 10))
        assertNull(DocumentTextQuery.parsePageRange(null, 10))
    }

    @Test fun searchHits() {
        val hits = DocumentTextQuery.search(joined, "PAGE")
        assertEquals(2, hits.size)
        assertEquals(1, hits[0].page)
        assertEquals(3, hits[1].page)
        assertTrue(DocumentTextQuery.search(joined, "   ").isEmpty())
    }

    @Test fun rendering() {
        val whole = DocumentTextQuery.render("a.pdf", joined, null, null)
        assertTrue(whole.startsWith("a.pdf — 3 pages"))
        assertTrue(whole.contains("[Page 3]"))
        val ranged = DocumentTextQuery.render("a.pdf", joined, "3", null)
        assertTrue(ranged.contains("pages 3-3") && ranged.contains("Third page.") && !ranged.contains("First page"))
        assertTrue(DocumentTextQuery.render("a.pdf", joined, "99", null).contains("Invalid page range"))
        val queried = DocumentTextQuery.render("a.pdf", joined, null, "second")
        assertTrue(queried.contains("1 match") && queried.contains("Page 3:"))
        assertTrue(DocumentTextQuery.render("a.pdf", joined, null, "zzz").contains("No matches"))
        val long = "word ".repeat(20_000)
        val capped = DocumentTextQuery.capped(long)
        assertTrue(capped.length <= DocumentTextQuery.MAX_RESULT_CHARACTERS + DocumentTextQuery.TRUNCATION_NOTE.length + 1)
        assertTrue(capped.endsWith(DocumentTextQuery.TRUNCATION_NOTE))
        assertEquals("short", DocumentTextQuery.capped("short"))
    }
}
