# ──────────────────────────────────────────────
# Terraform Provider Configuration
# ──────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Used only to read the thumbprint off the cluster OIDC issuer for IRSA.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Uncomment below to use S3 backend for remote state
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "eks-monitoring/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "eks-monitoring"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
