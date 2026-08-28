# NSI Traffic Inspection Between Two Web VPCs

## Overview
This configuration demonstrates Network Security Intelligence (NSI) traffic inspection between two peered VPC networks using FortiGate firewalls deployed in a centralized inspection VPC.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Inspection VPC                           │
│                     (10.50.160.0/24)                           │
│                                                                 │
│  ┌──────────────────────────────────────────────────────┐     │
│  │  FortiGate MIG (3 instances across 3 zones)         │     │
│  │  - NSI Intercept Deployment Group                   │     │
│  │  - Health checks on port 8080                       │     │
│  │  - GENEVE encapsulation on port 6081                │     │
│  └──────────────────────────────────────────────────────┘     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                           │                    │
                           │ NSI Inspection     │
                           │                    │
          ┌────────────────┴────────┬──────────┴─────────────┐
          │                         │                         │
  ┌───────▼─────────┐      ┌────────▼────────┐       ┌──────▼──────┐
  │   Web VPC       │◄─────┤  VPC Peering    ├──────►│  Web2 VPC   │
  │  (10.12.0.0/24) │      └─────────────────┘       │(10.13.0.0/24)│
  │                 │                                 │              │
  │ - 3 Debian VMs  │                                 │- 3 Debian VMs │
  │   (zones a,b,c) │                                 │  (zones a,b,c)│
  └─────────────────┘                                 └──────────────┘
```

## VPC Networks

### 1. Inspection VPC (`fgt-nsi-fgt-nsi-ib-new`)
- **CIDR**: 10.50.160.0/24
- **Purpose**: Hosts FortiGate instances for traffic inspection
- **Resources**: 
  - FortiGate MIG with 3 instances
  - Internal load balancer
  - NSI Intercept Deployment Group
  - Cloud Router + Cloud NAT (`fgt-nsi-inspection-nat-router` / `fgt-nsi-inspection-nat-gw`)
    providing internet egress for FortiGate **port1**, which has no external IP.
    Required for FortiGuard, DNS, and licensing traffic.

### 2. Management VPC (`fgt-nsi-fgt-nsi-ib-new-mgmt`)
- **CIDR**: 10.50.180.0/24
- **Purpose**: FortiGate management and control plane
- **Access**: Admin interface on port 8443

### 3. Web VPC (`fgt-nsi-fgt-nsi-ib-new-web`)
- **CIDR**: 10.12.0.0/24
- **Purpose**: First workload VPC with web servers
- **Resources**:
  - 3 Debian 12 instances (Apache + iperf3)
  - HTTP/HTTPS/SSH access enabled

### 4. Web2 VPC (`fgt-nsi-fgt-nsi-ib-new-web2`)
- **CIDR**: 10.13.0.0/24
- **Purpose**: Second workload VPC for demonstrating NSI between VPCs
- **Resources**:
  - 3 Debian 12 instances (Apache + iperf3)
  - HTTP/HTTPS/SSH access enabled
- **Peering**: Bidirectional peering with Web VPC

## VPC Peering Configuration

### Peering Details
- **Web → Web2**: `fgt-nsi-web-to-web2-peering`
- **Web2 → Web**: `fgt-nsi-web2-to-web-peering`

### Features Enabled
- ✅ Export/Import custom routes
- ✅ Export/Import subnet routes with public IP
- ✅ Bidirectional traffic flow

## NSI Configuration Steps

### 1. Create NSI Intercept Deployment Group
```bash
gcloud beta network-security intercept-deployment-groups create newfgt-nsi-ftnt-dg \
  --location global \
  --project <project-id> \
  --network fgt-nsi-fgt-nsi-ib-new \
  --no-async
```

### 2. Create Intercept Deployments (one per zone)
```bash
# Zone A
gcloud beta network-security intercept-deployments create fgt-nsi-us-central1a \
  --location=us-central1-a \
  --project=<project-id> \
  --forwarding-rule=fgt-us-central1a \
  --intercept-deployment-group=projects/<project-id>/locations/global/interceptDeploymentGroups/newfgt-nsi-ftnt-dg \
  --forwarding-rule-location=us-central1 \
  --no-async

# Repeat for zones B and C
```

### 3. Create Intercept Endpoint Group
```bash
gcloud beta network-security intercept-endpoint-groups create newfgt-nsi-ftnt-epg \
  --intercept-deployment-group newfgt-nsi-ftnt-dg \
  --project <project-id> \
  --location global \
  --no-async
```

### 4. Associate Endpoint Group with Both Web VPCs
```bash
# Web VPC Association
gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc \
  --intercept-endpoint-group newfgt-nsi-ftnt-epg \
  --network fgt-nsi-fgt-nsi-ib-new-web \
  --project <project-id> \
  --location global \
  --no-async

# Web2 VPC Association
gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc-web2 \
  --intercept-endpoint-group newfgt-nsi-ftnt-epg \
  --network fgt-nsi-fgt-nsi-ib-new-web2 \
  --project <project-id> \
  --location global \
  --no-async
```

### 5. Create Security Profile and Profile Group
```bash
# Security Profile
gcloud beta network-security security-profiles custom-intercept create <project-id>-ftnt-sp1 \
  --intercept-endpoint-group newfgt-nsi-ftnt-epg \
  --billing-project <project-id> \
  --organization <org-id> \
  --location global

# Security Profile Group
gcloud beta network-security security-profile-groups create <project-id>-ftnt-spg1 \
  --custom-intercept-profile <project-id>-ftnt-sp1 \
  --billing-project <project-id> \
  --organization <org-id> \
  --location global
```

### 6. Create and Apply Firewall Policy
```bash
# Create Policy
gcloud compute network-firewall-policies create newfgt-nsi \
  --project <project-id> \
  --global

# Add Ingress Rule
gcloud beta compute network-firewall-policies rules create 10 \
  --action=APPLY_SECURITY_PROFILE_GROUP \
  --firewall-policy newfgt-nsi \
  --global-firewall-policy \
  --security-profile-group organizations/<org-id>/locations/global/securityProfileGroups/<project-id>-ftnt-spg1 \
  --layer4-configs all \
  --src-ip-ranges 0.0.0.0/0 \
  --dest-ip-ranges 0.0.0.0/0 \
  --direction INGRESS

# Add Egress Rule
gcloud beta compute network-firewall-policies rules create 11 \
  --action=APPLY_SECURITY_PROFILE_GROUP \
  --firewall-policy newfgt-nsi \
  --global-firewall-policy \
  --security-profile-group organizations/<org-id>/locations/global/securityProfileGroups/<project-id>-ftnt-spg1 \
  --layer4-configs all \
  --src-ip-ranges 0.0.0.0/0 \
  --dest-ip-ranges 0.0.0.0/0 \
  --direction EGRESS

# Associate with Web VPC
gcloud compute network-firewall-policies associations create \
  --name newfgt-nsi-policy-assoc \
  --global-firewall-policy \
  --firewall-policy newfgt-nsi \
  --network fgt-nsi-fgt-nsi-ib-new-web \
  --project <project-id>

# Associate with Web2 VPC
gcloud compute network-firewall-policies associations create \
  --name newfgt-nsi-policy-assoc-web2 \
  --global-firewall-policy \
  --firewall-policy newfgt-nsi \
  --network fgt-nsi-fgt-nsi-ib-new-web2 \
  --project <project-id>
```

## Testing NSI Traffic Inspection

### 1. Verify VPC Peering
```bash
# Check peering status
gcloud compute networks peerings list --network=fgt-nsi-fgt-nsi-ib-new-web

# Expected output: ACTIVE state for both peerings
```

### 2. Test Connectivity Between VPCs
```bash
# From a Web VPC VM, ping a Web2 VPC VM
gcloud compute ssh fgt-nsi-web-us-central1a --zone=us-central1-a
ping 10.13.0.x  # IP of a Web2 VPC server
curl http://10.13.0.x  # Apache test page on the Web2 VPC server

# From a Web2 VPC VM, ping a Web VPC VM
gcloud compute ssh fgt-nsi-web2-us-central1a --zone=us-central1-a
ping 10.12.0.x  # IP of a Web VPC server
curl http://10.12.0.x  # Apache test page on the Web VPC server
```

### 3. Verify Traffic Inspection on FortiGate
```bash
# Access FortiGate GUI
# Navigate to: Log & Report > Forward Traffic
# Filter for traffic between 10.12.0.0/24 and 10.13.0.0/24
# You should see GENEVE encapsulated traffic being inspected
```

### 4. Monitor NSI Metrics
```bash
# Check intercept deployment status
gcloud beta network-security intercept-deployments list --location=us-central1-a

# Check endpoint group associations
gcloud beta network-security intercept-endpoint-group-associations list --location=global

# View logs in Cloud Logging
gcloud logging read "resource.type=network_security_intercept" --limit=50
```

## Traffic Flow Explanation

1. **VM in Web VPC initiates connection to VM in Web2 VPC**
   - Packet leaves Web VPC (10.12.0.0/24)
   - VPC Peering routes packet toward Web2 VPC

2. **NSI Intercepts Traffic**
   - Network Firewall Policy detects traffic
   - Security Profile Group applies custom-intercept profile
   - Traffic is redirected to Intercept Endpoint Group

3. **FortiGate Inspection**
   - Traffic is GENEVE encapsulated (port 6081)
   - Sent to FortiGate instance in Inspection VPC
   - FortiGate performs deep packet inspection
   - Policy decisions are applied (allow/deny/modify)

4. **Traffic Returns to Path**
   - Inspected traffic is de-encapsulated
   - Forwarded to destination in Web2 VPC
   - Response traffic follows same inspection path

## Key Benefits of This Design

✅ **Centralized Security**: Single FortiGate deployment inspects traffic between multiple VPCs
✅ **Scalability**: FortiGate MIG automatically scales based on traffic load
✅ **High Availability**: 3 zones ensure redundancy
✅ **Transparent Inspection**: No changes required to workload VMs
✅ **Flexible Policies**: Apply different security profiles per VPC or traffic type
✅ **Cloud-Native**: Leverages GCP NSI for seamless integration

## Monitoring and Troubleshooting

### Check FortiGate Health
```bash
# View MIG status
gcloud compute instance-groups managed describe fgt-nsi-fortigate-mig --region=us-central1

# Check backend service health
gcloud compute backend-services get-health fgt-nsi-backend-service --region=us-central1
```

### Verify NSI Configuration
```bash
# List all intercept resources
gcloud beta network-security intercept-deployment-groups list
gcloud beta network-security intercept-deployments list --location=us-central1-a
gcloud beta network-security intercept-endpoint-groups list
gcloud beta network-security intercept-endpoint-group-associations list
```

### Common Issues

**Issue**: Traffic not being inspected
- ✓ Verify firewall policy is associated with both VPCs
- ✓ Check security profile group configuration
- ✓ Ensure FortiGate instances are healthy (check MIG status)
- ✓ Verify GENEVE port 6081 is open in inspection VPC

**Issue**: VPC Peering not working
- ✓ Verify both peerings are in ACTIVE state
- ✓ Check route propagation settings
- ✓ Ensure no overlapping CIDR ranges
- ✓ Verify firewall rules allow traffic

**Issue**: FortiGate not processing traffic
- ✓ Check FortiGate configuration for NSI settings
- ✓ Verify health check passes on port 8080
- ✓ Review FortiGate logs for errors
- ✓ Ensure proper licensing and configuration

## Additional Resources

- [GCP Network Security Intelligence Documentation](https://cloud.google.com/network-security/docs)
- [FortiGate NSI Integration Guide](https://docs.fortinet.com/document/fortigate-public-cloud/latest/gcp-administration-guide)
- [VPC Network Peering Documentation](https://cloud.google.com/vpc/docs/vpc-peering)

## Deployment Commands

```bash
# Initialize Terraform
terraform init

# Review planned changes
terraform plan

# Apply configuration
terraform apply

# After Terraform completes, run the NSI gcloud commands from the output
terraform output nsi_manual_commands

# Verify VPC peering
terraform output vpc_peering_info

# Get Web2 server information
terraform output web2_servers_info
```
