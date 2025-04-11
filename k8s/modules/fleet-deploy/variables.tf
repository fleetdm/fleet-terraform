variable "namespace" {
    type = string
    default = "fleet"
    description = "The value for this variable will be used as the name of the namespace that fleet will be deployed to"
}

variable "hostname" {
    type = string
    default = "fleet.localhost"
    description = "The value for this variable will be used as the hostname that you will access fleet on"
}

variable "replicas" {
    type = number
    default = 3
    description = "The value for this variable will be used to drive the number of fleet deployment replicas"
}

variable "image_repository" {
    type = string
    default = "fleetdm/fleet"
    description = "The value for this variable will be used to populate the image repository for fleet"
}

variable "image_tag" {
    type = string
    default = "v4.66.0"
    description = "The value for this variable will be used to populate the fleet version that will be deployed"
}

variable "pod_annotations" {
    type = map
    default = {}
}

variable "service_annotations" {
    type = map
    default = {}
}

variable "service_account_annotations" {
    type = map
    default = {}
}

variable "resources" {
    type = object({
        limits = optional(object({
            cpu = optional(string, "1")
            memory = optional(string, "4Gi")
        }),{
            cpu = "1"
            memory = "4Gi"
        })
        requests = optional(object({
            cpu = optional(string, "0.1")
            memory = optional(string, "50Mi")
        }),{
            cpu = "0.1"
            memory = "50Mi"
        })
    })
}

variable "node_selector" {
    type = map
    default = {}
}

variable "tolerations" {
    type = list(any)
    default = []
}

variable "environment_variables" {
    type = list(map(string))
    default = []
}

variable "environment_from_config_maps" {
    type = list(map(string))
    default = []
}

variable "environment_from_secrets" {
    type = list(map(string))
    default = []
}

/*
    affinity
*/
variable "affinity" {
    type = map
    default = {}
}

/*
    vuln_processing
*/
variable "vuln_processing" {
    type = object({
        ttl_seconds_after_finished = optional(number, 100)
        restart_policy = optional(string, "Never")
        dedicated = optional(bool, false)
        schedule = optional(string, "0 * * * *")
        resources = object({
            limits = optional(object({
                cpu = optional(string, "1")
                memory = optional(string, "4Gi")
            }),{
                cpu = "1"
                memory = "4Gi"
            })
            requests = optional(object({
                cpu = optional(string, "0.1")
                memory = optional(string, "50Mi")
            }),{
                cpu = "0.1"
                memory = "50Mi"
            })
        })
    })
}

/*
    ingress
*/
variable "ingress" {
    type = object({
        enabled = optional(bool, false)
        class_name = optional(string, "")
        labels = optional(map(string), {})
        annotations = optional(map(string), {})
        hosts = optional(list(any), [])
        tls = object({
            secret_name = optional(string, "")
            hosts = optional(list(string),[])
        })
    })
}

variable "fleet" {
    type = object({
        listen_port = optional(number, 8080)
        secret_name = optional(string, "fleet")
        migrations = object({
            auto_apply_sql_migrations = optional(bool, true)
            migration_job_annotations = optional(map(string), {})
            parallelism = optional(number, 1)
            completions = optional(number, 1)
            active_deadline_seconds = optional(number, 900)
            backoff_limit = optional(number, 6)
            ttl_seconds_after_finished = optional(number, 100)
            manual_selector = optional(bool, false)
            restart_policy = optional(string, "Never")
        })
        tls = object({
            enabled = optional(bool, false)
            unique_tls_secret = optional(bool, false)
            secret_name = optional(string, "fleet-tls")
            compatibility = optional(string, "modern")
            cert_secret_key = optional(string, "server.cert")
            key_secret_key = optional(string, "server.key")
        })
        auth = object({
            b_crypto_cost = optional(number, 12)
            salt_key_size = optional(number, 24)
        })
        app = object({
            token_key_size = optional(number, 24)
            invite_token_validity_period = optional(string, "120h")
        })
        session = object({
            key_size = optional(number, 64)
            duration = optional(string, "2160h")
        })
        logging = object({
            debug = optional(bool, false)
            json = optional(bool, false)
            disable_banner = optional(bool, false)
        })
        carving = object({
            s3 = object({
                bucket_name = optional(string, "")
                prefix = optional(string, "")
                access_key_id = optional(string, "")
                secret_key = optional(string, "s3-bucket")
                sts_assume_role_arn = optional(string, "")
            })
        })
        license = object({
            secret_name = optional(string, "")
            license_key = optional(string, "license-key")
        })
        extra_volumes = optional(list(any), [])
        extra_volume_mounts = optional(list(any), [])
        security_context = object({
            run_as_user = optional(number, 3333)
            run_as_group = optional(number, 3333)
        })
    })
}

variable "osquery" {
    type = object({
        secret_name = optional(string, "osquery")
        node_key_size = optional(number, 24)
        label_update_interval = optional(string, "30m")
        detail_update_interval = optional(string, "30m")
        logging = object({
            status_plugin = optional(string, "filesystem")
            result_plugin = optional(string, "filesystem")
            filesystem = object({
                status_log_file = optional(string, "osquery_status")
                result_log_file = optional(string, "osquery_result")
                enable_rotation = optional(bool, false)
                enable_compression = optional(bool, false)
                volume_size = optional(string, "20Gi")
            })
            firehose = object({
                region = optional(string, "")
                access_key_id = optional(string, "")
                secret_key = optional(string, "firehose")
                sts_assume_role_arn = optional(string, "")
                status_stream = optional(string, "")
                result_stream = optional(string, "")
            })
            kinesis = object({
                region = optional(string, "")
                access_key_id = optional(string, "")
                secret_key = optional(string, "kinesis")
                sts_assume_role_arn = optional(string, "")
                status_stream = optional(string, "")
                result_stream = optional(string, "")
            })
            lambda = object({
                region = optional(string, "")
                access_key_id = optional(string, "")
                secret_key = optional(string, "lambda")
                sts_assume_role_arn = optional(string, "")
                status_stream = optional(string, "")
                result_stream = optional(string, "")
            })
            pubsub = object({
                project = optional(string, "")
                status_topic = optional(string, "")
                result_topic = optional(string, "")
            })
        })
    })
}

variable "database" {
    type = object({
        enabled = optional(bool, false)
        secret_name = optional(string, "password")
        address = optional(string, "mysql:3306")
        database = optional(string, "fleet")
        username = optional(string, "fleet")
        password_key = optional(string, "mysql-password")
        max_open_conns = optional(number, 50)
        max_idle_conns = optional(number, 50)
        conn_max_lifetime = optional(number, 0)

        tls = object({
            enabled = optional(bool, false)
            config = optional(string, "")
            server_name = optional(string, "")
            ca_cert_key = optional(string, "")
            cert_key = optional(string, "")
            key_key = optional(string, "")
        })
    })
}

variable "cache" {
    type = object({
        enabled = optional(bool, false)
        address = optional(string, "redis:6379")
        database = optional(number, 0)
        use_password = optional(bool, false)
        secret_name = optional(string, "redis-password")
        password_key = optional(string, "redis")
    })
}

variable "gke" {
    type = object({
        workload_identity_email = optional(string, "")
        cloud_sql = object({
            enable_proxy = optional(bool, false)
            image_repository = optional(string, "gcr.io/cloudsql-docker/gce-proxy")
            image_tag = optional(string, "1.17-alpine")
            verbose = optional(bool, true)
            instance_name = optional(string, "")
        })
        ingress = object({
            use_managed_certificate = optional(bool, false)
            use_gke_ingress = optional(bool, false)
            node_port = optional(number, 0)
            hostnames = optional(list(string), [""])
        })
    })
}