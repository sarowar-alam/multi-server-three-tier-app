terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws" 
    version = ">= 5.0" }
  }
  # Always local state — this module manages the remote state infrastructure itself
  backend "local" {}
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}
