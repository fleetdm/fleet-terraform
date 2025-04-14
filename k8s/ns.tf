data "kubernetes_namespace" "fleet" {
  metadata {  
    name = local.namespace
  }
}