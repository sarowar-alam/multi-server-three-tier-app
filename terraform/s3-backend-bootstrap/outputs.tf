output "s3_bucket_name"      { value = aws_s3_bucket.tfstate.bucket }
output "s3_bucket_arn"       { value = aws_s3_bucket.tfstate.arn }
output "dynamodb_table_name" { value = aws_dynamodb_table.tf_locks.name }
output "next_step" {
  value = "To use S3 backend: uncomment the s3 block in any scenario's backend.tf, then run: terraform init -migrate-state"
}
