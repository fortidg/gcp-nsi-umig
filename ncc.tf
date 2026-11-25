# NCC connects the optional demo Web VPCs and any named existing workload VPCs.
# Use the explicit MESH topology so all VPC spokes exchange routes.
data "google_compute_network" "ncc_existing_vpcs" {
  for_each = toset(var.ncc_existing_vpc_names)

  name    = each.value
  project = var.project_id
}

locals {
  ncc_spoke_networks = merge(
    {
      for key, network in google_compute_network.vpc_networks :
      key => network.self_link if contains(["web", "web2"], key)
    },
    {
      for name, network in data.google_compute_network.ncc_existing_vpcs :
      name => network.self_link
    }
  )
}

resource "google_network_connectivity_hub" "web_mesh" {
  count = length(local.ncc_spoke_networks) > 0 ? 1 : 0

  name            = "${local.prefix}-web-mesh"
  description     = "Full mesh connectivity for the NSI workload VPCs"
  project         = var.project_id
  policy_mode     = "PRESET"
  preset_topology = "MESH"

  depends_on = [google_project_service.required_apis]
}

resource "google_network_connectivity_spoke" "workload_vpcs" {
  for_each = local.ncc_spoke_networks

  name        = "${local.prefix}-${each.key}-spoke"
  description = "VPC spoke for ${each.key}"
  location    = "global"
  project     = var.project_id
  hub         = google_network_connectivity_hub.web_mesh[0].id

  linked_vpc_network {
    uri = each.value
  }
}
