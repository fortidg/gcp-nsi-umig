# VPC Peering between Web VPC and Web2 VPC
# This enables NSI traffic inspection demonstration between two VPCs.
# Only created with the demo workload (var.deploy_web_servers).

# Peering from Web VPC to Web2 VPC
resource "google_compute_network_peering" "web_to_web2" {
  count = var.deploy_web_servers ? 1 : 0

  name         = "${local.prefix}-web-to-web2-peering"
  network      = google_compute_network.vpc_networks["web"].id
  peer_network = google_compute_network.vpc_networks["web2"].id

  # Export custom routes to peer network
  export_custom_routes = true
  import_custom_routes = true

  # Export subnet routes with public IP
  export_subnet_routes_with_public_ip = true
  import_subnet_routes_with_public_ip = true
}

# Peering from Web2 VPC to Web VPC (bidirectional peering required)
resource "google_compute_network_peering" "web2_to_web" {
  count = var.deploy_web_servers ? 1 : 0

  name         = "${local.prefix}-web2-to-web-peering"
  network      = google_compute_network.vpc_networks["web2"].id
  peer_network = google_compute_network.vpc_networks["web"].id

  # Export custom routes to peer network
  export_custom_routes = true
  import_custom_routes = true

  # Export subnet routes with public IP
  export_subnet_routes_with_public_ip = true
  import_subnet_routes_with_public_ip = true

  # Ensure the first peering is created before this one
  depends_on = [google_compute_network_peering.web_to_web2]
}

# Keep existing deployments from destroying and recreating the peerings now that
# they are gated by count.
moved {
  from = google_compute_network_peering.web_to_web2
  to   = google_compute_network_peering.web_to_web2[0]
}

moved {
  from = google_compute_network_peering.web2_to_web
  to   = google_compute_network_peering.web2_to_web[0]
}
