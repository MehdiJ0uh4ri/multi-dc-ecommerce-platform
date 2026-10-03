# Separate root module for objects inside Keycloak (ADR-031). The keycloak provider talks to
# the Keycloak admin API, which only exists after the main root module has deployed
# Keycloak, so it cannot share an apply with it. Applied by `make keycloak-config`
# through a kubectl port-forward.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.9" # 5.9.0 checked on registry.terraform.io 2026-09-18
    }
  }

  # Local state next to the main module's, for the same reason (ADR-002).
  backend "local" {
    path = "state/terraform.tfstate"
  }
}
