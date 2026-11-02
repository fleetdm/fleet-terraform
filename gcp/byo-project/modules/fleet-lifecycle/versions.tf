# Provider-only Fleet migration lifecycle (no provisioners, no scripts).
# Every apply-path action is a google-beta resource, a terracurl request,
# a time_sleep or terraform_data.
terraform {
  required_version = ">= 1.11"

  required_providers {
    # Service, Job (run_execution_token) and the access token used by the
    # terracurl requests (data.google_client_config) all come from the same
    # caller-configured google-beta provider.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.35.0, < 7.0.0"
    }
    # Stop / restore PATCH and the read-only status GETs. 1.2.2 was inspected:
    # request fields are ForceNew, Read/Update issue no HTTP, `response` is
    # not Sensitive.
    terracurl = {
      source  = "devops-rob/terracurl"
      version = "~> 1.2"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}
