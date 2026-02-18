terraform {
  required_version = ">= 1.3.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.29.0"
      configuration_aliases = [
        aws.destination,
        aws.target,
      ]
    }
  }
}
