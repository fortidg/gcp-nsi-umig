# VPC Networks
resource "google_compute_network" "vpc_networks" {
  for_each = local.vpc_networks

  name                    = each.value.name
  description             = each.value.description
  auto_create_subnetworks = each.value.auto_create_subnetworks
  mtu                     = lookup(each.value, "mtu", null)
}

# Subnets
resource "google_compute_subnetwork" "subnets" {
  for_each = local.subnets

  name                     = each.value.name
  network                  = google_compute_network.vpc_networks[each.value.vpc_key].id
  ip_cidr_range            = each.value.cidr_range
  region                   = each.value.region
  description              = each.value.description
  private_ip_google_access = each.value.enable_private_ip_google_access
}