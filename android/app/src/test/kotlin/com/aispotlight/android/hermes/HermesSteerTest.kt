package com.aispotlight.android.hermes

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Contract test for [HermesSteer] — the Kotlin half of the mid-turn
 * follow-up frame. `shared/fixtures/steer-frame.json` at the REPO root is
 * the shared source of truth; the Swift twin
 * (`scripts/SteerContractTest.swift`) runs the same cases. Run both via
 * `scripts/test-attach-note.sh`.
 */
class HermesSteerTest {

    private val fixture: JSONObject by lazy {
        // Unit tests run with the module dir as CWD — walk up to the repo
        // root (the dir holding shared/fixtures).
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "shared/fixtures/steer-frame.json").exists()) {
            dir = dir.parentFile
        }
        val file = File(dir ?: error("shared/fixtures/steer-frame.json not found above CWD"),
            "shared/fixtures/steer-frame.json")
        JSONObject(file.readText())
    }

    /** `{frame}` in a case stands for the fixture's frame. */
    private fun expand(text: String): String = text.replace("{frame}", fixture.getString("frame"))

    private fun strings(array: JSONArray): List<String> = (0 until array.length()).map { array.getString(it) }

    @Test
    fun framePinned() {
        assertEquals(fixture.getString("frame"), HermesSteer.FRAME)
    }

    @Test
    fun framed() {
        val cases = fixture.getJSONArray("framed")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val wire = HermesSteer.framed(case.getString("text"))
            assertEquals(name, expand(case.getString("wire")), wire)
            // Round-trip: the words come back out alone.
            assertEquals("$name (round-trip)", listOf(case.getString("text")), HermesSteer.pieces(wire))
        }
    }

    @Test
    fun pieces() {
        val cases = fixture.getJSONArray("pieces")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            assertEquals(case.getString("name"), strings(case.getJSONArray("pieces")),
                HermesSteer.pieces(expand(case.getString("text"))))
        }
    }

    @Test
    fun unframed() {
        val cases = fixture.getJSONArray("unframed")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            assertEquals(case.getString("name"), case.getString("words"),
                HermesSteer.unframed(expand(case.getString("text"))))
        }
    }

    @Test
    fun extract() {
        val cases = fixture.getJSONArray("extract")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            assertEquals(case.getString("name"), strings(case.getJSONArray("texts")),
                HermesSteer.texts(expand(case.getString("content"))))
        }
    }
}
