resource "kubernetes_service" "fleet-service" {
    metadata {
        name = "fleet"
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
        annotations = local.service_annotations
    }

    spec {
        selector = {
            app = "fleet"
            component = "fleet-server"
        }

        dynamic "port" {
            for_each = local.gke.ingress.use_gke_ingress && local.gke.ingress.node_port != "" ? [
                { name = "fleet", port = local.fleet.listen_port, target_port = local.fleet.listen_port, protocol = "TCP", node_port = local.gke.ingress.node_port }
            ] : [
                { name = "fleet", port = local.fleet.listen_port, target_port = local.fleet.listen_port, protocol = "TCP", node_port = null }
            ]

            content {
                name = port.value.name
                port = port.value.port
                protocol = port.value.protocol
                target_port = port.value.target_port
                node_port = port.value.node_port
            }
        }
        
        type = local.gke.ingress.use_gke_ingress ? "NodePort" : "ClusterIP"
    }    
    depends_on = [ 
        resource.kubernetes_deployment.fleet
    ]
}
