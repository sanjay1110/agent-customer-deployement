terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
  # Remote state in the customer's account (created by infra/bootstrap).
  # Configure with: terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = merge({
      Project     = var.name
      Environment = "customer-sim"
      ManagedBy   = "terraform"
      Owner       = var.owner_tag
      DataClass   = "confidential"
    }, var.extra_tags)
  }
}
