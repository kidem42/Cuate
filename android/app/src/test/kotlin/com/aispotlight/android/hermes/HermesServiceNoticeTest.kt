package com.aispotlight.android.hermes

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Contract test for [HermesServiceNotice] and [HermesContinuationFrame].
 * `shared/fixtures/service-notices.json` at the REPO root is the shared
 * source of truth (texts rendered by the real Hermes 0.21.5 formatters);
 * the Swift twin (`scripts/ServiceNoticeContractTest.swift`) runs the same
 * cases. Run both via `scripts/test-attach-note.sh`.
 */
class HermesServiceNoticeTest {

    private val fixture: JSONObject by lazy {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "shared/fixtures/service-notices.json").exists()) {
            dir = dir.parentFile
        }
        val file = File(dir ?: error("shared/fixtures/service-notices.json not found above CWD"),
            "shared/fixtures/service-notices.json")
        JSONObject(file.readText())
    }

    private fun strings(array: JSONArray): List<String> = (0 until array.length()).map { array.getString(it) }

    private fun JSONObject.optText(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)

    @Test
    fun notices() {
        val cases = fixture.getJSONArray("notices")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val text = case.getString("text")
            assertTrue("$name: detected", HermesServiceNotice.isNotice(text))
            assertFalse("$name: not a continuation", HermesContinuationFrame.isContinuation(text))
            val notice = HermesServiceNotice.parse(text)
            assertNotNull("$name: parsed", notice)
            notice!!
            val kind = if (notice.kind == HermesServiceNotice.Kind.DELEGATION) "delegation" else "process"
            assertEquals("$name: kind", case.getString("kind"), kind)
            assertEquals("$name: tasks", case.getInt("tasks"), notice.tasks.size)
            assertEquals("$name: ok", case.getInt("ok"), notice.okCount)
            assertEquals("$name: fail", case.getInt("fail"), notice.failCount)
            assertEquals("$name: duration", case.optText("duration"), notice.durationText)
            assertEquals("$name: exit", case.optText("exit"), notice.exitText)
            case.optText("firstLabel")?.let { assertEquals("$name: first label", it, notice.tasks.first().label) }
            case.optText("firstGoal")?.let { assertEquals("$name: first goal", it, notice.tasks.first().goal) }
            val carried = notice.tasks.any { it.body.isNotEmpty() || it.goal.isNotEmpty() } ||
                !notice.body.isNullOrEmpty() || notice.metaLines.isNotEmpty()
            assertTrue("$name: content carried", carried)
        }
    }

    @Test
    fun plainTextIsNoNotice() {
        for (text in strings(fixture.getJSONArray("notNotices"))) {
            assertFalse(text, HermesServiceNotice.isNotice(text))
            assertNull(text, HermesServiceNotice.parse(text))
        }
    }

    @Test
    fun continuation() {
        val continuation = fixture.getJSONObject("continuation")
        assertEquals(continuation.getString("wire"), HermesContinuationFrame.WIRE)
        for (text in strings(continuation.getJSONArray("matches"))) {
            assertTrue(text, HermesContinuationFrame.isContinuation(text))
            assertFalse(text, HermesServiceNotice.isNotice(text))
        }
        for (text in strings(continuation.getJSONArray("others"))) {
            assertFalse(text, HermesContinuationFrame.isContinuation(text))
        }
    }
}
