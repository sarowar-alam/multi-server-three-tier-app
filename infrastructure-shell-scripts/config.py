# =============================================================================
#  Configuration — BMI Health Tracker AWS Deploy
# =============================================================================

# ── AWS credentials ──────────────────────────────────────────────────────────
PROFILE = "sarowar-ostad"
REGION  = "ap-south-1"

# ── AMI (Ubuntu 26.04 LTS amd64, ap-south-1) ─────────────────────────────────
AMI_ID = "ami-01a00762f46d584a1"

# ── IAM ───────────────────────────────────────────────────────────────────────
IAM_INSTANCE_PROFILE_ARN = "arn:aws:iam::388779989543:instance-profile/SSM"

# ── ACM certificate (bmi.ostaddevops.click, ap-south-1) ──────────────────────
ACM_CERT_ARN = (
    "arn:aws:acm:ap-south-1:388779989543:certificate/"
    "9eabfa2b-1b15-4b7a-beed-881e00ffe10d"
)

# ── Route53 ───────────────────────────────────────────────────────────────────
ROUTE53_ZONE_ID   = "Z1019653XLWIJ02C53P5"
ROUTE53_ZONE_NAME = "ostaddevops.click"
DEFAULT_DOMAIN    = "bmi.ostaddevops.click"
DEFAULT_CERT_EMAIL = "admin@ostaddevops.click"

# ── EC2 defaults ──────────────────────────────────────────────────────────────
DEFAULT_INSTANCE_TYPE = "t3.micro"
DEFAULT_VOLUME_GB     = 20

# ── VPC / networking ──────────────────────────────────────────────────────────
VPC_CIDR = "10.0.0.0/16"

PUBLIC_SUBNETS = [
    {"cidr": "10.0.1.0/24", "az": "ap-south-1a", "name": "bmi-public-1a"},
    {"cidr": "10.0.2.0/24", "az": "ap-south-1b", "name": "bmi-public-1b"},
]

PRIVATE_SUBNETS = [
    {"cidr": "10.0.11.0/24", "az": "ap-south-1a", "name": "bmi-private-1a"},
    {"cidr": "10.0.12.0/24", "az": "ap-south-1b", "name": "bmi-private-1b"},
]

# ── GitHub raw URL base ───────────────────────────────────────────────────────
GITHUB_RAW_BASE = (
    "https://raw.githubusercontent.com/sarowar-alam/"
    "three-tier-aws-deployment/main/userdata-setup-scripts"
)

# ── Tagging ───────────────────────────────────────────────────────────────────
PROJECT_TAG    = "bmi-health-tracker"
MANAGED_BY_TAG = "bmi-deploy"

# ── State file ────────────────────────────────────────────────────────────────
import os
STATE_FILE = os.path.join(os.path.dirname(__file__), "deploy-state.json")
