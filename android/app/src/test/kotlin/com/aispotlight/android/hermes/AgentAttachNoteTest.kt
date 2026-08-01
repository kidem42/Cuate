package com.aispotlight.android.hermes

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Contract test for [AgentAttachNote] — the Kotlin half of the
 * cross-device attach-note format. `shared/fixtures/attach-note.json` at
 * the REPO root is the shared source of truth; the Swift twin
 * (`scripts/AttachNoteContractTest.swift`) runs the same cases. Run both
 * via `scripts/test-attach-note.sh`.
 */
class AgentAttachNoteTest {

    private val fixture: JSONObject by lazy {
        // Unit tests run with the module dir as CWD — walk up to the repo
        // root (the dir holding shared/fixtures) so the test survives
        // being launched from either the repo or the android folder.
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "shared/fixtures/attach-note.json").exists()) {
            dir = dir.parentFile
        }
        val file = File(dir ?: error("shared/fixtures/attach-note.json not found above CWD"),
            "shared/fixtures/attach-note.json")
        JSONObject(file.readText())
    }

    @Test
    fun compose() {
        val cases = fixture.getJSONArray("compose")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val paths = case.getJSONArray("paths").let { array ->
                (0 until array.length()).map { array.getString(it) }
            }
            assertEquals(name, case.getString("note"), AgentAttachNote.compose(paths))
            // Round-trip: a composed note must split back losslessly.
            val split = AgentAttachNote.split(case.getString("note"))
            assertTrue("$name (round-trip display)", split.display.isEmpty())
            assertEquals("$name (round-trip paths)", paths, split.paths)
        }
    }

    @Test
    fun split() {
        val cases = fixture.getJSONArray("split")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val result = AgentAttachNote.split(case.getString("text"))
            assertEquals("$name (display)", case.getString("display"), result.display)
            assertEquals(
                "$name (paths)",
                case.getJSONArray("paths").let { array ->
                    (0 until array.length()).map { array.getString(it) }
                },
                result.paths,
            )
        }
    }

    @Test
    fun matching() {
        val cases = fixture.getJSONArray("matching")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            assertEquals(
                case.getString("name"),
                case.getString("normalized"),
                AgentAttachNote.normalizedForMatching(case.getString("text")),
            )
        }
    }
}
