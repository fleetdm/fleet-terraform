resource "kubernetes_ingress_v1" "fleet-ingress"{
  count = local.ingress.enabled ? 1 : 0
  metadata {
    name = "fleet"
    namespace = data.kubernetes_namespace.fleet.metadata[0].name
    labels = local.ingress.labels
    annotations = local.ingress.annotations
  }
  spec {
    ingress_class_name = local.ingress.class_name

    dynamic "tls" {
        for_each = local.ingress.tls.hosts

        content {
          hosts = [tls.value]
          secret_name = local.ingress.tls.secret_name
        }
    }
    
    dynamic "rule" {
      for_each = local.ingress.hosts

      content {
        host = rule.value.name

        http {
          dynamic "path" {
            for_each = rule.value.paths

            content {
              path = path.value.path

              backend {
                service {
                  name = resource.kubernetes_service.fleet-service.metadata[0].name
                  port {
                    number = local.fleet.listen_port
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}