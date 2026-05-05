## Optional dev/test MySQL deployment.
## Set database.enabled = true to deploy. For production, use an external MySQL.

resource "random_password" "mysql_root_password" {
  count   = local.database.enabled ? 1 : 0
  length  = 16
  special = false
}

resource "random_password" "mysql_password" {
  count   = local.database.enabled ? 1 : 0
  length  = 16
  special = false
}

locals {
  mysql_root_password = local.database.enabled ? (local.database.mysql.root_password != "" ? local.database.mysql.root_password : random_password.mysql_root_password[0].result) : ""
  mysql_password      = local.database.enabled ? (local.database.mysql.password != "" ? local.database.mysql.password : random_password.mysql_password[0].result) : ""
}

resource "kubernetes_secret" "mysql" {
  count = local.database.enabled ? 1 : 0

  metadata {
    name      = local.database.secret_name
    namespace = data.kubernetes_namespace.fleet.metadata[0].name
    labels = {
      app = "mysql"
    }
  }

  data = {
    "mysql-root-password" = local.mysql_root_password
    "mysql-password"      = local.mysql_password
  }

  type = "Opaque"
}

resource "kubernetes_service" "mysql" {
  count = local.database.enabled ? 1 : 0

  metadata {
    name      = "mysql"
    namespace = data.kubernetes_namespace.fleet.metadata[0].name
    labels = {
      app = "mysql"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "mysql"
    }

    port {
      name        = "mysql"
      port        = 3306
      target_port = 3306
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_stateful_set" "mysql" {
  count = local.database.enabled ? 1 : 0

  metadata {
    name      = "mysql"
    namespace = data.kubernetes_namespace.fleet.metadata[0].name
    labels = {
      app = "mysql"
    }
  }

  spec {
    service_name = "mysql"
    replicas     = 1

    selector {
      match_labels = {
        app = "mysql"
      }
    }

    template {
      metadata {
        labels = {
          app = "mysql"
        }
      }

      spec {
        container {
          name  = "mysql"
          image = "${local.database.mysql.image_repository}:${local.database.mysql.image_tag}"

          port {
            name           = "mysql"
            container_port = 3306
            protocol       = "TCP"
          }

          env {
            name = "MYSQL_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mysql[0].metadata[0].name
                key  = "mysql-root-password"
              }
            }
          }

          env {
            name  = "MYSQL_USER"
            value = local.database.username
          }

          env {
            name = "MYSQL_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mysql[0].metadata[0].name
                key  = "mysql-password"
              }
            }
          }

          env {
            name  = "MYSQL_DATABASE"
            value = local.database.database
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "mysqladmin ping -h localhost -u root -p\"$MYSQL_ROOT_PASSWORD\""]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "mysqladmin ping -h localhost -u root -p\"$MYSQL_ROOT_PASSWORD\""]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            limits = {
              cpu    = local.database.mysql.resources.limits.cpu
              memory = local.database.mysql.resources.limits.memory
            }
            requests = {
              cpu    = local.database.mysql.resources.requests.cpu
              memory = local.database.mysql.resources.requests.memory
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
          }
        }
      }
    }

    dynamic "volume_claim_template" {
      for_each = local.database.mysql.persistence.enabled ? [1] : []

      content {
        metadata {
          name = "data"
        }
        spec {
          access_modes = ["ReadWriteOnce"]
          resources {
            requests = {
              storage = local.database.mysql.persistence.size
            }
          }
          storage_class_name = local.database.mysql.persistence.storage_class != "" ? local.database.mysql.persistence.storage_class : null
        }
      }
    }
  }
}
