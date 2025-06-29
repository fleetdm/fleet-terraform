## Fleet deployment with Terraform

This deployment guide has been tested with
- k3s
  - istio ingress
  - nginx ingress

### Usage

#### 1. Create namespace

This terraform will not auto-provision a namespace. You can add one with `kubectl create namespace <name>` or by creating a YAML file containing a service and applying it to your cluster.

#### 2. Create Secrets

If you have a requirement to pull container images from a Private registry via `image_pull_secrets`, you can configure them using the instructions below. Additionally, you can instruct the terraform desployment to add the image\_pull\_secret via `module.fleet.image_pull_secrets`.

```
kubectl create secret docker-registry <secret_name> \
  --docker-server=<your_private_registry_url> \
  --docker-username=<your_user_name> \
  --docker-password=<your_password> \
  --docker-email=<your_email> \
  --dry-run=client -o yaml
```

The output that is generated by the above command will generate a file that looks like the below format, you can copy and paste to save to a file or redirect the output directly into a file.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <secret_name>
  namespace: <namespace_name>
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64_encoded_config>
```

In order for the deployment to go through successfully, you'll need to create some secrets so Fleet knows how to authenticate against things like MySQL and Redis.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: redis
  namespace: <namespace>
type: kubernetes.io/basic-auth
stringData:
  password: <redis-password-here>
---
apiVersion: v1
kind: Secret
metadata:
  name: mysql
  namespace: <namespace>
type: kubernetes.io/basic-auth
stringData:
  password: <mysql-password-here>
```

If you use Fleet's TLS capabilities, TLS connections to the MySQL server, or AWS access secret keys, additional secrets and keys are needed. The name of each `Secret` must match the value of `secret_name` for each section in `module.fleet` located in `main.tf`. The key of each secret must match the related key value from the values file. For example, to configure Fleet's TLS, you would use a secret like the one below.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: fleet
  namespace: <namespace_name>
type: kubernetes.io/tls
data:
  tls.crt: |
    <base64-encoded-tls-cert-here>
  tls.key: |
    <base64-encoded-tls-key-here>
```

If you have a Fleet premium license you would create a secret like the one below.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: license
  namespace: <namespace>
type: Opaque
stringData:
  license-key: <fleet-license-here>
```

Once all of your secrets are configured, use `kubectl apply -f <secret_file_name.yaml> --namespace <your_namespace>` to configure them in the cluster.

#### 3. Further Configuration

To configure how Fleet runs, such as specifying the number of Fleet instances to deploy or changing the logger plugin for Fleet, edit the `module.fleet` located in `main.tf` file to your desired settings.

##### nginx ingress

Assuming no other ingress controllers are deployed to your environment, you can deploy nginx ingress components by executing `kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.7.1/deploy/static/provider/baremetal/deploy.yaml`

You will need an nginx ingress `Service`, similar to the one below. To deploy run `kubectl apply -f <path_to_service_file>`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-loadbalancer
  namespace: ingress-nginx
spec:
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 80
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
  type: LoadBalancer
```

The below will be in preparation for deployment through the `terraform apply` in step 5.

In `main.tf` make sure the following variable `fleet.tls.enabled = false`, otherwise the Fleet terraform deployment will fail.
In `main.tf` make sure the following map is configured with the correct values.
  - `ingress.enabled` must be `true`, if you'd like Fleet to deploy the nginx ingress for you.
  - `ingress.class_name` needs to be set to `nginx`, but can be changed to values like `traefik`, if you have another compatible ingress.
  - `ingress.hosts.name` must have a matching entry in `ingress.tls.hosts`
    - example: `ingress.hosts.name = fleet.example.com` and `ingress.tls.hosts = fleet.example.com`
  - Last, `ingress.tls.secret_name` must be a valid secret name in your current namespace.*
    - Note: The TLS must contain a valid certificate that matches the hostnames provided for `ingress.hosts.name` and `ingress.tls.hosts`.
```
...
    ingress = {
        enabled = true
        class_name = "nginx"
        annotations = {}
        labels = {}
        hosts = [{
            name = "fleet.localhost.local"
            paths = [{
                path = "/"
                path_type = "ImplementationSpecific"
            }]
        }]
        tls = {
            secret_name = "chart-example-tls"
            hosts = [
                "fleet.localhost.local"
            ]
        }
    }
...
```

##### istio ingress

There are different ways to deploy istio to your cluster. We will cover the helm deployment in the [official istio documentation](https://istio.io/latest/docs/setup/install/helm/).

Assuming no other ingress controllers are deployed to your environment, you can deploy istio components by executing the following commands.

```sh
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
kubectl create namespace istio-system
helm install istio-base istio/base -n istio-system
helm install istiod istio/istiod -n istio-system
kubectl create namespace istio-ingress
helm install istio-ingress istio/gateway -n istio-ingress --wait
```

In `main.tf` make sure the following variable `fleet.tls.enabled = false`, otherwise the Fleet terraform deployment will fail.

You will need to create a TLS secret specifically for use by the istio ingress gateway like the example below or re-use Fleet secret created in step 2. You can apply the secret with the following command `kubectl apply -f <path_to_secret_yaml_file>`.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: fleet
  namespace: <namespace_name>
type: kubernetes.io/tls
data:
  tls.crt: |
    <base64-encoded-tls-cert-here>
  tls.key: |
    <base64-encoded-tls-cert-here>
```

After the secret has been created, you can create your istio ingress `Gateway` and istio `Virtual Service`. In the examble below you should make reference, in the `Gateway` and `VirtualService` to hostname (example: `fleet.example.com`) covered by your TLS certificate stored in the TLS secret created above (example: `fleet`).

```yaml
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-gateway-fleet
  namespace: <namespace_name>
spec:
  selector:
    istio: ingress # use istio default ingress gateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: fleet # must be the same as secret
    hosts:
    - 'fleet.example.com'
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: fleet-vs
  namespace: <namespace_name>
spec:
  hosts:
  - "fleet.example.com"
  gateways:
  - istio-gateway-fleet
  http:
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        port:
          number: 8080
        host: fleet
```

#### 4. Setup provider.tf

Setup your `provider.tf` with the correct credentials, whether it's for a self-hosted or managed service k8s deployment. The following [link to the kubernetes provider terraform docs](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/guides/getting-started.html) has examples documented for AWS EKS, GCP GKE, and Azure.

```
provider "kubernetes" {
  # config_path = "/path/to/kubeconfig"
  config_path = ""
}
```

#### 5. Deploy Fleet

From the location where your `main.tf` resides, execute the following commands.

```sh
terraform init
terraform plan
terraform apply
```

### Upgrade Fleet

Fleet should not be running when an upgrade is initiated because database migrations need to take place first. After `main.tf` has been updated to increment the version of the Fleet `image_tag`, the following commands can be executed to upgrade Fleet while bringing Fleet down so migrations can run.

```sh
terraform init
terraform apply -replace=module.fleet.kubernetes_deployment.fleet
```

### Remove Fleet

#### 1. Tear down Fleet

From the location where your `main.tf` resides, execute the following commands.

```sh
terraform init
terraform destroy
```

#### 2. Remove all secrets

Using the file configured for your secrets, use `kubectl delete -f <secret_file_name.yaml> --namespace <your_namespace>` to remove the secrets.

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.37.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [kubernetes_cron_job_v1.fleet_vuln_processing_cron_job](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) | resource |
| [kubernetes_deployment.fleet](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment) | resource |
| [kubernetes_ingress_v1.fleet-ingress](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_job.migration](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job) | resource |
| [kubernetes_role.fleet-role](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role) | resource |
| [kubernetes_role_binding.fleet-role-binding](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding) | resource |
| [kubernetes_service.fleet-service](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service) | resource |
| [kubernetes_service_account.fleet-sa](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account) | resource |
| [kubernetes_namespace.fleet](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/namespace) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_affinity_rules"></a> [affinity\_rules](#input\_affinity\_rules) | Used to configure affinity rules for the fleet deployment, migration job, and vuln-processing cron job. | <pre>object({ <br/>        required_during_scheduling_ignored_during_execution = optional(list(any), [])<br/>        preferred_during_scheduling_ignored_during_execution = optional(list(any), [])<br/>    })</pre> | n/a | yes |
| <a name="input_anti_affinity_rules"></a> [anti\_affinity\_rules](#input\_anti\_affinity\_rules) | Used to configure anti-affinity rules for the fleet deployment, migration job, and vuln-processing cron job. | <pre>object({ <br/>        required_during_scheduling_ignored_during_execution = optional(list(any), [])<br/>        preferred_during_scheduling_ignored_during_execution = optional(list(any),<br/>        [<br/>            {<br/>                weight = 100<br/>                label_selector = {<br/>                    match_expressions = [<br/>                        {<br/>                            key = "app"<br/>                            operator = "In"<br/>                            values = ["fleet"]<br/>                        }<br/>                    ]<br/>                }<br/>                topology_key = "kubernetes.io/hostname"<br/>            }<br/>        ])<br/>    })</pre> | n/a | yes |
| <a name="input_cache"></a> [cache](#input\_cache) | Used to configure redis specific values for use in the Fleet deployment, migration job, and vuln-processing cron job. | <pre>object({<br/>        enabled = optional(bool, false)<br/>        address = optional(string, "redis:6379")<br/>        database = optional(number, 0)<br/>        use_password = optional(bool, false)<br/>        secret_name = optional(string, "redis")<br/>        password_key = optional(string, "password")<br/>    })</pre> | n/a | yes |
| <a name="input_database"></a> [database](#input\_database) | Used to configure database specific values for use in the Fleet deployment, migration job, and vuln-processing cron job. | <pre>object({<br/>        enabled = optional(bool, false)<br/>        secret_name = optional(string, "mysql")<br/>        address = optional(string, "mysql:3306")<br/>        database = optional(string, "fleet")<br/>        username = optional(string, "fleet")<br/>        password_key = optional(string, "password")<br/>        max_open_conns = optional(number, 50)<br/>        max_idle_conns = optional(number, 50)<br/>        conn_max_lifetime = optional(number, 0)<br/><br/>        tls = object({<br/>            enabled = optional(bool, false)<br/>            config = optional(string, "")<br/>            server_name = optional(string, "")<br/>            ca_cert_key = optional(string, "")<br/>            cert_key = optional(string, "")<br/>            key_key = optional(string, "")<br/>        })<br/>    })</pre> | n/a | yes |
| <a name="input_database_read_replica"></a> [database\_read\_replica](#input\_database\_read\_replica) | Used to configure database\_read\_replica specific values for use in the Fleet deployment and vuln-processing cron job. | <pre>object({<br/>        enabled = optional(bool, false)<br/>        secret_name = optional(string, "mysql")<br/>        address = optional(string, "mysql-ro:3306")<br/>        database = optional(string, "fleet")<br/>        username = optional(string, "fleet-ro")<br/>        password_key = optional(string, "ro-password")<br/>        password_path = optional(string,"")<br/>        max_open_conns = optional(number, 50)<br/>        max_idle_conns = optional(number, 50)<br/>        conn_max_lifetime = optional(number, 0)<br/><br/>        tls = object({<br/>            enabled = optional(bool, false)<br/>            config = optional(string, "")<br/>            server_name = optional(string, "")<br/>            ca_cert_key = optional(string, "")<br/>            cert_key = optional(string, "")<br/>            key_key = optional(string, "")<br/>        })<br/>    })</pre> | n/a | yes |
| <a name="input_environment_from_config_maps"></a> [environment\_from\_config\_maps](#input\_environment\_from\_config\_maps) | Used to configure additional environment variables from a config map for the fleet deployment and vuln-processing cron job. | `list(map(string))` | `[]` | no |
| <a name="input_environment_from_secrets"></a> [environment\_from\_secrets](#input\_environment\_from\_secrets) | Used to configure additional environment variables from a secret for the fleet deployment and vuln-processing cron job. | `list(map(string))` | `[]` | no |
| <a name="input_environment_variables"></a> [environment\_variables](#input\_environment\_variables) | Used to configure additional environment variables for the fleet deployment and vuln-processing cron job. | `list(map(string))` | `[]` | no |
| <a name="input_fleet"></a> [fleet](#input\_fleet) | Used to configure Fleet specific values for use in the Fleet deployment, migration job, and vuln-processing cron job. | <pre>object({<br/>        listen_port = optional(number, 8080)<br/>        secret_name = optional(string, "fleet")<br/>        migrations = object({<br/>            auto_apply_sql_migrations = optional(bool, true)<br/>            migration_job_annotations = optional(map(string), {})<br/>            parallelism = optional(number, 1)<br/>            completions = optional(number, 1)<br/>            active_deadline_seconds = optional(number, 900)<br/>            backoff_limit = optional(number, 6)<br/>            manual_selector = optional(bool, false)<br/>            restart_policy = optional(string, "Never")<br/>        })<br/>        tls = object({<br/>            enabled = optional(bool, false)<br/>            unique_tls_secret = optional(bool, false)<br/>            secret_name = optional(string, "fleet-tls")<br/>            compatibility = optional(string, "modern")<br/>            cert_secret_key = optional(string, "server.cert")<br/>            key_secret_key = optional(string, "server.key")<br/>        })<br/>        auth = object({<br/>            b_crypto_cost = optional(number, 12)<br/>            salt_key_size = optional(number, 24)<br/>        })<br/>        app = object({<br/>            token_key_size = optional(number, 24)<br/>            invite_token_validity_period = optional(string, "120h")<br/>        })<br/>        session = object({<br/>            key_size = optional(number, 64)<br/>            duration = optional(string, "2160h")<br/>        })<br/>        logging = object({<br/>            debug = optional(bool, false)<br/>            json = optional(bool, false)<br/>            disable_banner = optional(bool, false)<br/>        })<br/>        carving = object({<br/>            s3 = object({<br/>                bucket_name = optional(string, "")<br/>                prefix = optional(string, "")<br/>                access_key_id = optional(string, "")<br/>                secret_key = optional(string, "s3-bucket")<br/>                sts_assume_role_arn = optional(string, "")<br/>            })<br/>        })<br/>        license = object({<br/>            secret_name = optional(string, "")<br/>            license_key = optional(string, "license-key")<br/>        })<br/>        extra_volumes = optional(list(any), [])<br/>        extra_volume_mounts = optional(list(any), [])<br/>        security_context = object({<br/>            run_as_user = optional(number, null)<br/>            run_as_group = optional(number, null)<br/>            run_as_non_root = optional(bool, true)<br/>        })<br/>    })</pre> | n/a | yes |
| <a name="input_gke"></a> [gke](#input\_gke) | Used to configure gke specific values for use in the Fleet deployment, migration job, and vuln-processing cron job. | <pre>object({<br/>        workload_identity_email = optional(string, "")<br/>        cloud_sql = object({<br/>            enable_proxy = optional(bool, false)<br/>            image_repository = optional(string, "gcr.io/cloudsql-docker/gce-proxy")<br/>            image_tag = optional(string, "1.17-alpine")<br/>            verbose = optional(bool, true)<br/>            instance_name = optional(string, "")<br/>        })<br/>        ingress = object({<br/>            use_managed_certificate = optional(bool, false)<br/>            use_gke_ingress = optional(bool, false)<br/>            node_port = optional(number, 0)<br/>            hostnames = optional(list(string), [""])<br/>        })<br/>    })</pre> | n/a | yes |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Used as the hostname that you will access fleet on. | `string` | `"fleet.localhost"` | no |
| <a name="input_image_pull_secrets"></a> [image\_pull\_secrets](#input\_image\_pull\_secrets) | Used to inject image pull secrets for access to a private container registry. | <pre>list(object({<br/>        name = string<br/>    }))</pre> | `[]` | no |
| <a name="input_image_repository"></a> [image\_repository](#input\_image\_repository) | Used to populate the image repository for fleet. | `string` | `"fleetdm/fleet"` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | Used to populate the fleet version that will be deployed. | `string` | `"v4.66.0"` | no |
| <a name="input_ingress"></a> [ingress](#input\_ingress) | Used to configure values for ingress. | <pre>object({<br/>        enabled = optional(bool, false)<br/>        class_name = optional(string, "nginx")<br/>        labels = optional(map(string), {})<br/>        annotations = optional(map(string), {})<br/>        hosts = optional(list(any), [])<br/>        tls = object({<br/>            secret_name = optional(string, "")<br/>            hosts = optional(list(string),[])<br/>        })<br/>    })</pre> | n/a | yes |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | The value for this variable will be used as the name of the namespace that fleet will be deployed to. | `string` | `"fleet"` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Used to populate node selector values. | `map` | `{}` | no |
| <a name="input_osquery"></a> [osquery](#input\_osquery) | Used to configure osquery specific values for use in the Fleet deployment, migration job, and vuln-processing cron job. | <pre>object({<br/>        secret_name = optional(string, "osquery")<br/>        node_key_size = optional(number, 24)<br/>        label_update_interval = optional(string, "30m")<br/>        detail_update_interval = optional(string, "30m")<br/>        logging = object({<br/>            status_plugin = optional(string, "filesystem")<br/>            result_plugin = optional(string, "filesystem")<br/>            filesystem = object({<br/>                status_log_file = optional(string, "osquery_status")<br/>                result_log_file = optional(string, "osquery_result")<br/>                enable_rotation = optional(bool, false)<br/>                enable_compression = optional(bool, false)<br/>                volume_size = optional(string, "20Gi")<br/>            })<br/>            firehose = object({<br/>                region = optional(string, "")<br/>                access_key_id = optional(string, "")<br/>                secret_key = optional(string, "firehose")<br/>                sts_assume_role_arn = optional(string, "")<br/>                status_stream = optional(string, "")<br/>                result_stream = optional(string, "")<br/>            })<br/>            kinesis = object({<br/>                region = optional(string, "")<br/>                access_key_id = optional(string, "")<br/>                secret_key = optional(string, "kinesis")<br/>                sts_assume_role_arn = optional(string, "")<br/>                status_stream = optional(string, "")<br/>                result_stream = optional(string, "")<br/>            })<br/>            lambda = object({<br/>                region = optional(string, "")<br/>                access_key_id = optional(string, "")<br/>                secret_key = optional(string, "lambda")<br/>                sts_assume_role_arn = optional(string, "")<br/>                status_stream = optional(string, "")<br/>                result_stream = optional(string, "")<br/>            })<br/>            pubsub = object({<br/>                project = optional(string, "")<br/>                status_topic = optional(string, "")<br/>                result_topic = optional(string, "")<br/>            })<br/>        })<br/>    })</pre> | n/a | yes |
| <a name="input_pod_annotations"></a> [pod\_annotations](#input\_pod\_annotations) | Used to populate the annotations for pods. | `map` | `{}` | no |
| <a name="input_replicas"></a> [replicas](#input\_replicas) | Used to drive the number of fleet deployment replicas. | `number` | `3` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | Used to populate resource values for the fleet deployment and migration job. | <pre>object({<br/>        limits = optional(object({<br/>            cpu = optional(string, "1")<br/>            memory = optional(string, "4Gi")<br/>        }),{<br/>            cpu = "1"<br/>            memory = "4Gi"<br/>        })<br/>        requests = optional(object({<br/>            cpu = optional(string, "0.1")<br/>            memory = optional(string, "50Mi")<br/>        }),{<br/>            cpu = "0.1"<br/>            memory = "50Mi"<br/>        })<br/>    })</pre> | n/a | yes |
| <a name="input_service_account_annotations"></a> [service\_account\_annotations](#input\_service\_account\_annotations) | Used to populate the annotations for the fleet service account. | `map` | `{}` | no |
| <a name="input_service_annotations"></a> [service\_annotations](#input\_service\_annotations) | Used to populate the annotations for the fleet service. | `map` | `{}` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Used to configure tolerations. | `list(any)` | `[]` | no |
| <a name="input_vuln_processing"></a> [vuln\_processing](#input\_vuln\_processing) | Used to configure the values for the vuln-processing cron job. | <pre>object({<br/>        ttl_seconds_after_finished = optional(number, 100)<br/>        restart_policy = optional(string, "Never")<br/>        dedicated = optional(bool, false)<br/>        schedule = optional(string, "0 * * * *")<br/>        resources = object({<br/>            limits = optional(object({<br/>                cpu = optional(string, "1")<br/>                memory = optional(string, "4Gi")<br/>            }),{<br/>                cpu = "1"<br/>                memory = "4Gi"<br/>            })<br/>            requests = optional(object({<br/>                cpu = optional(string, "0.1")<br/>                memory = optional(string, "50Mi")<br/>            }),{<br/>                cpu = "0.1"<br/>                memory = "50Mi"<br/>            })<br/>        })<br/>    })</pre> | n/a | yes |

## Outputs

No outputs.
