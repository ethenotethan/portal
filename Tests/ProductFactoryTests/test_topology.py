from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from automation.product_factory import topology


class ProductFactoryTopologyTests(unittest.TestCase):
    def test_cron_updates_and_model_edges_share_the_same_declarations(self) -> None:
        document = topology.load_topology()
        updates = topology.cron_updates(document)
        projection = topology.model_projection(document)

        self.assertEqual(len(updates), len(document["jobs"]))
        self.assertTrue(all(update.get("action") == "update" for update in updates))
        declared_edges = sum(
            len(job[field])
            for job in document["jobs"]
            for field in topology.DATAFLOW_FIELDS
        )
        dataflow_edges = [
            relation
            for relation in projection["relations"]
            if relation["kind"] == "dataflow"
        ]
        self.assertEqual(len(dataflow_edges), declared_edges)
        self.assertEqual(
            {relation["declared_by"] for relation in dataflow_edges},
            set(topology.DATAFLOW_FIELDS),
        )
        self.assertEqual(
            {relation["declared_by"] for relation in projection["relations"] if relation["kind"] == "relationship"},
            {"relationships"},
        )
        resource_titles = {
            item["title"]
            for item in projection["entities"]["factory_resources"]["items"]
        }
        self.assertIn("origin/main", resource_titles)
        self.assertIn("artifact:portal-pr-automation", resource_titles)

    def test_rejects_relationship_with_missing_endpoint(self) -> None:
        document = {
            "version": 1,
            "jobs": [
                {
                    "id": "worker",
                    "cron_id": "job-1",
                    "name": "worker",
                    "role": "test worker",
                    "inputs": ["file:/input"],
                    "outputs": ["file:/output"],
                    "side_effects": [],
                    "source_files": ["/worker.py"],
                }
            ],
            "authorities": [],
            "relationships": [
                {
                    "from": "factory_jobs/worker",
                    "to": "factory_resources/file:/missing",
                    "type": "writes",
                }
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "topology.json"
            path.write_text(json.dumps(document))

            with self.assertRaisesRegex(ValueError, "missing endpoint"):
                topology.load_topology(path)


if __name__ == "__main__":
    unittest.main()
