terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.30.0"
    }
  }
}

provider "kubernetes" {
  # config_path = "/path/to/kubeconfig"
  config_path = ""
}