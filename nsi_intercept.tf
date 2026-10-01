# NSI Intercept resources require google-beta provider
# Note: These resources are currently in beta and may need to be created via gcloud CLI
# The following resources serve as placeholders and documentation

# For now, these NSI resources should be created using the gcloud commands:
# Reference the gcp-nsi.txt file for the exact gcloud commands needed

# Placeholder for NSI Intercept Deployment Group
# gcloud beta network-security intercept-deployment-groups create newfgt-nsi-ftnt-dg \
#   --location global \
#   --project <project-id> \
#   --network fgt-nsi-fgt-nsi-ib-new \
#   --no-async

# Placeholder for NSI Intercept Deployments 
# gcloud beta network-security intercept-deployments create fgt-nsi-us-central1a \
#   --location=us-central1-a \
#   --project=<project-id> \
#   --forwarding-rule=fgt-us-central1a \
#   --intercept-deployment-group=projects/<project-id>/locations/global/interceptDeploymentGroups/newfgt-nsi-ftnt-dg \
#   --forwarding-rule-location=us-central1 \
#   --no-async

# Similar commands needed for us-central1b and us-central1c

# Placeholder for NSI Intercept Endpoint Group
# gcloud beta network-security intercept-endpoint-groups create newfgt-nsi-ftnt-epg \
#   --intercept-deployment-group newfgt-nsi-ftnt-dg \
#   --project <project-id> \
#   --location global \
#   --no-async

# Placeholder for NSI Intercept Endpoint Group Association  
# gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc \
#   --intercept-endpoint-group newfgt-nsi-ftnt-epg \
#   --network fgt-nsi-fgt-nsi-ib-new-web \
#   --project <project-id> \
#   --location global \
#   --no-async

locals {
  # Security profiles and profile groups are ORGANIZATION-scoped, so their names
  # share a single namespace with every other project in the org. Derive them from
  # project_id so parallel deployments cannot collide or silently reuse each
  # other's profile group. Must match NSI_NAME_PREFIX in setup-nsi.sh, which
  # defaults to PROJECT_ID.
  nsi_name_prefix            = var.project_id
  security_profile           = "${local.nsi_name_prefix}-ftnt-sp1"
  security_profile_group     = "${local.nsi_name_prefix}-ftnt-spg1"
  security_profile_group_uri = "organizations/${var.organization_id}/locations/global/securityProfileGroups/${local.security_profile_group}"
}

# Output values for reference after manual creation
output "nsi_manual_commands" {
  description = "Manual gcloud commands needed to complete NSI setup"
  value = {
    deployment_group = "gcloud beta network-security intercept-deployment-groups create newfgt-nsi-ftnt-dg --location global --project ${var.project_id} --network ${google_compute_network.vpc_networks["inspection"].name} --no-async"

    intercept_deployments = {
      for zone in var.zones : replace(zone, "-", "_") => "gcloud beta network-security intercept-deployments create fgt-nsi-${replace(zone, "-", "")} --location=${zone} --project=${var.project_id} --forwarding-rule=${google_compute_forwarding_rule.fortigate_forwarding_rules[zone].name} --intercept-deployment-group=projects/${var.project_id}/locations/global/interceptDeploymentGroups/newfgt-nsi-ftnt-dg --forwarding-rule-location=${var.region} --no-async"
    }

    endpoint_group = "gcloud beta network-security intercept-endpoint-groups create newfgt-nsi-ftnt-epg --intercept-deployment-group newfgt-nsi-ftnt-dg --project ${var.project_id} --location global --no-async"

    endpoint_group_association_web = "gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc --intercept-endpoint-group newfgt-nsi-ftnt-epg --network ${local.workload_vpc_name} --project ${var.project_id} --location global --no-async"

    # The second association only exists for the demo web2 VPC.
    endpoint_group_association_web2 = var.deploy_web_servers ? "gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc-web2 --intercept-endpoint-group newfgt-nsi-ftnt-epg --network ${google_compute_network.vpc_networks["web2"].name} --project ${var.project_id} --location global --no-async" : null

    security_profile = "gcloud beta network-security security-profiles custom-intercept create ${local.security_profile} --intercept-endpoint-group newfgt-nsi-ftnt-epg --billing-project ${var.project_id} --organization ${var.organization_id} --location global"

    security_profile_group = "gcloud beta network-security security-profile-groups create ${local.security_profile_group} --custom-intercept-profile ${local.security_profile} --billing-project ${var.project_id} --organization ${var.organization_id} --location global"

    firewall_policy = "gcloud compute network-firewall-policies create newfgt-nsi --project ${var.project_id} --global"

    firewall_policy_rules = {
      ingress = "gcloud beta compute network-firewall-policies rules create 10 --action=APPLY_SECURITY_PROFILE_GROUP --firewall-policy newfgt-nsi --global-firewall-policy --security-profile-group ${local.security_profile_group_uri} --layer4-configs all --src-ip-ranges 0.0.0.0/0 --dest-ip-ranges 0.0.0.0/0 --direction INGRESS"
      egress  = "gcloud beta compute network-firewall-policies rules create 11 --action=APPLY_SECURITY_PROFILE_GROUP --firewall-policy newfgt-nsi --global-firewall-policy --security-profile-group ${local.security_profile_group_uri} --layer4-configs all --src-ip-ranges 0.0.0.0/0 --dest-ip-ranges 0.0.0.0/0 --direction EGRESS"
    }

    firewall_policy_association_web = "gcloud compute network-firewall-policies associations create --name newfgt-nsi-policy-assoc --global-firewall-policy --firewall-policy newfgt-nsi --network ${local.workload_vpc_name} --project ${var.project_id}"

    firewall_policy_association_web2 = var.deploy_web_servers ? "gcloud compute network-firewall-policies associations create --name newfgt-nsi-policy-assoc-web2 --global-firewall-policy --firewall-policy newfgt-nsi --network ${google_compute_network.vpc_networks["web2"].name} --project ${var.project_id}" : null
  }
}

# Additional output for VPC Peering verification (null without the demo workload)
output "vpc_peering_info" {
  description = "VPC Peering configuration for NSI demonstration"
  value = var.deploy_web_servers ? {
    web_to_web2_peering = google_compute_network_peering.web_to_web2[0].name
    web2_to_web_peering = google_compute_network_peering.web2_to_web[0].name
    web_network         = google_compute_network.vpc_networks["web"].name
    web2_network        = google_compute_network.vpc_networks["web2"].name
    web_subnet_cidr     = google_compute_subnetwork.subnets["web_central"].ip_cidr_range
    web2_subnet_cidr    = google_compute_subnetwork.subnets["web2_central"].ip_cidr_range
    peering_status_info = "Use 'gcloud compute networks peerings list --network=${google_compute_network.vpc_networks["web"].name}' to verify peering status"
  } : null
}

# Output for Web2 server information (null without the demo workload)
output "web2_servers_info" {
  description = "Information about Web2 VPC servers for testing"
  value = var.deploy_web_servers ? {
    web2_server_names = [for k, v in google_compute_instance.web2_servers : v.name]
    web2_server_ips   = [for k, v in google_compute_instance.web2_servers : v.network_interface[0].network_ip]
    web2_subnet       = google_compute_subnetwork.subnets["web2_central"].name
    web2_vpc          = google_compute_network.vpc_networks["web2"].name
    test_command      = "From Web VPC servers, ping Web2 VPC servers to test NSI inspection"
  } : null
}