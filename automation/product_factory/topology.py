"""Canonical Product Factory cron declarations and model projection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


TOPOLOGY_PATH = Path(__file__).with_name("topology.v1.json")
DATAFLOW_FIELDS = {
    "inputs": ("reads", "resource_to_job"),
    "outputs": ("writes", "job_to_resource"),
    "side_effects": ("delivers", "job_to_resource"),
}


def load_topology(path: Path = TOPOLOGY_PATH) -> dict[str, Any]:
    """Load and validate the versioned factory topology."""
    value = json.loads(path.read_text())
    if value.get("version") != 1:
        raise ValueError("unsupported Product Factory topology version")
    jobs = value.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        raise ValueError("Product Factory topology requires jobs")
    job_ids = [job.get("id") for job in jobs]
    if any(not isinstance(job_id, str) or not job_id for job_id in job_ids):
        raise ValueError("every Product Factory job requires an id")
    if len(job_ids) != len(set(job_ids)):
        raise ValueError("Product Factory job ids must be unique")
    for job in jobs:
        for field in (*DATAFLOW_FIELDS, "source_files"):
            values = job.get(field)
            if not isinstance(values, list) or any(not isinstance(item, str) or not item for item in values):
                raise ValueError(f"{job['id']}.{field} must be a list of non-empty strings")
    authorities = value.get("authorities", [])
    if not isinstance(authorities, list):
        raise ValueError("Product Factory authorities must be a list")
    authority_ids = [authority.get("id") for authority in authorities]
    if any(not isinstance(authority_id, str) or not authority_id for authority_id in authority_ids):
        raise ValueError("every Product Factory authority requires an id")
    resource_refs = {
        ref
        for job in jobs
        for field in DATAFLOW_FIELDS
        for ref in job[field]
    }
    endpoints = (
        {f"factory_jobs/{job_id}" for job_id in job_ids}
        | {f"factory_authorities/{authority_id}" for authority_id in authority_ids}
        | {f"factory_resources/{ref}" for ref in resource_refs}
    )
    relationships = value.get("relationships", [])
    if not isinstance(relationships, list):
        raise ValueError("Product Factory relationships must be a list")
    for relationship in relationships:
        if not isinstance(relationship, dict) or not relationship.get("type"):
            raise ValueError("every Product Factory relationship requires a type")
        for endpoint in (relationship.get("from"), relationship.get("to")):
            if endpoint not in endpoints:
                raise ValueError(f"Product Factory relationship has missing endpoint: {endpoint}")
    resource_labels = value.get("resource_labels", {})
    if not isinstance(resource_labels, dict):
        raise ValueError("Product Factory resource_labels must be an object")
    for ref, label in resource_labels.items():
        if ref not in resource_refs or not isinstance(label, str) or not label:
            raise ValueError(f"invalid Product Factory resource label: {ref}")
    return value


def _resource(ref: str, labels: dict[str, str]) -> dict[str, str]:
    scheme, _, value = ref.partition(":")
    return {
        "id": ref,
        "ref": ref,
        "scheme": scheme,
        "title": labels.get(ref, value or ref),
    }


def model_projection(topology: dict[str, Any] | None = None) -> dict[str, Any]:
    """Derive model entities and typed relations from cron declarations."""
    topology = topology or load_topology()
    jobs = topology["jobs"]
    resource_labels = topology.get("resource_labels", {})
    refs = sorted(
        {
            ref
            for job in jobs
            for field in DATAFLOW_FIELDS
            for ref in job[field]
        }
    )
    relations: list[dict[str, str]] = []
    for job in jobs:
        job_ref = f"factory_jobs/{job['id']}"
        for field, (relation_type, direction) in DATAFLOW_FIELDS.items():
            for ref in job[field]:
                resource_ref = f"factory_resources/{ref}"
                source, target = (
                    (resource_ref, job_ref)
                    if direction == "resource_to_job"
                    else (job_ref, resource_ref)
                )
                relations.append(
                    {
                        "from": source,
                        "to": target,
                        "type": relation_type,
                        "kind": "dataflow",
                        "declared_by": field,
                    }
                )
    relations.extend(
        {
            **relationship,
            "kind": "relationship",
            "declared_by": "relationships",
        }
        for relationship in topology.get("relationships", [])
    )
    return {
        "entities": {
            "factory_jobs": {"key": "id", "items": jobs},
            "factory_resources": {
                "key": "id",
                "items": [_resource(ref, resource_labels) for ref in refs],
            },
            "factory_authorities": {
                "key": "id",
                "items": topology.get("authorities", []),
            },
        },
        "relations": relations,
    }


def cron_updates(topology: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Return supported cron.update payloads from the same declarations."""
    topology = topology or load_topology()
    return [
        {
            "action": "update",
            "job_id": job["cron_id"],
            "inputs": job["inputs"],
            "outputs": job["outputs"],
            "side_effects": job["side_effects"],
            "source_files": job["source_files"],
        }
        for job in topology["jobs"]
    ]
