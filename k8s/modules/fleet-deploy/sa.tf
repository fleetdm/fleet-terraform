resource "kubernetes_service_account" "fleet-sa" {
    metadata {
        name = "fleet"
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
    
        labels = {
            app = "fleet"
        }
        annotations = local.gke.workload_identity_email != "" ? merge(local.service_account_annotations, { "iam.gke.io/gcp-service-account" = local.gke.workload_identity_email}) : local.service_account_annotations
    }
}

resource "kubernetes_role" "fleet-role" {
    metadata {
        name = "fleet"
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
    }

    rule {
        api_groups = ["core"]
        resources = ["secrets"]
        resource_names = tolist([
            local.database.secret_name != "" ? local.database.secret_name : "", 
            local.cache.secret_name != "" ? local.cache.secret_name : "", 
            local.fleet.secret_name != "" ? local.fleet.secret_name : "", 
            local.osquery.secret_name != "" ? local.osquery.secret_name : ""
        ])
        verbs = ["get"]
    }    
    depends_on = [ 
        resource.kubernetes_service_account.fleet-sa
    ]
}

resource "kubernetes_role_binding" "fleet-role-binding" {
    metadata {
        name = "fleet"
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
    }

    role_ref {
        api_group = "rbac.authorization.k8s.io"
        kind = "Role"
        name = resource.kubernetes_role.fleet-role.metadata[0].name
    }

    subject {
        kind = "ServiceAccount"
        name = resource.kubernetes_service_account.fleet-sa.metadata[0].name
        namespace = data.kubernetes_namespace.fleet.metadata[0].name
    }    
    depends_on = [ 
        resource.kubernetes_role.fleet-role
    ]
}