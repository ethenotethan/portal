from __future__ import annotations

import unittest
from urllib.parse import parse_qs, urlsplit

from automation.product_factory.github import GitHubReader


class ProductFactoryGitHubReaderTests(unittest.TestCase):
    def test_fetches_all_issue_pages_and_filters_pull_requests(self) -> None:
        page_one = [
            {
                "number": number,
                "node_id": f"I_{number}",
                "title": f"Issue {number}",
                "body": "body",
                "user": {"login": "ethenotethan"},
                "labels": [{"name": "bug"}],
                "state": "open",
                "html_url": f"https://example/{number}",
                "updated_at": "2026-09-21T10:00:00Z",
            }
            for number in range(1, 100)
        ]
        page_one.append(
            {
                "number": 100,
                "pull_request": {"url": "https://api.example/pulls/100"},
                "labels": [],
            }
        )
        page_two = [
            {
                "number": 101,
                "node_id": "I_101",
                "title": "Closed issue",
                "body": None,
                "user": {"login": "hankbob"},
                "labels": [{"name": "factory:product"}],
                "state": "closed",
                "html_url": "https://example/101",
                "updated_at": "2026-09-21T11:00:00Z",
            }
        ]
        calls: list[str] = []

        def api(endpoint: str):
            calls.append(endpoint)
            page = parse_qs(urlsplit(endpoint).query)["page"][0]
            return page_one if page == "1" else page_two

        records = GitHubReader(api).fetch_issues("ethenotethan/portal")

        self.assertEqual(len(records), 100)
        self.assertEqual(records[-1]["number"], 101)
        self.assertEqual(records[-1]["body"], "")
        self.assertEqual(records[-1]["labels"], ["factory:product"])
        self.assertEqual(len(calls), 2)
        self.assertIn("state=all", calls[0])

    def test_latest_control_label_event_carries_actor(self) -> None:
        events = [
            {"id": 1, "event": "labeled", "label": {"name": "bug"}, "actor": {"login": "guest"}},
            {
                "id": 2,
                "event": "labeled",
                "label": {"name": "factory:design-approved"},
                "actor": {"login": "ethenotethan"},
            },
        ]

        def api(endpoint: str):
            self.assertIn("issues/260/events", endpoint)
            return events

        label_events = GitHubReader(api).fetch_label_events("ethenotethan/portal", 260)

        self.assertEqual(
            label_events,
            [
                {
                    "event_id": 2,
                    "action": "labeled",
                    "label": "factory:design-approved",
                    "actor": "ethenotethan",
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
