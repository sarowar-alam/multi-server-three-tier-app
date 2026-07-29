"""
Deploy state — written to deploy-state.json after each successful deploy.
Used by --teardown to reverse the exact set of resources that were created.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, asdict
from typing import List


@dataclass
class DeployState:
    scenario: str = ""
    region: str = ""
    deployed_at: str = ""

    # ── VPC / networking ──────────────────────────────────────────────────────
    vpc_id: str = ""
    public_subnet_ids: List[str] = field(default_factory=list)
    private_subnet_ids: List[str] = field(default_factory=list)
    igw_id: str = ""
    public_rt_id: str = ""
    private_rt_id: str = ""
    nat_gw_id: str = ""
    nat_eip_alloc_id: str = ""

    # ── Security groups ───────────────────────────────────────────────────────
    sg_alb: str = ""       # ALB SG (ALB scenarios)
    sg_frontend: str = ""  # Frontend / Single-server SG
    sg_backend: str = ""   # Backend SG (multi-server)
    sg_db: str = ""        # DB SG (multi-server)

    # ── EC2 instances ─────────────────────────────────────────────────────────
    instance_db: str = ""
    instance_backend: str = ""
    instance_frontend: str = ""   # also used as "single" instance

    # ── ALB ───────────────────────────────────────────────────────────────────
    alb_arn: str = ""
    alb_dns: str = ""
    alb_canonical_zone_id: str = ""
    tg_arn: str = ""
    listener_80_arn: str = ""
    listener_443_arn: str = ""

    # ── Route53 ───────────────────────────────────────────────────────────────
    route53_domain: str = ""
    route53_is_alias: bool = False

    # ── Output ────────────────────────────────────────────────────────────────
    access_url: str = ""

    # ─────────────────────────────────────────────────────────────────────────

    def save(self, path: str) -> None:
        with open(path, "w") as f:
            json.dump(asdict(self), f, indent=2)
        print(f"  State saved → {path}")

    @classmethod
    def load(cls, path: str) -> "DeployState":
        with open(path) as f:
            data = json.load(f)
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})

    @classmethod
    def load_or_exit(cls, path: str) -> "DeployState":
        if not os.path.exists(path):
            print(f"ERROR: No state file found at {path}. Nothing to tear down.")
            raise SystemExit(1)
        return cls.load(path)


def make_tags(scenario: str, name: str, extra: dict | None = None) -> list:
    """Return a list of AWS tag dicts for the given resource name."""
    from config import PROJECT_TAG, MANAGED_BY_TAG
    tags = [
        {"Key": "Name",      "Value": name},
        {"Key": "Project",   "Value": PROJECT_TAG},
        {"Key": "ManagedBy", "Value": MANAGED_BY_TAG},
        {"Key": "Scenario",  "Value": scenario},
    ]
    if extra:
        for k, v in extra.items():
            tags.append({"Key": k, "Value": v})
    return tags


def tag_spec(resource_type: str, scenario: str, name: str) -> list:
    """Return TagSpecifications list for run_instances / create_* calls."""
    return [{
        "ResourceType": resource_type,
        "Tags": make_tags(scenario, name),
    }]
