"""
Userdata builders — return a bash script string (not base64-encoded;
boto3 run_instances accepts plain text and encodes automatically).
"""
import textwrap
import config


def _strip(s: str) -> str:
    return textwrap.dedent(s).lstrip("\n")


def render_frontend(
    mode: str,
    backend_host: str,
    domain: str = "",
    cert_email: str = "",
    db_password: str = "",
) -> str:
    """
    Userdata for the Tier-1 / single-server EC2.
    Downloads tier1-frontend.sh from GitHub and runs it with the given args.
    When backend_host=localhost and db_password is set, tier1-frontend.sh
    automatically runs DB + Backend setup first (single-server mode).
    """
    args = f"-Mode={mode} -BackendHost={backend_host}"
    if domain:
        args += f" -Domain={domain}"
    if cert_email:
        args += f" -CertEmail={cert_email}"
    if db_password:
        args += f" -DbPassword={db_password}"

    raw = config.GITHUB_RAW_BASE
    return _strip(f"""
        #!/bin/bash
        set -euo pipefail
        exec > >(tee -a /var/log/bmi-userdata.log) 2>&1
        echo "[userdata] BMI frontend setup starting $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        curl -fsSL "{raw}/tier1-frontend.sh" -o /tmp/tier1-frontend.sh
        chmod +x /tmp/tier1-frontend.sh
        bash /tmp/tier1-frontend.sh {args}
    """)


def render_backend(
    db_host: str,
    db_password: str,
    frontend_url: str = "*",
    port: str = "3000",
) -> str:
    """
    Userdata for the Tier-2 (backend-only) EC2 in multi-server deployments.
    """
    raw = config.GITHUB_RAW_BASE
    return _strip(f"""
        #!/bin/bash
        set -euo pipefail
        exec > >(tee -a /var/log/bmi-userdata.log) 2>&1
        echo "[userdata] BMI backend setup starting $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        curl -fsSL "{raw}/tier2-backend.sh" -o /tmp/tier2-backend.sh
        chmod +x /tmp/tier2-backend.sh
        bash /tmp/tier2-backend.sh \\
          -DbPassword="{db_password}" \\
          -DbHost="{db_host}" \\
          -FrontendUrl="{frontend_url}" \\
          -Port="{port}"
    """)


def render_database(db_password: str) -> str:
    """
    Userdata for the Tier-3 (database-only) EC2 in multi-server deployments.
    """
    raw = config.GITHUB_RAW_BASE
    return _strip(f"""
        #!/bin/bash
        set -euo pipefail
        exec > >(tee -a /var/log/bmi-userdata.log) 2>&1
        echo "[userdata] BMI database setup starting $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        curl -fsSL "{raw}/tier3-database.sh" -o /tmp/tier3-database.sh
        chmod +x /tmp/tier3-database.sh
        bash /tmp/tier3-database.sh -Password="{db_password}"
    """)
