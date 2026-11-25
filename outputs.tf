# Network Outputs
output "vpc_networks" {
  description = "Created VPC networks"
  value = {
    inspection_vpc = {
      id   = google_compute_network.vpc_networks["inspection"].id
      name = google_compute_network.vpc_networks["inspection"].name
    }
    management_vpc = {
      id   = google_compute_network.vpc_networks["management"].id
      name = google_compute_network.vpc_networks["management"].name
    }
    # null when deploy_web_servers = false.
    web_vpc = var.deploy_web_servers ? {
      id   = google_compute_network.vpc_networks["web"].id
      name = google_compute_network.vpc_networks["web"].name
    } : null
    web2_vpc = var.deploy_web_servers ? {
      id   = google_compute_network.vpc_networks["web2"].id
      name = google_compute_network.vpc_networks["web2"].name
    } : null
  }
}

output "ncc_hub" {
  description = "Full mesh NCC hub, or null when no workload VPCs are configured"
  value = try({
    id   = google_network_connectivity_hub.web_mesh[0].id
    name = google_network_connectivity_hub.web_mesh[0].name
  }, null)
}

output "ncc_spokes" {
  description = "NCC VPC spokes connecting the workload networks"
  value = {
    for key, spoke in google_network_connectivity_spoke.workload_vpcs :
    key => {
      id      = spoke.id
      name    = spoke.name
      network = local.ncc_spoke_networks[key]
    }
  }
}

output "nsi_resources" {
  description = "Terraform-managed NSI resources and workload VPC associations"
  value = {
    deployment_group = google_network_security_intercept_deployment_group.fortigate.id
    deployments      = { for zone, deployment in google_network_security_intercept_deployment.fortigate : zone => deployment.id }
    endpoint_group   = google_network_security_intercept_endpoint_group.fortigate.id
    security_profile = google_network_security_security_profile.fortigate.id
    profile_group    = google_network_security_security_profile_group.fortigate.id
    firewall_policy  = google_compute_network_firewall_policy.fortigate.id
    consumers = {
      for name, association in google_network_security_intercept_endpoint_group_association.consumers :
      name => {
        endpoint_association = association.id
        policy_association   = google_compute_network_firewall_policy_association.consumers[name].id
      }
    }
  }
}

output "subnets" {
  description = "Created subnets"
  value = {
    inspection_subnet = {
      id         = google_compute_subnetwork.subnets["inspection_central"].id
      name       = google_compute_subnetwork.subnets["inspection_central"].name
      cidr_range = google_compute_subnetwork.subnets["inspection_central"].ip_cidr_range
    }
    management_subnet = {
      id         = google_compute_subnetwork.subnets["management_central"].id
      name       = google_compute_subnetwork.subnets["management_central"].name
      cidr_range = google_compute_subnetwork.subnets["management_central"].ip_cidr_range
    }
    web_subnet = var.deploy_web_servers ? {
      id         = google_compute_subnetwork.subnets["web_central"].id
      name       = google_compute_subnetwork.subnets["web_central"].name
      cidr_range = google_compute_subnetwork.subnets["web_central"].ip_cidr_range
    } : null
    web2_subnet = var.deploy_web_servers ? {
      id         = google_compute_subnetwork.subnets["web2_central"].id
      name       = google_compute_subnetwork.subnets["web2_central"].name
      cidr_range = google_compute_subnetwork.subnets["web2_central"].ip_cidr_range
    } : null
  }
}

# FortiGate Outputs
output "fortigate_instances" {
  description = "Individual FortiGate instance details"
  value = {
    for k, v in google_compute_instance.fortigate_instances : k => {
      id                = v.id
      name              = v.name
      zone              = v.zone
      inspection_ip     = v.network_interface[0].network_ip
      management_ip     = v.network_interface[1].network_ip
      management_ext_ip = v.network_interface[1].access_config[0].nat_ip
    }
  }
}

output "fortigate_instance_groups" {
  description = "Unmanaged instance groups for FortiGate NSI"
  value = {
    for k, v in google_compute_instance_group.fortigate_uig : k => {
      id   = v.id
      name = v.name
      zone = v.zone
    }
  }
}

# Load Balancer Outputs
output "backend_service" {
  description = "Backend service details"
  value = {
    id   = google_compute_region_backend_service.fortigate_backend_service.id
    name = google_compute_region_backend_service.fortigate_backend_service.name
  }
}

output "health_check" {
  description = "Health check details"
  value = {
    id   = google_compute_health_check.fortigate_health_check.id
    name = google_compute_health_check.fortigate_health_check.name
  }
}

output "forwarding_rules" {
  description = "Internal load balancer forwarding rules"
  value = {
    for k, v in google_compute_forwarding_rule.fortigate_forwarding_rules : k => {
      id         = v.id
      name       = v.name
      ip_address = v.ip_address
    }
  }
}

output "ilb_ip" {
  description = "Internal load balancer loopback IP address"
  value = {
    id      = google_compute_address.ilb_ip.id
    name    = google_compute_address.ilb_ip.name
    address = google_compute_address.ilb_ip.address
  }
}

output "ilb_frontend_ips" {
  description = "Internal load balancer frontend IP addresses"
  value = {
    for k, v in google_compute_address.ilb_frontend_ips : k => {
      id      = v.id
      name    = v.name
      address = v.address
    }
  }
}

# Cloud NAT Output
output "inspection_nat" {
  description = "Cloud Router and NAT gateway providing internet egress for FortiGate port1"
  value = {
    router_name = google_compute_router.inspection_nat_router.name
    router_id   = google_compute_router.inspection_nat_router.id
    nat_name    = google_compute_router_nat.inspection_nat.name
    network     = google_compute_network.vpc_networks["inspection"].name
    region      = var.region
    # NAT addresses are Google-allocated (AUTO_ONLY), so they are not known to
    # Terraform. Query them once the gateway is up:
    nat_ips_command = "gcloud compute routers get-nat-mapping-info ${google_compute_router.inspection_nat_router.name} --region ${var.region} --project ${var.project_id}"
  }
}

# Firewall Rules Output
output "firewall_rules" {
  description = "Created firewall rules"
  value = {
    for k, v in google_compute_firewall.firewall_rules : k => {
      id   = v.id
      name = v.name
    }
  }
}

output "project_summary" {
  description = "Summary of the deployed resources"
  value = {
    project_id             = var.project_id
    region                 = var.region
    fortigate_machine_type = var.fortigate_machine_type
    instance_count         = var.fortigate_instance_count
    zones                  = var.zones
    admin_port             = var.admin_port
    web_servers_deployed   = var.deploy_web_servers
  }
}

# Web servers output
output "web_servers" {
  description = "Web server instances for testing"
  value = {
    for k, v in google_compute_instance.web_servers : k => {
      id          = v.id
      name        = v.name
      internal_ip = v.network_interface[0].network_ip
      external_ip = length(v.network_interface[0].access_config) > 0 ? v.network_interface[0].access_config[0].nat_ip : null
    }
  }
}

# Web2 servers output
output "web2_servers" {
  description = "Web2 server instances for testing NCC connectivity and NSI"
  value = {
    for k, v in google_compute_instance.web2_servers : k => {
      id          = v.id
      name        = v.name
      internal_ip = v.network_interface[0].network_ip
      external_ip = length(v.network_interface[0].access_config) > 0 ? v.network_interface[0].access_config[0].nat_ip : null
    }
  }
}
