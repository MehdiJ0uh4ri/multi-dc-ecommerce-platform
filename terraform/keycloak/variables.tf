variable "keycloak_url" {
  description = "Keycloak as reached from the Terraform host; `make keycloak-config` port-forwards svc/keycloak to this port."
  type        = string
  default     = "http://localhost:18080"
}

variable "realm" {
  description = "Realm imported from app/docker/keycloak/import/ecommerce-realm.json (terraform/gateway-identity-dc1.tf)."
  type        = string
  default     = "ecommerce"
}

variable "datastore_passwords" {
  description = "Same file as the main module: terraform/secrets.auto.tfvars.json (`make secrets`). Uses dc1_keycloak_admin and dc1_keycloak_seeder_client."
  type        = map(string)
  sensitive   = true
}
