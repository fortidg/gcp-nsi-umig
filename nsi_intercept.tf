# Terraform owns the NSI producer service, consumer associations, and firewall
# policy. Existing resources created by setup-nsi.sh must be imported before
# applying this configuration.

locals {
  security_profile        = "${coalesce(var.nsi_name_prefix, var.project_id)}-ftnt-sp1"
  security_profile_group  = "${coalesce(var.nsi_name_prefix, var.project_id)}-ftnt-spg1"
  security_profile_parent = var.nsi_security_profile_scope == "organization" ? "organizations/${coalesce(var.organization_id, "unset")}" : "projects/${var.project_id}"

  demo_nsi_networks = var.deploy_web_servers ? {
    (local.web_vpc_networks.web.name)  = google_compute_network.vpc_networks["web"].id
    (local.web_vpc_networks.web2.name) = google_compute_network.vpc_networks["web2"].id
  } : {}

  nsi_consumer_networks = merge(
    local.demo_nsi_networks,
    { for name, network in data.google_compute_network.nsi_consumers : name => network.id }
  )

  # Preserve the names used by setup-nsi.sh for the demo VPCs. For extra VPCs,
  # use a short hash suffix only when the full association name exceeds 63 chars.
  nsi_endpoint_association_names = {
    for name in keys(local.nsi_consumer_networks) :
    name => name == local.web_vpc_networks.web.name && var.deploy_web_servers ? "new-fgt-nsi-ftnt-epg-assoc" :
    name == local.web_vpc_networks.web2.name && var.deploy_web_servers ? "new-fgt-nsi-ftnt-epg-assoc-web2" :
    length("newfgt-nsi-epga-${name}") <= 63 ? "newfgt-nsi-epga-${name}" :
    "newfgt-nsi-epga-${substr(name, 0, 38)}-${substr(sha1(name), 0, 8)}"
  }

  nsi_policy_association_names = {
    for name in keys(local.nsi_consumer_networks) :
    name => name == local.web_vpc_networks.web.name && var.deploy_web_servers ? "newfgt-nsi-policy-assoc" :
    name == local.web_vpc_networks.web2.name && var.deploy_web_servers ? "newfgt-nsi-policy-assoc-web2" :
    length("newfgt-nsi-fpa-${name}") <= 63 ? "newfgt-nsi-fpa-${name}" :
    "newfgt-nsi-fpa-${substr(name, 0, 39)}-${substr(sha1(name), 0, 8)}"
  }
}

data "google_compute_network" "nsi_consumers" {
  for_each = toset([
    for name in var.nsi_consumer_vpc_names : name
    if !var.deploy_web_servers || !contains([local.web_vpc_networks.web.name, local.web_vpc_networks.web2.name], name)
  ])

  name    = each.value
  project = var.project_id
}

resource "google_network_security_intercept_deployment_group" "fortigate" {
  provider = google-beta

  intercept_deployment_group_id = "newfgt-nsi-ftnt-dg"
  location                      = "global"
  project                       = var.project_id
  network                       = google_compute_network.vpc_networks["inspection"].id

  depends_on = [google_project_service.required_apis]
}

resource "google_network_security_intercept_deployment" "fortigate" {
  provider = google-beta
  for_each = google_compute_forwarding_rule.fortigate_forwarding_rules

  intercept_deployment_id    = "fgt-nsi-${replace(each.key, "-", "")}"
  location                   = each.key
  project                    = var.project_id
  forwarding_rule            = each.value.id
  intercept_deployment_group = google_network_security_intercept_deployment_group.fortigate.id
}

resource "google_network_security_intercept_endpoint_group" "fortigate" {
  provider = google-beta

  intercept_endpoint_group_id = "newfgt-nsi-ftnt-epg"
  location                    = "global"
  project                     = var.project_id
  intercept_deployment_group  = google_network_security_intercept_deployment_group.fortigate.id

  depends_on = [google_network_security_intercept_deployment.fortigate]
}

resource "google_network_security_intercept_endpoint_group_association" "consumers" {
  provider = google-beta
  for_each = local.nsi_consumer_networks

  intercept_endpoint_group_association_id = local.nsi_endpoint_association_names[each.key]
  location                                = "global"
  project                                 = var.project_id
  network                                 = each.value
  intercept_endpoint_group                = google_network_security_intercept_endpoint_group.fortigate.id

  lifecycle {
    precondition {
      condition = !contains([
        google_compute_network.vpc_networks["inspection"].name,
        google_compute_network.vpc_networks["management"].name,
      ], each.key)
      error_message = "The inspection and management VPCs cannot be NSI consumer VPCs."
    }
  }
}

resource "google_network_security_security_profile" "fortigate" {
  provider = google-beta

  name     = local.security_profile
  parent   = local.security_profile_parent
  location = "global"
  type     = "CUSTOM_INTERCEPT"

  custom_intercept_profile {
    intercept_endpoint_group = google_network_security_intercept_endpoint_group.fortigate.id
  }

  lifecycle {
    precondition {
      condition     = var.nsi_security_profile_scope == "project" || try(length(trimspace(var.organization_id)) > 0, false)
      error_message = "Set organization_id when nsi_security_profile_scope is organization."
    }
  }
}

resource "google_network_security_security_profile_group" "fortigate" {
  provider = google-beta

  name                     = local.security_profile_group
  parent                   = local.security_profile_parent
  location                 = "global"
  custom_intercept_profile = google_network_security_security_profile.fortigate.id
}

resource "google_compute_network_firewall_policy" "fortigate" {
  name    = "newfgt-nsi"
  project = var.project_id
}

resource "google_compute_network_firewall_policy_rule" "intercept" {
  for_each = {
    ingress = { priority = 10, direction = "INGRESS" }
    egress  = { priority = 11, direction = "EGRESS" }
  }

  firewall_policy        = google_compute_network_firewall_policy.fortigate.name
  project                = var.project_id
  priority               = each.value.priority
  direction              = each.value.direction
  action                 = "apply_security_profile_group"
  security_profile_group = google_network_security_security_profile_group.fortigate.id

  match {
    src_ip_ranges  = ["0.0.0.0/0"]
    dest_ip_ranges = ["0.0.0.0/0"]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

resource "google_compute_network_firewall_policy_association" "consumers" {
  for_each = local.nsi_consumer_networks

  name              = local.nsi_policy_association_names[each.key]
  firewall_policy   = google_compute_network_firewall_policy.fortigate.name
  attachment_target = each.value
  project           = var.project_id

  # Destroy policy attachments before the endpoint group associations.
  depends_on = [
    google_compute_network_firewall_policy_rule.intercept,
    google_network_security_intercept_endpoint_group_association.consumers,
  ]
}
