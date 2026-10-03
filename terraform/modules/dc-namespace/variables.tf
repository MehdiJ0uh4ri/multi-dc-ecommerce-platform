variable "name" {
  description = "Namespace name, e.g. dc1-core."
  type        = string
}

variable "dc" {
  description = "Simulated datacenter id (dc1, dc2). Must match the node zone label and taint value."
  type        = string
}

variable "zone_label_key" {
  description = "Node label used to pin this namespace's pods (PodNodeSelector)."
  type        = string
}

variable "taint_key" {
  description = "Node taint key tolerated by default in this namespace (PodTolerationRestriction)."
  type        = string
}

variable "extra_annotations" {
  description = "Additional namespace annotations (e.g. chaos-mesh.org/inject=enabled)."
  type        = map(string)
  default     = {}
}

variable "quota" {
  description = "ResourceQuota hard limits."
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
    pods            = number
    pvcs            = number
    storage         = string
  })
}

variable "container_defaults" {
  description = "LimitRange defaults, needed because a quota on requests/limits rejects pods that omit them."
  type = object({
    request_cpu    = string
    request_memory = string
    limit_cpu      = string
    limit_memory   = string
  })
}
