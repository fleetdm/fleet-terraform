resource "random_pet" "suffix" {
  length = 1
}

resource "random_password" "private_key" {
  length = 32
}

resource "google_secret_manager_secret" "database_password" {
  project   = var.project_id
  secret_id = "fleet-db-password-${random_pet.suffix.id}"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_password" {
  secret      = google_secret_manager_secret.database_password.name
  secret_data = module.mysql.generated_user_password
}

resource "google_secret_manager_secret" "private_key" {
  project   = var.project_id
  secret_id = "fleet-private-key-${random_pet.suffix.id}"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "private_key" {
  secret      = google_secret_manager_secret.private_key.name
  secret_data = random_password.private_key.result
}