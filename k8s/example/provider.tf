terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.30.0"
    }
  }
}

/*
  To support deployments to your cloud provider's platform,
  the provider will need to be modified for access, accordingly.
  https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/guides/getting-started.html
*/
provider "kubernetes" {
  # config_path = "/path/to/kubeconfig"
  config_path = ""
}