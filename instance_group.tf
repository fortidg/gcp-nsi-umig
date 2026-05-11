# Individual FortiGate Instances for Unmanaged Instance Group
resource "google_compute_instance" "fortigate_instances" {
  for_each = toset(var.zones)

  name         = "${local.prefix}-fgt-nsi-${each.key}"
  machine_type = var.fortigate_machine_type
  zone         = each.key

  # Boot disk configuration
  boot_disk {
    auto_delete = true
    device_name = "${local.prefix}-fgt-boot-${each.key}"
    initialize_params {
      image = data.google_compute_image.fortigate_image.self_link
      size  = 50
      type  = "hyperdisk-balanced"
    }
  }

  # Port 1 - Data/Inspection interface
  network_interface {
    network    = google_compute_network.vpc_networks["inspection"].id
    subnetwork = google_compute_subnetwork.subnets["inspection_central"].id
    stack_type = "IPV4_ONLY"
  }

  # Port 2 - Management interface
  network_interface {
    network    = google_compute_network.vpc_networks["management"].id
    subnetwork = google_compute_subnetwork.subnets["management_central"].id
    stack_type = "IPV4_ONLY"

    # Enable external IP for management access
    access_config {
      network_tier = "PREMIUM"
    }
  }

  # Service account for API access
  service_account {
    scopes = ["cloud-platform"]
  }

  # Instance metadata
  metadata = merge(
    {
      enable-oslogin = "TRUE"
      user-data = templatefile("${path.module}/templates/fortigate-config.tpl", {
        admin_port        = try(var.instance_configs[each.key].admin_port, null) != null ? var.instance_configs[each.key].admin_port : var.admin_port
        admin_pass        = try(var.instance_configs[each.key].admin_password, null) != null ? var.instance_configs[each.key].admin_password : var.admin_password
        fmg_ip            = try(var.instance_configs[each.key].fmg_ip, null) != null ? var.instance_configs[each.key].fmg_ip : var.fmg_ip
        fmg               = try(var.instance_configs[each.key].fmg, null) != null ? var.instance_configs[each.key].fmg : var.fmg
        flx_tok           = try(var.instance_configs[each.key].flx_tok, null) != null ? var.instance_configs[each.key].flx_tok : ""
        mgmt_gw           = google_compute_subnetwork.subnets["management_central"].gateway_address
        insp_gw           = google_compute_subnetwork.subnets["inspection_central"].gateway_address
        ilb_ip            = google_compute_address.ilb_ip.address
        health_check_port = var.health_check_port
        frontend_ips      = [for k, v in google_compute_address.ilb_frontend_ips : v.address]
      })
    },
    lookup(var.instance_configs, each.key, null) != null ? var.instance_configs[each.key].custom_metadata : {}
  )

  # Tags for firewall rules
  tags = ["fortigate-nsi", "allow-health-check"]

  # Enable IP forwarding for traffic inspection
  can_ip_forward = true

  lifecycle {
    create_before_destroy = true
  }
}

# Unmanaged Instance Group per zone for FortiGate NSI
resource "google_compute_instance_group" "fortigate_uig" {
  for_each = toset(var.zones)

  name        = "${local.prefix}-fgt-nsi-uig-${each.key}"
  description = "Unmanaged instance group for FortiGate NSI in ${each.key}"
  zone        = each.key

  # Add the FortiGate instance to the group
  instances = [
    google_compute_instance.fortigate_instances[each.key].id
  ]

  # Named port for GENEVE traffic
  named_port {
    name = "geneve"
    port = 6081
  }

  lifecycle {
    create_before_destroy = true
  }
}