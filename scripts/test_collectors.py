"""Unit tests for the metric collectors that have no build behind them.

`collect-layout-smells.py` is a textual bracket-tracking scan and
`collect-slow-tests.py` is a log parser; both decide what a ratchet counts, so
their rules are pinned here the way `test_constraint_growth.py` pins the
constraint gate. Run with `python3 -m unittest scripts/test_collectors.py`.
"""
from __future__ import annotations

import importlib.util
import pathlib
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


layout = _load("collect-layout-smells")
slow = _load("collect-slow-tests")


def kinds(source: str) -> list[str]:
    return [f["kind"] for f in layout.scan(source)]


class LayoutSmellScanTests(unittest.TestCase):
    def test_lazy_stack_directly_under_same_axis_scroll_view_is_fine(self):
        src = """
        struct Feed: View {
            var body: some View {
                ScrollView { LazyVStack(spacing: 4) { Text("row") } }
            }
        }
        """
        self.assertEqual(kinds(src), [])

    def test_default_scroll_view_axis_is_vertical(self):
        src = "struct A: View { var body: some View { ScrollView { LazyHStack { Text(\"x\") } } } }"
        self.assertEqual(kinds(src), ["lazy_stack_cross_axis_scroll"])

    def test_lazy_vstack_inside_horizontal_scroll_view_is_cross_axis(self):
        # The model table's rows before #606: every row must be realised to know
        # the table's height, so the lazy stack can never skip one.
        src = """
        struct Table: View {
            var body: some View {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack { LazyVStack(alignment: .leading, spacing: 0) { Text("r") } }
                }
            }
        }
        """
        self.assertEqual(kinds(src), ["lazy_stack_cross_axis_scroll"])

    def test_both_axes_scroll_view_accepts_either_stack(self):
        src = """
        struct B: View {
            var body: some View {
                ScrollView([.horizontal, .vertical]) { LazyHStack { LazyVStack { Text("x") } } }
            }
        }
        """
        self.assertEqual(kinds(src), [])

    def test_lazy_stack_with_no_scroll_view_in_type_has_no_viewport(self):
        # The Kanban columns / ModelCard before #606.
        src = """
        struct Board: View {
            var body: some View {
                HStack { LazyVStack(alignment: .leading, spacing: 6) { Text("card") } }
            }
        }
        """
        self.assertEqual(kinds(src), ["lazy_stack_without_viewport"])

    def test_split_body_and_rows_in_same_type_gets_benefit_of_doubt(self):
        src = """
        struct Split: View {
            var body: some View { ScrollView { rows } }
            private var rows: some View { LazyVStack { Text("a") } }
        }
        """
        self.assertEqual(kinds(src), [])

    def test_scroll_view_in_a_sibling_type_does_not_count(self):
        src = """
        struct Rows: View { var body: some View { LazyVStack { Text("a") } } }
        struct Host: View { var body: some View { ScrollView { Rows() } } }
        """
        self.assertEqual(kinds(src), ["lazy_stack_without_viewport"])

    def test_mentions_in_comments_and_strings_are_ignored(self):
        src = """
        struct C: View {
            // A LazyVStack here would loop — see #606.
            /* LazyHStack( */
            var body: some View { Text("LazyVStack(") }
        }
        """
        self.assertEqual(kinds(src), [])

    def test_bare_trailing_closure_form_is_seen(self):
        src = "struct D: View { var body: some View { VStack { LazyVStack { Text(\"b\") } } } }"
        self.assertEqual(kinds(src), ["lazy_stack_without_viewport"])

    def test_extension_scopes_like_a_type(self):
        src = """
        extension Thing {
            var list: some View { LazyVStack { Text("x") } }
        }
        """
        self.assertEqual(kinds(src), ["lazy_stack_without_viewport"])

    def test_collect_reports_lines_and_counts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "X.swift"
            path.write_text("struct X: View {\n    var body: some View {\n        HStack { LazyVStack { Text(\"a\") } }\n    }\n}\n")
            snap = layout.collect(tmp, tmp)
        self.assertEqual(snap["total"], 1)
        self.assertEqual(snap["counts"], {"lazy_stack_without_viewport": 1})
        self.assertEqual(snap["sites"][0]["file"], "X.swift")
        self.assertEqual(snap["sites"][0]["line"], 3)


class SlowTestParseTests(unittest.TestCase):
    LOG = """
    ◇ Test "fast one" started.
    ✔ Test "fast one" passed after 0.012 seconds.
    ✔ Test "on the watchlist" passed after 2.500 seconds.
    ✘ Test "sleeps its way out" failed after 12.345 seconds with 1 issue.
    ✔ Test recordOpCounts() passed after 6.001 seconds.
    ✔ Suite "Slow suite" passed after 99.000 seconds.
    ✔ Test run with 4 tests in 1 suite passed after 99.100 seconds.
    Test Case '-[LegacyTests testOld]' passed (7.250 seconds).
    Test Suite 'All tests' passed at 2026-09-28 (100.000 seconds).
    """

    def test_counts_only_tests_over_threshold(self):
        snap = slow.collect(self.LOG, 5.0)
        names = [s["file"] for s in snap["sites"]]
        self.assertEqual(names, ["sleeps its way out", "LegacyTests/testOld", "recordOpCounts()"])
        self.assertEqual(snap["total"], 3)
        self.assertEqual(snap["counts"], {"over_threshold": 3})

    def test_suite_and_run_summary_lines_are_ignored(self):
        snap = slow.collect(self.LOG, 5.0)
        for site in snap["sites"]:
            self.assertNotIn("Suite", site["file"])
            self.assertNotIn("run with", site["file"])

    def test_watchlist_holds_the_middle_band(self):
        snap = slow.collect(self.LOG, 5.0)
        self.assertEqual([w["file"] for w in snap["watchlist"]], ["on the watchlist"])

    def test_rerun_keeps_max_duration(self):
        log = "✔ Test \"a\" passed after 1.0 seconds.\n✔ Test \"a\" passed after 8.0 seconds.\n"
        snap = slow.collect(log, 5.0)
        self.assertEqual(snap["total"], 1)
        self.assertEqual(snap["sites"][0]["seconds"], 8.0)

    def test_tests_parsed_counts_distinct_tests(self):
        self.assertEqual(slow.collect(self.LOG, 5.0)["tests_parsed"], 5)


if __name__ == "__main__":
    unittest.main()
