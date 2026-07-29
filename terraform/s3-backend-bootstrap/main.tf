# =============================================================================
#  S3 Backend Bootstrap — run ONCE before using S3 backend in any scenario
#
#  Creates:
#    1. S3 bucket  (versioned, encrypted) for Terraform state files
#    2. DynamoDB table for state locking (prevents concurrent applies)
#
#  Usage:
#    terraform init
#    terraform apply
#
#  After applying, edit backend.tf in any scenario folder to uncomment the
#  S3 block, then run: terraform init -migrate-state
# =============================================================================

resource "aws_s3_bucket" "tfstate" {
  bucket = var.bucket_name
  tags = {
    Project   = "bmi-health-tracker"
    ManagedBy = "terraform"
    Purpose   = "terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project   = "bmi-health-tracker"
    ManagedBy = "terraform"
    Purpose   = "terraform-state-lock"
  }
}
