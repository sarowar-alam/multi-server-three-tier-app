# =============================================================================
#  Backend configuration
#  Default: local state file (no setup required)
#  Switch to S3: uncomment the s3 block, comment out the local block,
#                then run:  terraform init -migrate-state
#                Prereq:   run terraform/s3-backend-bootstrap once first
# =============================================================================

terraform {
  backend "local" {}
}

# terraform {
#   backend "s3" {
#     bucket         = "bmi-health-tracker-tfstate"
#     key            = "single-server/public-http/terraform.tfstate"
#     region         = "ap-south-1"
#     encrypt        = true
#     profile        = "sarowar-ostad"
#   }
# }
