"""docs/PAGE-TYPES.md says which recorded kinds of opt-out page an end-to-end test covers: it must match the recorded sites, and every fixture and test it names must exist."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import page_type_coverage  # noqa: E402


class PageTypeCoverage(unittest.TestCase):
    def test_every_fixture_and_test_the_table_names_exists(self):
        self.assertEqual(page_type_coverage.check_files(), [])

    def test_the_table_is_current(self):
        text, _ = page_type_coverage.render()
        self.assertEqual(open(page_type_coverage.DOC, encoding='utf-8').read(), text, 'run tools/page_type_coverage.py --write')

    def test_the_three_kinds_asked_for_are_covered(self):
        _, rows = page_type_coverage.count()
        status = {name: st for name, _, _, _, st in rows}
        for name in status:
            if name.startswith(('Search first', 'Several addresses', 'Choose exactly one')):
                self.assertEqual(status[name], 'covered', name)


if __name__ == '__main__':
    unittest.main()
