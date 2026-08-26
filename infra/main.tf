terraform {
  required_version = ">= 1.4.0"

  # EMPTY backend by contract: bucket/key/region arrive via -backend-config
  # flags from the platform (deterministic key = PROJECT_NAME/terraform.tfstate).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 5.83.0"
    }
  }
}

# Region comes from AWS_REGION in the pipeline environment.
provider "aws" {}
