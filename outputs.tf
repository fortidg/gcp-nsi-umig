locals {
  # The NSI consumer-side commands need a workload VPC to attach to. That is the
  # demo web VPC when it is deployed; otherwise the user supplies their own.
  workload_vpc_name  = var.deploy_web_servers ? google_compute_network.vpc_networks["web"].name : "<your-workload-vpc>"
  workload_vpc_label = var.deploy_web_servers ? "web VPC" : "your workload VPC"
}

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
    # null when deploy_web_servers = false; setup-nsi.sh relies on that to skip
    # the web VPC associations.
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
  description = "Web2 server instances for testing VPC peering and NSI"
  value = {
    for k, v in google_compute_instance.web2_servers : k => {
      id          = v.id
      name        = v.name
      internal_ip = v.network_interface[0].network_ip
      external_ip = length(v.network_interface[0].access_config) > 0 ? v.network_interface[0].access_config[0].nat_ip : null
    }
  }
}

# NSI deployment instructions
output "nsi_deployment_instructions" {
  description = "Instructions and commands for completing NSI setup"
  value       = <<-EOT
    
    After Terraform deployment is complete, run the following gcloud commands to enable NSI:
    
    1. Create the intercept deployment group:
    gcloud beta network-security intercept-deployment-groups create newfgt-nsi-ftnt-dg \
      --location global \
      --project ${var.project_id} \
      --network ${google_compute_network.vpc_networks["inspection"].name} \
      --no-async
    
    2. Create intercept deployments for each zone:
    ${join("\n    \n    ", [for zone in var.zones : "gcloud beta network-security intercept-deployments create fgt-nsi-${replace(zone, "-", "")} \\\n      --location=${zone} \\\n      --project=${var.project_id} \\\n      --forwarding-rule=${google_compute_forwarding_rule.fortigate_forwarding_rules[zone].name} \\\n      --intercept-deployment-group=projects/${var.project_id}/locations/global/interceptDeploymentGroups/newfgt-nsi-ftnt-dg \\\n      --forwarding-rule-location=${var.region} \\\n      --no-async"])}
    
    3. Create intercept endpoint group:
    gcloud beta network-security intercept-endpoint-groups create newfgt-nsi-ftnt-epg \
      --intercept-deployment-group newfgt-nsi-ftnt-dg \
      --project ${var.project_id} \
      --location global \
      --no-async
    
    4. Associate endpoint group with ${local.workload_vpc_label}:
    gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc \
      --intercept-endpoint-group newfgt-nsi-ftnt-epg \
      --network ${local.workload_vpc_name} \
      --project ${var.project_id} \
      --location global \
      --no-async
    
    5. Create security profile:
    gcloud beta network-security security-profiles custom-intercept create ${local.security_profile} \
      --intercept-endpoint-group newfgt-nsi-ftnt-epg \
      --billing-project ${var.project_id} \
      --organization ${var.organization_id} \
      --location global
    
    6. Create security profile group:
    gcloud beta network-security security-profile-groups create ${local.security_profile_group} \
      --custom-intercept-profile ${local.security_profile} \
      --billing-project ${var.project_id} \
      --organization ${var.organization_id} \
      --location global
    
    7. Create firewall policy:
    gcloud compute network-firewall-policies create newfgt-nsi \
      --project ${var.project_id} \
      --global
    
    8. Create firewall policy rules:
    gcloud beta compute network-firewall-policies rules create 10 \
      --action=APPLY_SECURITY_PROFILE_GROUP \
      --firewall-policy newfgt-nsi \
      --global-firewall-policy \
      --security-profile-group ${local.security_profile_group_uri} \
      --layer4-configs all \
      --src-ip-ranges 0.0.0.0/0 \
      --dest-ip-ranges 0.0.0.0/0 \
      --direction INGRESS
    
    gcloud beta compute network-firewall-policies rules create 11 \
      --action=APPLY_SECURITY_PROFILE_GROUP \
      --firewall-policy newfgt-nsi \
      --global-firewall-policy \
      --security-profile-group ${local.security_profile_group_uri} \
      --layer4-configs all \
      --src-ip-ranges 0.0.0.0/0 \
      --dest-ip-ranges 0.0.0.0/0 \
      --direction EGRESS
    
    9. Associate policy with ${local.workload_vpc_label}:
    gcloud compute network-firewall-policies associations create \
      --name newfgt-nsi-policy-assoc \
      --global-firewall-policy \
      --firewall-policy newfgt-nsi \
      --network ${local.workload_vpc_name} \
      --project ${var.project_id}
    
    EOT
}