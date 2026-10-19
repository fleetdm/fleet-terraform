# google-beta provider configuration for the root module.
#
# The byo-project module uses google-beta directly for
# google_project_service_identity (provisions the Cloud SQL and Secret Manager
# service agents that need KMS grants when cmek.cloud_sql / cmek.secret_manager
# are set), and registry child modules already use it (Cloud SQL instance,
# project services). Configured to match the default google provider in main.tf
# so beta-managed resources land in the same project/region with the same
# default labels. Child modules inherit this default configuration.
provider "google-beta" {
  project        = var.project_id
  region         = var.region
  default_labels = var.labels
}
