terraform {
  required_version = ">= 1.3.7"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }

    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.1"
    }

    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.29.0"
    }
  }
}
