# Cloud Router + Cloud NAT for the inspection VPC (FortiGate port1 / nic0).
#
# port1 has no external IP, so FortiGate-originated egress (FortiGuard, DNS,
# licensing, updates) has no path to the internet on its own. Cloud NAT provides
# that path. Note that Cloud NAT only applies to a NIC WITHOUT an external
# address -- if an access_config is ever added to nic0 in instance_group.tf, this
# NAT stops being used for port1.
#
# The management VPC (port2 / nic1) deliberately has no NAT: those NICs already
# carry external IPs, which bypass Cloud NAT entirely.

resource "google_compute_router" "inspection_nat_router" {
  name        = local.nat_router_name
  description = "Cloud Router for the inspection VPC NAT gateway (FortiGate port1 egress)"
  network     = google_compute_network.vpc_networks["inspection"].id
  region      = var.region
}

resource "google_compute_router_nat" "inspection_nat" {
  name   = local.nat_gateway_name
  router = google_compute_router.inspection_nat_router.name
  region = google_compute_router.inspection_nat_router.region

  # Google-allocated egress addresses, covering every subnet in the VPC so the
  # NAT keeps working if additional inspection subnets are added later.
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # A firewall opens far more concurrent sessions than a typical VM, so the
  # default static allocation of 64 ports per instance is easy to exhaust.
  # Dynamic allocation requires endpoint-independent mapping to stay off.
  enable_endpoint_independent_mapping = false
  enable_dynamic_port_allocation      = true
  min_ports_per_vm                    = 64
  max_ports_per_vm                    = 8192

  # Log dropped translations only -- this is what surfaces port exhaustion.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

  depends_on = [google_compute_subnetwork.subnets]
}
