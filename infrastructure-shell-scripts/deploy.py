#!/usr/bin/env python3
"""
BMI Health Tracker — AWS Deployment Tool
=========================================

Usage examples (run from the infrastructure-shell-scripts/ directory):

  # Install deps once:
  pip install -r requirements.txt

  # Case 1: Multi-server + private subnets + ALB  → https://bmi.ostaddevops.click
  python deploy.py --scenario multi-alb --db-password 0stad2025

  # Case 2: Multi-server + public IPs, no domain  → http://PUBLIC_IP
  python deploy.py --scenario multi-public --db-password 0stad2025

  # Case 3: Multi-server + public IPs + domain    → https://bmi.ostaddevops.click
  python deploy.py --scenario multi-public --db-password 0stad2025 \\
      --domain bmi.ostaddevops.click --cert-email admin@ostaddevops.click

  # Case 4: Single-server + private subnet + ALB  → https://bmi.ostaddevops.click
  python deploy.py --scenario single-alb --db-password 0stad2025

  # Case 5: Single-server + public IP, no domain  → http://PUBLIC_IP
  python deploy.py --scenario single-public --db-password 0stad2025

  # Case 6: Single-server + public IP + domain    → https://bmi.ostaddevops.click
  python deploy.py --scenario single-public --db-password 0stad2025 \\
      --domain bmi.ostaddevops.click --cert-email admin@ostaddevops.click

  # Teardown (destroys everything created by the last deploy):
  python deploy.py --teardown

  # Dry run (prints plan, makes zero AWS API calls):
  python deploy.py --scenario single-public --db-password x --dry-run
"""

import argparse
import sys
import os
from datetime import datetime, timezone

# Add the parent directory to the path so `import config` works regardless
# of where the script is called from.
sys.path.insert(0, os.path.dirname(__file__))

import config
import boto3
from core.state import DeployState
from core.teardown import teardown_all


SCENARIOS = {
    "single-public": ("scenarios.single_public", "Case 5/6: Single-server + public IP"),
    "single-alb":    ("scenarios.single_alb",    "Case 4:   Single-server + private + ALB"),
    "multi-public":  ("scenarios.multi_public",  "Case 2/3: Multi-server + public IPs"),
    "multi-alb":     ("scenarios.multi_alb",     "Case 1:   Multi-server + private + ALB"),
}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="deploy.py",
        description="BMI Health Tracker — deploy all 6 AWS scenarios",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--scenario",
        choices=list(SCENARIOS.keys()),
        metavar="SCENARIO",
        help=f"Deployment scenario: {', '.join(SCENARIOS.keys())}",
    )
    p.add_argument(
        "--db-password",
        default="",
        metavar="PASSWORD",
        help="PostgreSQL bmi_user password (required for all scenarios)",
    )
    p.add_argument(
        "--domain",
        default="",
        metavar="DOMAIN",
        help=(
            "Public domain for HTTPS (e.g. bmi.ostaddevops.click). "
            "Omit for plain HTTP (public scenarios) or to use the default domain (ALB scenarios)."
        ),
    )
    p.add_argument(
        "--cert-email",
        default=config.DEFAULT_CERT_EMAIL,
        metavar="EMAIL",
        help=f"Let's Encrypt registration email (default: {config.DEFAULT_CERT_EMAIL})",
    )
    p.add_argument(
        "--instance-type",
        default=config.DEFAULT_INSTANCE_TYPE,
        metavar="TYPE",
        help=f"EC2 instance type (default: {config.DEFAULT_INSTANCE_TYPE})",
    )
    p.add_argument(
        "--key-name",
        default="",
        metavar="KEY",
        help="EC2 key pair name for SSH access (optional; SSM is the primary access method)",
    )
    p.add_argument(
        "--profile",
        default=config.PROFILE,
        metavar="PROFILE",
        help=f"AWS named profile (default: {config.PROFILE})",
    )
    p.add_argument(
        "--region",
        default=config.REGION,
        metavar="REGION",
        help=f"AWS region (default: {config.REGION})",
    )
    p.add_argument(
        "--teardown",
        action="store_true",
        help="Destroy all resources created by the last deploy (reads deploy-state.json)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be created/deleted — makes no AWS API calls",
    )
    return p


def _print_banner() -> None:
    print("=" * 62)
    print("  BMI Health Tracker — AWS Deploy")
    print(f"  {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print("=" * 62)


def _print_summary(state: DeployState) -> None:
    print()
    print("=" * 62)
    print("  DEPLOYMENT COMPLETE")
    print("=" * 62)
    print(f"  Scenario   : {state.scenario}")
    if state.instance_db:
        print(f"  DB         : {state.instance_db}")
    if state.instance_backend:
        print(f"  Backend    : {state.instance_backend}")
    if state.instance_frontend:
        print(f"  Frontend   : {state.instance_frontend}")
    if state.alb_dns:
        print(f"  ALB        : {state.alb_dns}")
    if state.route53_domain:
        print(f"  Route53    : {state.route53_domain}")
    print()
    print(f"  ACCESS URL : {state.access_url}")
    print()
    print("  NOTE: EC2 userdata setup takes 5-10 minutes after launch.")
    print("        Poll progress via SSM Session Manager:")
    print("          aws ssm start-session --target INSTANCE_ID")
    print("          sudo tail -f /var/log/bmi-userdata.log")
    print("=" * 62)


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    _print_banner()

    # ── Teardown path ─────────────────────────────────────────────────────────
    if args.teardown:
        state = DeployState.load_or_exit(config.STATE_FILE)
        print(f"\nTearing down scenario '{state.scenario}' deployed at {state.deployed_at}")
        confirm = input("Type 'yes' to confirm teardown: ").strip().lower()
        if confirm != "yes":
            print("Aborted.")
            sys.exit(0)
        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        teardown_all(session, state)
        os.remove(config.STATE_FILE)
        print(f"\nState file removed: {config.STATE_FILE}")
        return

    # ── Deploy path ───────────────────────────────────────────────────────────
    if not args.scenario:
        parser.error("--scenario is required unless --teardown is specified")
    if not args.db_password:
        parser.error("--db-password is required")

    module_path, desc = SCENARIOS[args.scenario]
    print(f"\nScenario : {args.scenario}")
    print(f"           {desc}")
    if args.dry_run:
        print("\n*** DRY RUN — no AWS API calls will be made ***")

    # Import the scenario module dynamically
    import importlib
    scenario_mod = importlib.import_module(module_path)

    state = DeployState(
        scenario=args.scenario,
        region=args.region,
        deployed_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )

    session = boto3.Session(profile_name=args.profile, region_name=args.region)

    try:
        scenario_mod.deploy(args, session, state)
    except Exception as exc:
        print(f"\nERROR during deploy: {exc}")
        print("Partial state saved — run --teardown to clean up created resources.")
        if not args.dry_run:
            state.save(config.STATE_FILE)
        raise

    if not args.dry_run:
        state.save(config.STATE_FILE)

    _print_summary(state)


if __name__ == "__main__":
    main()
