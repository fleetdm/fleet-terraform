## Optional dev/test Valkey (Redis-compatible) deployment.
## Set cache.enabled = true to deploy. For production, use an external Redis/Valkey.

resource "kubernetes_service" "redis" {
  count = local.cache.enabled ? 1 : 0

  metadata {
    name      = "redis"
    namespace = data.kubernetes_namespace.fleet.metadata[0].name
    labels = {
      app = "redis"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "redis"
    }

    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment" "redis" {
  count = local.cache.enabled ? 1 : 0

  metadata {
    name      = "redis"
    namespace = data.kubernetes_namespace.fleet.metadata[0].name
    labels = {
      app = "redis"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        container {
          name  = "redis"
          image = "${local.cache.redis.image_repository}:${local.cache.redis.image_tag}"

          port {
            name           = "redis"
            container_port = 6379
            protocol       = "TCP"
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            limits = {
              cpu    = local.cache.redis.resources.limits.cpu
              memory = local.cache.redis.resources.limits.memory
            }
            requests = {
              cpu    = local.cache.redis.resources.requests.cpu
              memory = local.cache.redis.resources.requests.memory
            }
          }
        }
      }
    }
  }
}
