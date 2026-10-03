# Bootstrap admin from KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD (helm-values/dc1-core/keycloak.yaml).
provider "keycloak" {
  client_id     = "admin-cli"
  username      = "admin"
  password      = var.datastore_passwords["dc1_keycloak_admin"]
  url           = var.keycloak_url
  realm         = "master"
  initial_login = false
}

data "keycloak_realm" "ecommerce" {
  realm = var.realm
}

# Service account for the Phase 4.5 seeders (client credentials). It gets no realm roles and
# no role scope: product-service only requires an authenticated caller for writes
# (docs/known-limits.md), and nothing else accepts this token.
resource "keycloak_openid_client" "platform_seeder" {
  realm_id  = data.keycloak_realm.ecommerce.id
  client_id = "platform-seeder"
  name      = "Platform data seeder (service account)"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  client_secret                = var.datastore_passwords["dc1_keycloak_seeder_client"]
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  full_scope_allowed           = false
}

output "platform_seeder_client" {
  value = {
    realm     = var.realm
    client_id = keycloak_openid_client.platform_seeder.client_id
    secret_in = "Kubernetes Secret dc1-core/data-tools-seeder-client (terraform/data-tools.tf)"
  }
}
