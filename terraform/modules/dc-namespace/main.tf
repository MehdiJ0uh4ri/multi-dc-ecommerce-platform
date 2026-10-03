terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.name
    labels = {
      "platform.local/dc" = var.dc
    }
    annotations = merge(var.extra_annotations, {
      # Enforced by the PodNodeSelector / PodTolerationRestriction admission
      # plugins enabled in k3d/multidc-cluster.yaml. Every pod in this namespace
      # is pinned to its DC node without per-chart nodeSelector/tolerations.
      "scheduler.alpha.kubernetes.io/node-selector" = "${var.zone_label_key}=${var.dc}"
      "scheduler.alpha.kubernetes.io/defaultTolerations" = jsonencode([{
        key      = var.taint_key
        operator = "Equal"
        value    = var.dc
        effect   = "NoSchedule"
      }])
    })
  }
}

resource "kubernetes_resource_quota_v1" "this" {
  metadata {
    name      = "${var.dc}-quota"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"           = var.quota.requests_cpu
      "requests.memory"        = var.quota.requests_memory
      "limits.cpu"             = var.quota.limits_cpu
      "limits.memory"          = var.quota.limits_memory
      "pods"                   = var.quota.pods
      "persistentvolumeclaims" = var.quota.pvcs
      "requests.storage"       = var.quota.storage
    }
  }
}

resource "kubernetes_limit_range_v1" "this" {
  metadata {
    name      = "${var.dc}-container-defaults"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default_request = {
        cpu    = var.container_defaults.request_cpu
        memory = var.container_defaults.request_memory
      }
      default = {
        cpu    = var.container_defaults.limit_cpu
        memory = var.container_defaults.limit_memory
      }
    }
  }
}

# Ingress is denied by default; only same-namespace traffic is allowed here.
# Cross-DC exceptions are declared in the root module (network-policies.tf).
resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector {}
      }
    }
  }
}
