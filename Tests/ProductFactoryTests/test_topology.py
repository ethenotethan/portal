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

    def test_model_edges_match_cron_graph_wire_semantics(self) -> None:
        projection = topology.model_projection()
        relations = {
            (
                relation["from"],
                relation["to"],
                relation["type"],
                relation["declared_by"],
            )
            for relation in projection["relations"]
        }

        self.assertIn(
            (
                "factory_jobs/quality-classifier",
                "factory_jobs/quality-worker",
                "feeds",
                "inputs",
            ),
            relations,
        )
        self.assertIn(
            (
                "factory_jobs/quality-worker",
                "factory_resources/github:ethenotethan/portal/pulls",
                "github",
                "side_effects",
            ),
            relations,
        )
        resource_ids = {
            item["id"]
            for item in projection["entities"]["factory_resources"]["items"]
        }
        self.assertNotIn("cron-output:88bc6606d5f1", resource_ids)

    def test_runtime_scripts_are_repository_owned_and_use_canonical_projection(self) -> None:
        document = topology.load_topology()
        jobs = {job["id"]: job for job in document["jobs"]}
        repository_root = Path(__file__).resolve().parents[2]

        synchronizer = jobs["control-center-sync"]
        self.assertEqual(
            synchronizer["script"],
            "/Users/inference2/Projects/portal/scripts/portal-pr-kanban-tick.sh",
        )
        sync_source = repository_root / "scripts" / "portal-pr-kanban-sync.py"
        deployed_sync_source = str(sync_source).replace(
            str(repository_root),
            "/Users/inference2/Projects/portal",
        )
        self.assertIn(deployed_sync_source, synchronizer["source_files"])
        text = sync_source.read_text()
        self.assertIn("from automation.product_factory.topology import model_projection", text)
        self.assertNotIn("ARCHITECTURE_RELATIONS", text)

        merge_queue = jobs["merge-queue"]
        self.assertEqual(
            merge_queue["script"],
            "/Users/inference2/Projects/portal/scripts/portal-merge-queue.sh",
        )

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
