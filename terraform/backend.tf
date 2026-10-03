# Local backend on purpose: a `kubernetes` backend would store state inside the
# cluster it manages, so `k3d cluster delete` would also destroy the state.
# See docs/decisions.md (ADR-002).
terraform {
  backend "local" {
    path = "state/terraform.tfstate"
  }
}
