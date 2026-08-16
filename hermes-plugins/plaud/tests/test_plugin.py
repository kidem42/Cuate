"""Contract tests for the Plaud plugin — stdlib only, no network, no grant.

They cover the SEAM with Hermes, not just this package's own logic: how the
runtime calls a handler, what it does with `check_fn`, what a registration
needs. Two shipped bugs came from assuming that seam instead of reading it
(handlers written for keyword arguments; `check_fn` returning a tuple), and
both were invisible to logic-only tests — hence the first three cases below.

    python3 hermes-plugins/plaud/tests/test_plugin.py     # or: pytest <path>
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

# The package is `plaud` on disk (Hermes imports it as
# `hermes_plugins.plaud`); adding its parent makes the relative imports inside
# resolve exactly as they do on a live host.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

import plaud  # noqa: E402
from plaud import client, tools  # noqa: E402

# --------------------------------------------------------------------------
# Fixtures — the shapes the Plaud API actually returns.
# --------------------------------------------------------------------------

TRANSCRIPT = json.dumps(
    [
        {"start_time": 0, "speaker": "Pavel", "content": "Let's start."},
        {"start_time": 630000, "speaker": "Ann", "content": "Shipping Friday."},
        {"start_time": 1800000, "speaker": "Pavel", "content": "Agreed."},
    ]
)

MONDAY = {
    "id": "aaa111",
    "name": "Monday sync",
    "created_at": "2026-08-10T09:00:00Z",
    "duration": 1830,
    "note_list": [
        {"data_tab_name": "Summary", "data_content": "Decided to ship on Friday."},
        {"data_tab_name": "Highlights", "data_content": "- Friday release"},
    ],
    "source_list": [{"data_content": TRANSCRIPT}],
}

FRIDAY = {
    "id": "bbb222",
    "name": "Friday retro",
    "created_at": "2026-08-14T15:00:00Z",
    "duration": 900,
    "note_list": [{"data_tab_name": "Summary", "data_content": "Went fine."}],
    "source_list": [{"data_content": TRANSCRIPT}],
}

RAW = {  # recorded, not yet processed by Plaud
    "id": "ccc333",
    "name": "Voice memo",
    "created_at": "2026-08-15T20:00:00Z",
    "duration": 60,
    "note_list": [],
    "source_list": [],
}

LIBRARY = [RAW, FRIDAY, MONDAY]  # newest first, as the API returns it


class FakeAPI:
    """Stands in for the network: the tools see the same payloads, and any
    route the tests do not expect raises instead of reaching out."""

    def __init__(self, library=LIBRARY):
        self.library = library
        self.page_sizes = []

    def list_files(self, page=1, page_size=client.PAGE_SIZE):
        self.page_sizes.append(page_size)
        return self.library if page == 1 else []

    def get_file(self, file_id):
        for item in self.library:
            if item["id"] == file_id:
                return item
        raise client.PlaudError("Recording not found.")


def with_api(test):
    """Patches the client's three network calls for the duration of a test."""

    def wrapper(self, *args, **kwargs):
        api = FakeAPI()
        with mock.patch.object(client, "list_files", api.list_files), \
             mock.patch.object(client, "get_file", api.get_file), \
             mock.patch.object(client, "resolve_content", lambda item: item.get("data_content")):
            return test(self, api, *args, **kwargs)

    wrapper.__name__ = test.__name__
    return wrapper


# --------------------------------------------------------------------------
# The seam with Hermes
# --------------------------------------------------------------------------


class HermesSeam(unittest.TestCase):
    """What the runtime does to us — read from the Hermes sources, not guessed."""

    @with_api
    def test_handlers_take_a_positional_dict(self, api):
        # tools/registry.py:1126 — `entry.handler(args, **kwargs)`. A handler
        # written for keyword arguments only raises TypeError on every call.
        self.assertIn("aaa111", tools._handle_plaud_find({"query": "monday"}))
        self.assertIn("Decided to ship", tools._handle_plaud_get_note({"file_id": "aaa111"}))
        self.assertIn("Shipping Friday", tools._handle_plaud_get_transcript({"file_id": "aaa111"}))

    @with_api
    def test_handlers_survive_extra_kwargs(self, api):
        # The same call site splats kwargs alongside the dict; unknown keys
        # (call ids, session hints) must not blow the handler up.
        text = tools._handle_plaud_find({"limit": 1}, tool_call_id="call_1")
        self.assertIn("plaud://", text)

    def test_check_fn_returns_a_plain_bool(self):
        # tools/registry.py:338 — `bool(fn())`. A tuple is ALWAYS truthy, so a
        # `(False, "reason")` return would advertise the tools on a host with
        # no grant and fail at dispatch instead.
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.dict(os.environ, {"HERMES_HOME": home}, clear=False), \
                 mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("PLAUD_ACCESS_TOKEN", None)
                os.environ.pop("PLAUD_REFRESH_TOKEN", None)
                available = tools._check_plaud_available()
        self.assertIsInstance(available, bool)
        self.assertFalse(available)

    def test_registration_names_match_the_schemas(self):
        recorded = {}

        class Ctx:
            def register_tool(self, name, toolset, schema, handler, check_fn, emoji=None):
                recorded[name] = (schema, handler, check_fn)

            def register_system_prompt_section(self, name, fn):
                recorded["prompt_section"] = fn

            def register_cli_command(self, name, help, setup_fn, handler_fn, description=None):
                recorded["cli"] = name

        plaud.register(Ctx())
        self.assertEqual(recorded["cli"], "plaud")
        for name in ("plaud_find", "plaud_get_note", "plaud_get_transcript"):
            schema, handler, check_fn = recorded[name]
            self.assertEqual(schema["type"], "function")
            self.assertEqual(schema["function"]["name"], name, "schema name must match the registered name")
            parameters = schema["function"]["parameters"]
            self.assertEqual(parameters["type"], "object")
            self.assertTrue(schema["function"]["description"].strip())
            for required in parameters.get("required", []):
                self.assertIn(required, parameters["properties"], "required field is not declared")
            self.assertTrue(callable(handler) and callable(check_fn))

    def test_registration_survives_a_host_without_prompt_sections(self):
        class OldCtx:
            def register_tool(self, **kwargs):
                pass

            def register_cli_command(self, **kwargs):
                pass

        plaud.register(OldCtx())  # must not raise

    def test_prompt_section_is_silent_without_a_grant(self):
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.dict(os.environ, {"HERMES_HOME": home}, clear=False):
                os.environ.pop("PLAUD_ACCESS_TOKEN", None)
                self.assertEqual(plaud._prompt_section(None), "")
                client.save_tokens({"access_token": "a", "refresh_token": "r"})
                self.assertIn("Plaud", plaud._prompt_section(None))


# --------------------------------------------------------------------------
# Tool behaviour
# --------------------------------------------------------------------------


class Find(unittest.TestCase):
    @with_api
    def test_query_filters_by_name(self, api):
        text = tools._handle_plaud_find({"query": "retro"})
        self.assertIn("Friday retro", text)
        self.assertNotIn("Monday sync", text)

    @with_api
    def test_dates_and_limit_narrow_the_list(self, api):
        text = tools._handle_plaud_find({"date_from": "2026-08-12"})
        self.assertNotIn("Monday sync", text)
        self.assertEqual(len(tools._handle_plaud_find({"limit": 1}).splitlines()[0]), len("1 recording(s):"))

    @with_api
    def test_every_hit_carries_its_reference(self, api):
        for line in tools._handle_plaud_find({}).splitlines():
            if line.startswith("- "):
                self.assertIn("plaud://", line)

    @with_api
    def test_unprocessed_recordings_are_called_out(self, api):
        text = tools._handle_plaud_find({})
        self.assertIn("Not processed by Plaud yet", text)
        self.assertIn("Voice memo", text)

    @with_api
    def test_page_size_stays_inside_the_accepted_window(self, api):
        tools._handle_plaud_find({})
        self.assertTrue(all(size == client.PAGE_SIZE for size in api.page_sizes))

    @with_api
    def test_api_failure_comes_back_as_words(self, api):
        def boom(**kwargs):
            raise client.PlaudError("Plaud is not connected on this host.")

        with mock.patch.object(client, "list_files", boom):
            self.assertIn("not connected", tools._handle_plaud_find({}))


class References(unittest.TestCase):
    def tearDown(self):
        os.environ.pop("PLAUD_REFERENCE_STYLE", None)

    def test_marker_is_the_default(self):
        self.assertEqual(tools._reference("aaa111"), "plaud://aaa111")

    def test_style_can_be_a_link_or_a_bare_id(self):
        os.environ["PLAUD_REFERENCE_STYLE"] = "link"
        self.assertEqual(tools._reference("aaa111"), "https://web.plaud.ai/file/aaa111")
        os.environ["PLAUD_REFERENCE_STYLE"] = "id"
        self.assertEqual(tools._reference("aaa111"), "aaa111")
        os.environ["PLAUD_REFERENCE_STYLE"] = "nonsense"
        self.assertEqual(tools._reference("aaa111"), "plaud://aaa111")


class Note(unittest.TestCase):
    @with_api
    def test_all_tabs_by_default_one_when_asked(self, api):
        every = tools._handle_plaud_get_note({"file_id": "aaa111"})
        self.assertIn("## Summary", every)
        self.assertIn("## Highlights", every)
        one = tools._handle_plaud_get_note({"file_id": "aaa111", "tab": "highlights"})
        self.assertIn("## Highlights", one)
        self.assertNotIn("## Summary", one)

    @with_api
    def test_unprocessed_points_at_the_app(self, api):
        text = tools._handle_plaud_get_note({"file_id": "ccc333"})
        self.assertIn("not been processed", text)
        self.assertIn("web.plaud.ai/file/ccc333", text)

    @with_api
    def test_unknown_id_is_reported_not_raised(self, api):
        self.assertIn("not found", tools._handle_plaud_get_note({"file_id": "zzz999"}))


class Transcript(unittest.TestCase):
    @with_api
    def test_turns_are_timecoded(self, api):
        text = tools._handle_plaud_get_transcript({"file_id": "aaa111"})
        self.assertIn("[00:00] Pavel: Let's start.", text)
        self.assertIn("[10:30] Ann: Shipping Friday.", text)

    @with_api
    def test_window_trims_both_ends(self, api):
        text = tools._handle_plaud_get_transcript({"file_id": "aaa111", "from_min": 5, "to_min": 20})
        self.assertIn("Shipping Friday", text)
        self.assertNotIn("Let's start", text)
        self.assertNotIn("Agreed", text)

    @with_api
    def test_plain_text_transcripts_pass_through(self, api):
        plain = dict(MONDAY, source_list=[{"data_content": "no json here"}])
        with mock.patch.object(client, "get_file", lambda file_id: plain):
            self.assertIn("no json here", tools._handle_plaud_get_transcript({"file_id": "aaa111"}))


# --------------------------------------------------------------------------
# Handling of someone else's data
# --------------------------------------------------------------------------


class Safety(unittest.TestCase):
    def test_file_id_cannot_walk_the_path(self):
        def unreachable(path):
            raise AssertionError(f"the network must not be reached: {path}")

        with mock.patch.object(client, "_api", unreachable):
            for bad in ("../../etc/passwd", "aaa/../bbb", "aaa 111", ""):
                with self.assertRaises(client.PlaudError):
                    client.get_file(bad)

    def test_content_links_must_be_https(self):
        def unreachable(*args, **kwargs):
            raise AssertionError("a non-HTTPS link must never be opened")

        with mock.patch.object(client.urllib.request, "urlopen", unreachable):
            for link in ("file:///etc/passwd", "http://plaud.example/x.txt", "ftp://h/x"):
                self.assertIsNone(client.resolve_content({"data_link": link}))
        # Inline content never touches the network at all.
        self.assertEqual(client.resolve_content({"data_content": "hi"}), "hi")

    def test_the_grant_is_written_private(self):
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.dict(os.environ, {"HERMES_HOME": home}, clear=False):
                client.save_tokens({"access_token": "a", "refresh_token": "r"})
                path = client.token_file()
                self.assertEqual(path, pathlib.Path(home) / "plaud" / "auth.json")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(client.token_source(), "file")


if __name__ == "__main__":
    unittest.main(verbosity=2)
