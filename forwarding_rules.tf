# Forwarding Rules for Internal Load Balancer
resource "google_compute_forwarding_rule" "fortigate_forwarding_rules" {
  for_each = { for idx, zone in var.zones : zone => {
    name = "fgt-${replace(zone, "-", "")}"
    zone = zone
  } }

  name                  = each.value.name
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  ip_protocol           = "UDP"
  ports                 = ["6081"]
  network_tier          = "PREMIUM"

  # Use the reserved address that the FortiGate loopback (port1-ilb-probe) is
  # configured with. Without this GCP assigns an ephemeral IP, and the FortiGates
  # answer health probes on addresses the load balancer never uses.
  ip_address = google_compute_address.ilb_frontend_ips[each.key].address

  # Reference the backend service
  backend_service = google_compute_region_backend_service.fortigate_backend_service.id

  # Use the inspection subnet
  subnetwork = google_compute_subnetwork.subnets["inspection_central"].id

  # Note: allow_global_access must be false (default) for NSI intercept deployments
  # allow_global_access = false

  depends_on = [google_compute_region_backend_service.fortigate_backend_service]
}