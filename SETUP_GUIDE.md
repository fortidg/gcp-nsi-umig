# NSI Setup Guide - Two VPC Configuration

## Quick Start

This guide covers deploying FortiGate NSI with two peered Web VPCs for traffic inspection demonstration.

## Prerequisites

1. **GCP Project** with billing enabled
2. **Organization ID** (required for NSI security profiles)
3. **Required APIs** enabled (done automatically by `apis.tf`):
   - Compute Engine API
   - Network Security API
   - Cloud Resource Manager API

4. **Required Tools**:
   - Terraform >= 1.0.0
   - gcloud CLI (authenticated and configured)
   - jq (for parsing JSON outputs)

## Architecture Overview

```
Inspection VPC (10.50.160.0/24)
    └── FortiGate Instances (3 instances in unmanaged groups)
         │
         ├─ NSI Inspection ─┐
         │                  │
    Web VPC ◄──Peering──► Web2 VPC
 (10.12.0.0/24)        (10.13.0.0/24)
    3 Debian VMs         3 Debian VMs
```

**Note:** This deployment uses **Unmanaged Instance Groups** for more control over individual FortiGate instances. See [UNMANAGED_INSTANCE_GROUP.md](UNMANAGED_INSTANCE_GROUP.md) for details.

## Step-by-Step Deployment

### Step 1: Set Environment Variables

```bash
export PROJECT_ID="your-project-id"
export ORGANIZATION_ID="your-org-id"
export TF_VAR_project_id="$PROJECT_ID"
export TF_VAR_organization_id="$ORGANIZATION_ID"
```

### Step 2: Initialize Terraform

```bash
# Initialize Terraform
terraform init

# Optional: Create a terraform.tfvars file
cat > terraform.tfvars <<EOF
project_id      = "$PROJECT_ID"
organization_id = "$ORGANIZATION_ID"
region          = "us-central1"
prefix          = "fgt-nsi"
EOF
```

### Step 3: Review and Deploy Infrastructure

```bash
# Review the planned changes
terraform plan

# Deploy the infrastructure
terraform apply
```

**What gets created:**
- ✅ 4 VPC networks (Inspection, Management, Web, Web2)
- ✅ 4 Subnets (one per VPC)
- ✅ VPC Peering between Web and Web2
- ✅ 3 FortiGate instances (one per zone)
- ✅ 3 Unmanaged Instance Groups (one per zone, containing one FortiGate each)
- ✅ Internal Load Balancer with 3 forwarding rules
- ✅ 6 Debian 12 VMs with Apache + iperf3 (3 in Web VPC, 3 in Web2 VPC)
- ✅ Firewall rules for all VPCs
- ✅ Health checks

**Without the demo workload:** set `deploy_web_servers = false` in `terraform.tfvars` to skip the Web/Web2 VPCs, their subnets and firewall rules, the VPC peering, and the web server VMs. Only the FortiGate NSI side is deployed. `setup-nsi.sh` then skips the web VPC associations in steps 4 and 9. Pass your own VPCs in `CONSUMER_NETWORKS` instead (see below).

### Step 4: Configure NSI (Automated Script)

```bash
# Make the script executable
chmod +x setup-nsi.sh

# Run the NSI setup script
./setup-nsi.sh
```

**Inspecting your own VPCs:** set `CONSUMER_NETWORKS` to a comma- or space-separated list of VPC names in `PROJECT_ID`. The script associates them in steps 4 and 9, alongside the web VPCs (if deployed):

```bash
CONSUMER_NETWORKS="prod-vpc,staging-vpc" ./setup-nsi.sh
```

- **Association names:** `newfgt-nsi-epga-<network>` and `newfgt-nsi-fpa-<network>`.
- **Checks before creation:** every network is checked before anything is created. A typo, or the inspection or management VPC, stops the run.
- **All traffic is steered:** every associated VPC's traffic (`0.0.0.0/0`, both directions) goes through the FortiGates.
- **One firewall policy per VPC:** a VPC that already has a global network firewall policy can't be associated. The script reports the failure and exits non-zero.

**What the script does:**
1. Creates NSI Intercept Deployment Group
2. Creates Intercept Deployments (3 zones)
3. Creates Intercept Endpoint Group
4. Associates Endpoint Group with **both Web and Web2 VPCs** and any `CONSUMER_NETWORKS`
5. Creates Security Profile
6. Creates Security Profile Group
7. Creates Firewall Policy
8. Creates Firewall Policy Rules (ingress/egress)
9. Associates Policy with **both Web and Web2 VPCs** and any `CONSUMER_NETWORKS`

**Expected output:**
```
[INFO] Using PROJECT_ID: your-project-id
[INFO] Using ORGANIZATION_ID: 123456789012
[INFO] Getting Terraform outputs...
[INFO] Inspection Network: fgt-nsi-fgt-nsi-ib-new
[INFO] Web Network: fgt-nsi-fgt-nsi-ib-new-web
[INFO] Web2 Network: fgt-nsi-fgt-nsi-ib-new-web2
[STEP] 1. Creating intercept deployment group...
[STEP] 2. Creating intercept deployments for each zone...
[STEP] 3. Creating intercept endpoint group...
[STEP] 4. Associating endpoint group with workload VPCs...
[STEP] 5. Creating security profile...
[STEP] 6. Creating security profile group...
[STEP] 7. Creating firewall policy...
[STEP] 8. Creating firewall policy rules...
[STEP] 9. Associating policy with workload VPCs...
[INFO] NSI setup completed successfully!
```

### Step 5: Verify Deployment

```bash
# Check VPC Peering Status
gcloud compute networks peerings list --network=fgt-nsi-fgt-nsi-ib-new-web

# Expected output: ACTIVE state for both peerings
NAME                              NETWORK                       PEER_PROJECT     PEER_NETWORK                  STATE
fgt-nsi-web-to-web2-peering      fgt-nsi-fgt-nsi-ib-new-web    your-project    fgt-nsi-fgt-nsi-ib-new-web2   ACTIVE

# Check NSI Resources
gcloud beta network-security intercept-deployment-groups list
gcloud beta network-security intercept-deployments list --location=us-central1-a
gcloud beta network-security intercept-endpoint-groups list
gcloud beta network-security intercept-endpoint-group-associations list

# Check FortiGate Instances
gcloud compute instances list --filter="name~'fgt-nsi-fgt-nsi-us-central1'"

# Check FortiGate Instance Groups
gcloud compute instance-groups unmanaged list --filter="name~'fgt-nsi-fgt-nsi-uig'"

# Get VM IPs for testing
terraform output web_servers
terraform output web2_servers
terraform output fortigate_instances
```

## Testing NSI Traffic Inspection

### Test 1: Verify VPC Connectivity

```bash
# Get VM IPs
WEB_VM_IP=$(terraform output -json web_servers | jq -r '."us-central1-a".internal_ip')
WEB2_VM_IP=$(terraform output -json web2_servers | jq -r '."us-central1-a".internal_ip')

echo "Web VPC VM: $WEB_VM_IP"
echo "Web2 VPC VM: $WEB2_VM_IP"
```

### Test 2: SSH to VMs and Test Connectivity

```bash
# Get external IPs for SSH access
terraform output web_servers
terraform output web2_servers

# SSH to a Web VPC VM, then reach the Web2 VPC VM
gcloud compute ssh fgt-nsi-web-us-central1a --zone=us-central1-a
ping <WEB2_VM_IP>
curl http://<WEB2_VM_IP>          # Apache test page
iperf3 -c <WEB2_VM_IP>            # Throughput through the inspection path

# SSH to a Web2 VPC VM, then reach the Web VPC VM
gcloud compute ssh fgt-nsi-web2-us-central1a --zone=us-central1-a
ping <WEB_VM_IP>
curl http://<WEB_VM_IP>
iperf3 -c <WEB_VM_IP>
```

**Note:** The startup script installs Apache and an `iperf3` server unit on every web VM.
If a test fails right after deployment, check `/var/log/startup-script.log` on the VM to
confirm the script finished.

### Test 3: View Traffic in FortiGate

```bash
# Get FortiGate management IPs
gcloud compute instances list --filter="name~'fortigate'" --format="table(name,networkInterfaces[1].accessConfigs[0].natIP)"

# Access FortiGate GUI: https://<EXTERNAL_IP>:8443
# Default credentials (unless changed):
# Username: admin
# Password: (check instance metadata or use what you set in variables)

# In FortiGate GUI:
# Navigate to: Log & Report > Forward Traffic
# Filter for:
#   - Source IP: 10.12.0.0/24
#   - Destination IP: 10.13.0.0/24
# You should see GENEVE encapsulated traffic
```

### Test 4: Monitor NSI Metrics

```bash
# Check Cloud Logging for NSI events
gcloud logging read "resource.type=network_security_intercept" \
    --limit=50 \
    --format=json

# Check backend health
gcloud compute backend-services get-health fgt-nsi-backend-service --region=us-central1
```

## Cleanup Process

### Step 1: Remove NSI Configuration (Automated)

```bash
# Make the cleanup script executable
chmod +x cleanup-nsi.sh

# Run the cleanup script (use the same CONSUMER_NETWORKS as setup, if any)
CONSUMER_NETWORKS="prod-vpc,staging-vpc" ./cleanup-nsi.sh
```

Before deleting anything, the script checks for associations on the `newfgt-nsi` policy or the endpoint group that it wouldn't remove, such as a network left out of `CONSUMER_NETWORKS` or one added by hand. If it finds any, it lists them and stops with nothing deleted.

**What the script does (in reverse order):**
1. Removes firewall policy associations from **both Web and Web2 VPCs** and every `CONSUMER_NETWORKS` VPC
2. Deletes firewall policy rules
3. Deletes firewall policy
4. Deletes security profile group
5. Deletes security profile
6. Deletes intercept endpoint group associations from **both VPCs** and every `CONSUMER_NETWORKS` VPC
7. Deletes intercept endpoint group
8. Deletes intercept deployments (3 zones)
9. Deletes intercept deployment group

**Expected output:**
```
[INFO] Using PROJECT_ID: your-project-id
[INFO] Using ORGANIZATION_ID: 123456789012
[INFO] Starting NSI cleanup script...
[STEP] 1. Removing firewall policy associations...
[INFO] Deleted: firewall policy association newfgt-nsi-policy-assoc-web2
[INFO] Deleted: firewall policy association newfgt-nsi-policy-assoc
[STEP] 2. Deleting firewall policy rules...
[STEP] 3. Deleting firewall policy...
[STEP] 4. Deleting security profile group...
[STEP] 5. Deleting security profile...
[STEP] 6. Deleting intercept endpoint group associations...
[STEP] 7. Deleting intercept endpoint group...
[STEP] 8. Deleting intercept deployments...
[STEP] 9. Deleting intercept deployment group...
[INFO] NSI cleanup completed successfully!
[INFO] You can now proceed with 'terraform destroy --auto-approve'
```

### Step 2: Destroy Terraform Resources

```bash
# Destroy all Terraform-managed resources
terraform destroy --auto-approve
```

## Troubleshooting

### Issue: setup-nsi.sh fails with "terraform output not found"

**Solution:**
```bash
# Ensure terraform apply completed successfully
terraform apply

# Verify outputs are available
terraform output vpc_networks
terraform output forwarding_rules
```

### Issue: VPC Peering not in ACTIVE state

**Solution:**
```bash
# Check peering status
gcloud compute networks peerings list --network=fgt-nsi-fgt-nsi-ib-new-web

# If stuck, delete and let Terraform recreate
terraform apply -replace=google_compute_network_peering.web_to_web2
terraform apply -replace=google_compute_network_peering.web2_to_web
```

### Issue: Intercept endpoint group association already exists

**Solution:**
The scripts handle this gracefully with warnings. If you need to recreate:
```bash
# Delete manually
gcloud beta network-security intercept-endpoint-group-associations delete new-fgt-nsi-ftnt-epg-assoc \
    --project=$PROJECT_ID --location=global --quiet
gcloud beta network-security intercept-endpoint-group-associations delete new-fgt-nsi-ftnt-epg-assoc-web2 \
    --project=$PROJECT_ID --location=global --quiet

# Re-run setup script
./setup-nsi.sh
```

### Issue: FortiGate instances unhealthy

**Solution:**
```bash
# Check MIG status
gcloud compute instance-groups managed describe fgt-nsi-fortigate-mig --region=us-central1

# Check health
gcloud compute backend-services get-health fgt-nsi-backend-service --region=us-central1

# View FortiGate logs
gcloud compute instances get-serial-port-output <instance-name> --zone=us-central1-a
```

### Issue: Traffic not being inspected

**Checklist:**
- ✓ Verify NSI resources exist: `gcloud beta network-security intercept-endpoint-group-associations list`
- ✓ Verify firewall policy associated with both VPCs: `gcloud compute network-firewall-policies associations list --firewall-policy=newfgt-nsi`
- ✓ Verify FortiGate health: Backend service should show healthy instances
- ✓ Check FortiGate configuration: NSI policies should be configured
- ✓ Verify VPC peering is ACTIVE

### Issue: cleanup-nsi.sh fails with dependency errors

**Solution:**
```bash
# The script includes wait times, but you may need to wait longer
# Delete associations first, wait, then delete groups

# Manual cleanup if needed:
gcloud compute network-firewall-policies associations delete newfgt-nsi-policy-assoc-web2 --firewall-policy=newfgt-nsi --global-firewall-policy --quiet
gcloud compute network-firewall-policies associations delete newfgt-nsi-policy-assoc --firewall-policy=newfgt-nsi --global-firewall-policy --quiet

# Wait 30 seconds
sleep 30

# Continue with the rest of cleanup
gcloud beta network-security intercept-endpoint-group-associations delete new-fgt-nsi-ftnt-epg-assoc-web2 --location=global --quiet
gcloud beta network-security intercept-endpoint-group-associations delete new-fgt-nsi-ftnt-epg-assoc --location=global --quiet
```

## Key Features of This Setup

✅ **Dual VPC Configuration**: Two Web VPCs with different CIDR ranges
✅ **VPC Peering**: Bidirectional peering between Web VPCs
✅ **Centralized Inspection**: Single FortiGate deployment inspects traffic between VPCs
✅ **High Availability**: 3 zones with automatic failover
✅ **Automated Scripts**: setup-nsi.sh and cleanup-nsi.sh handle NSI configuration
✅ **Comprehensive Outputs**: All necessary information available via terraform output

## Script Enhancements

Both `setup-nsi.sh` and `cleanup-nsi.sh` have been updated to support **two Web VPCs**:

### setup-nsi.sh Updates:
- Reads both `WEB_NETWORK` and `WEB2_NETWORK` from Terraform outputs
- Creates endpoint group associations for both VPCs
- Creates firewall policy associations for both VPCs

### cleanup-nsi.sh Updates:
- Removes firewall policy associations from both VPCs
- Removes endpoint group associations from both VPCs
- Maintains proper deletion order to avoid dependency errors

## Additional Resources

- [Main Documentation](NSI_TWO_VPC_DEMO.md) - Detailed architecture and testing guide
- [GCP NSI Documentation](https://cloud.google.com/network-security/docs)
- [FortiGate GCP Guide](https://docs.fortinet.com/document/fortigate-public-cloud/latest/gcp-administration-guide)
- [VPC Peering Best Practices](https://cloud.google.com/vpc/docs/vpc-peering)

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Terraform outputs: `terraform output`
3. Check GCP logs: `gcloud logging read`
4. Verify NSI configuration: `gcloud beta network-security intercept-endpoint-group-associations list`
