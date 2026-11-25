# FortiGate NSI setup

Terraform creates and removes the FortiGate infrastructure, Network Service Insertion (NSI) resources, consumer VPC attachments, and Network Connectivity Center (NCC) full mesh. There are no setup or cleanup scripts.

## Prerequisites

- A Google Cloud project with billing and permission to create network security resources, firewall policies, and Compute Engine and NCC resources. Project-scoped profiles and groups require `roles/networksecurity.securityProfileAdmin` on the project; creating a profile also requires `networksecurity.interceptEndpointGroups.use` on the endpoint group. Organization scope instead requires an organization ID and the Security Profile Admin role on the organization.
- Terraform and Google Cloud credentials with access to the project. See `required_version` and provider versions in `main.tf`.
- FortiGate licensing information and a secure `admin_password`. The example variables file shows the required instance settings.
- Any VPC listed in `nsi_consumer_vpc_names` or `ncc_existing_vpc_names` must already exist in `project_id`.
- For local user Application Default Credentials, the account needs `serviceusage.services.use` on `project_id`. The provider sends that project as the quota project for Google API requests.

## Deploy

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and set `project_id`, region, zones, FortiGate settings, and `admin_password`. Set `organization_id` only if using organization-scoped profiles.
2. Decide which workload VPCs to inspect. The demo web and web2 VPCs are created and attached to NSI and NCC when `deploy_web_servers = true`. For existing VPCs, set `nsi_consumer_vpc_names`. Set `ncc_existing_vpc_names` if those VPCs should also exchange private subnet routes through the NCC hub.
3. Run:

```bash
terraform init
terraform plan
terraform apply
```

For a producer deployment without demo web servers:

```hcl
deploy_web_servers     = false
nsi_consumer_vpc_names = ["prod-vpc", "staging-vpc"]
ncc_existing_vpc_names = ["prod-vpc", "staging-vpc"]
```

The two VPC lists serve different purposes. `nsi_consumer_vpc_names` attaches the NSI endpoint group and global network firewall policy. `ncc_existing_vpc_names` connects VPCs through the NCC **MESH** hub. Use either list independently as needed. Do not list the inspection or management VPCs as NSI consumers.

The firewall policy's ingress and egress rules have priorities 10 and 11 and match all IPv4 traffic. Review the rules and [firewall policy evaluation order](https://docs.cloud.google.com/firewall/docs/firewall-policies-rule-eval-order) before attaching production VPCs. A workload VPC must be able to use the global network firewall policy; check existing policy associations first.

After apply, `terraform output nsi_resources` shows NSI resource IDs and attachments. `terraform output` also shows the FortiGate and load balancer details.

## Existing deployments

If the former shell setup created NSI resources in this project, import **every** matching deployment group, zonal deployment, endpoint group, endpoint group association, security profile and group, firewall policy, firewall rule, and policy association before applying. Those scripts created organization-scoped profiles, so set `nsi_security_profile_scope = "organization"` before importing them. Terraform otherwise tries to create a duplicate resource. Use the resource addresses in `nsi_intercept.tf`, the import ID format in the [Google provider resource documentation](https://registry.terraform.io/providers/hashicorp/google/latest/docs), and `terraform plan` to confirm adoption. Demo association names were preserved. The generated names for long custom VPC names may differ from those used by the former scripts; use the existing name in Terraform state or replace it deliberately.

If migrating a demo deployment from direct VPC peering to NCC, first remove the peerings from Terraform state/configuration with the targeted plan shown in [README.md](README.md#network-connectivity-center), then apply the NCC hub and spokes. Expect a brief routing gap.

## Remove

Review the proposed changes, then run:

```bash
terraform plan -destroy
terraform destroy
```

Terraform removes consumer associations before the shared NSI components. A security profile still used by another deployment cannot be deleted until that dependency is removed.
