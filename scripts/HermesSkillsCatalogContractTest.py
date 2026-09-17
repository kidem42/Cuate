"""Own minimal contracts; no vendored Hermes sources."""
import asyncio
from pathlib import Path
import tempfile
import unittest

from hermes.native_approval_patch import repair_skills_catalog


class SkillsCatalogContract(unittest.TestCase):
    source = "async def _handle_skills():\n    return _find_all_skills(skip_disabled=False, include_editorial=True)\n"

    def repair(self, definition, source=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tools").mkdir()
            (root / "tools/skills_tool.py").write_text(definition)
            return repair_skills_catalog(source or self.source, root)

    def test_old_signature_executes_and_preserves_catalog(self):
        definition = "def _find_all_skills(*, skip_disabled=False):\n    return ['enabled', 'disabled'] if not skip_disabled else ['enabled']\n"
        repaired = self.repair(definition)
        namespace = {}
        exec(definition + repaired, namespace)
        self.assertEqual(asyncio.run(namespace['_handle_skills']()), ['enabled', 'disabled'])
        self.assertEqual(self.repair(definition, repaired), repaired)

    def test_new_signature_is_unchanged(self):
        definition = "def _find_all_skills(*, skip_disabled=False, include_editorial=False): pass\n"
        self.assertEqual(self.repair(definition), self.source)

    def test_kwargs_signature_is_unchanged(self):
        self.assertEqual(self.repair("def _find_all_skills(**kwargs): pass\n"), self.source)

    def test_unrelated_source_does_not_require_skills_module(self):
        self.assertEqual(repair_skills_catalog("x = 1\n", Path('/missing')), "x = 1\n")

    def test_unknown_shapes_refused(self):
        for source in (self.source.replace('True', 'False'),
                       self.source.replace('skip_disabled=False', 'skip_disabled=choice'),
                       self.source + self.source.replace('_handle_skills', '_handle_skills')):
            with self.subTest(source=source), self.assertRaises(ValueError):
                self.repair("def _find_all_skills(*, skip_disabled=False): pass\n", source)

    def test_missing_definition_refused(self):
        with self.assertRaises(ValueError):
            self.repair("def unrelated(): pass\n")


if __name__ == '__main__':
    unittest.main()
