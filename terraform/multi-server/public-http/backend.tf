terraform {
  backend "local" {}
}

# terraform {
#   backend "s3" {
#     bucket         = "bmi-health-tracker-tfstate"
#     key            = "multi-server/public-http/terraform.tfstate"
#     region         = "ap-south-1"
#     dynamodb_table = "bmi-tf-locks"
#     encrypt        = true
#     profile        = "sarowar-ostad"
#   }
# }
