# Internal Load Balancer IP for FortiGate loopback interface
resource "google_compute_address" "ilb_ip" {
  name         = "${local.prefix}-ilb-ip"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.subnets["inspection_central"].id
  description  = "Internal IP for FortiGate loopback interface (port1-ilb-probe)"
}

# Frontend IPs for additional loopback interfaces
resource "google_compute_address" "ilb_frontend_ips" {
  for_each = toset(var.zones)

  name         = "${local.prefix}-ilb-frontend-${each.key}"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.subnets["inspection_central"].id
  description  = "Frontend IP for FortiGate loopback interface in ${each.key}"
}
