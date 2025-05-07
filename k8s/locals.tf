locals {
    namespace = var.namespace
    hostname = var.hostname
    replicas = var.replicas
    image_repository = var.image_repository
    image_tag = var.image_tag
    image_pull_secrets = var.image_pull_secrets
    pod_annotations = var.pod_annotations
    service_annotations = var.service_annotations
    service_account_annotations = var.service_account_annotations
    resources = var.resources
    vuln_processing = var.vuln_processing
    node_selector = var.node_selector
    tolerations = var.tolerations
    affinity_rules = var.affinity_rules
    anti_affinity_rules = var.anti_affinity_rules
    ingress = var.ingress
    fleet = var.fleet
    osquery = var.osquery
    database = var.database
    cache = var.cache
    gke = var.gke
    environment_variables = var.environment_variables
    environment_from_config_maps = var.environment_from_config_maps
    environment_from_secrets = var.environment_from_secrets
}