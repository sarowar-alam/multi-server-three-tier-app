terraform {
  backend "local" {}
}

# terraform {
#   backend "s3" {
#     bucket         = "bmi-health-tracker-tfstate"
#     key            = "single-server/public-ssl/terraform.tfstate"
#     region         = "ap-south-1"
#     encrypt        = true
#     profile        = "sarowar-ostad"
#   }
# }
