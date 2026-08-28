# FortiGate NSI (Network Service Insertion) Terraform Configuration

**Experimental**
 
This Terraform configuration deploys a FortiGate Network Service Insertion (NSI) infrastructure on Google Cloud Platform, based on the gcloud configurations provided. The deployment creates the necessary VPC networks, subnets, FortiGate instances in a Managed Instance Group, load balancer components, and NSI-specific resources required for traffic inspection.


![architecture](architecture-diagram.mmd)

## Architecture Overview

This deployment creates:

### VPC Networks
- **Inspection VPC** (`fgt-nsi-ib-new`): Data/traffic inspection network (10.50.160.0/24)
- **Management VPC** (`fgt-nsi-ib-new-mgmt`): FortiGate management network (10.50.180.0/24)  
- **Web VPC** (`fgt-nsi-ib-new-web`): Public web network (10.12.0.0/24)

### FortiGate Infrastructure
- **Instance Template**: FortiGate VM template with dual network interfaces
- **Managed Instance Group**: Auto-scaling group with 3 FortiGate instances across multiple zones
- **Health Checks**: HTTP health checks for load balancer backend service
- **Load Balancer**: Internal UDP load balancer for Geneve traffic (port 6081)
- **Forwarding Rules**: Three zone-specific forwarding rules for NSI deployment

### NSI (Network Security Inspection) Components
- **Intercept Deployment Group**: Global deployment group for FortiGate NSI
- **Intercept Deployments**: Zone-specific intercept deployments linking forwarding rules
- **Intercept Endpoint Group**: Endpoint group for traffic interception
- **Intercept Endpoint Group Association**: Association with the web VPC for traffic inspection
- **Security Profiles**: Custom intercept security profile for traffic processing
- **Security Profile Group**: Group containing the custom intercept profile
- **Firewall Policy**: Network firewall policy with NSI rules for ingress/egress traffic
- **Firewall Policy Association**: Policy association with the web VPC

### Test Infrastructure  
- **Web Server VMs**: Debian 12 instances across three zones for testing NSI functionality, preloaded with Apache and iperf3

### Security
- **Firewall Rules**: Allow all ingress/egress traffic on all VPCs plus health check rules
- **Network Interfaces**: Dual-interface setup (inspection + management)
- **Service Account**: Cloud Platform scope for GCP API access

## Prerequisites

1. **GCP Project**: Active GCP project with billing enabled
2. **APIs Enabled**: 
   - Compute Engine API
   - Cloud Resource Manager API
3. **Permissions**: IAM permissions for creating compute resources
4. **Terraform**: Version >= 1.0.0

## Quick Start

### 1. Clone and Setup
```bash
git clone <your-repo-url>
cd gcp-nsi
```

### 2. Configure Variables
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your specific values:
```hcl
project_id      = "your-gcp-project-id"
organization_id = "your-gcp-organization-id"
region          = "us-central1"
prefix          = "fgt-nsi"
admin_password = "YourSecurePasswordHere!"
```

### 3. Initialize and Deploy
```bash
terraform init
terraform plan
terraform apply
```

### 4. Access FortiGates
After deployment, FortiGate instances will have public IP addresses for management access:
- URL: `https://<fortigate-ip>:8443`
- Username: `admin`
- Password: As specified in `admin_password` variable

## Configuration Variables

### Required Variables
- `project_id`: Your GCP project ID
- `region`: GCP region for deployment (default: us-central1)
- `admin_password`: FortiGate admin password

### Optional Variables
- `fortigate_machine_type`: VM machine type (default: c4-standard-4)
- `fortigate_instance_count`: Number of FortiGate instances (default: 3)
- `zones`: Availability zones for instance distribution
- `prefix`: Resource naming prefix (default: fgt-nsi)
- `admin_port`: FortiGate admin port (default: 8443)

### Network Customization
- `inspection_subnet_cidr`: Inspection subnet CIDR (default: 10.50.160.0/24)
- `management_subnet_cidr`: Management subnet CIDR (default: 10.50.180.0/24)
- `web_subnet_cidr`: Web subnet CIDR (default: 10.12.0.0/24)

## NSI Integration

After Terraform deployment, complete the NSI setup in GCP Console:

1. **Create NSI Deployment Group** in Network Security → Network Service Insertion
2. **Reference Forwarding Rules** created by this Terraform:
   - `fgt-us-central1a` (Zone us-central1-a)
   - `fgt-us-central1b` (Zone us-central1-b) 
   - `fgt-us-central1c1` (Zone us-central1-c)
3. **Configure Policy Rules** to route traffic through the NSI

## File Structure

```
gcp-nsi/
├── main.tf                 # Provider configuration and locals
├── variables.tf            # Input variables
├── outputs.tf              # Output values
├── networks.tf             # VPC networks and subnets
├── firewall.tf             # Firewall rules
├── instance_template.tf    # FortiGate instance template
├── instance_group.tf       # Managed instance group
├── health_check.tf         # Load balancer health checks
├── backend_service.tf      # Load balancer backend service
├── forwarding_rules.tf     # Internal load balancer forwarding rules
├── templates/
│   └── fortigate-config.tpl # FortiGate configuration template
├── terraform.tfvars.example # Example variables file
└── README.md               # This file
```

## Outputs

The configuration provides detailed outputs including:
- VPC and subnet details
- FortiGate instance group information
- Load balancer components
- Forwarding rule IP addresses
- NSI deployment instructions

## Production Considerations

### Security
- **Firewall Rules**: The default configuration allows all traffic. Customize firewall rules for production environments based on your security requirements.
- **Admin Password**: Use a strong password and consider using Google Secret Manager.
- **Network Access**: Restrict management network access to specific IP ranges.

### Monitoring
- Enable GCP monitoring and logging for FortiGate instances
- Set up alerting for health check failures
- Monitor traffic flows and inspection statistics

### High Availability
- Instances are distributed across multiple zones automatically
- Auto-healing is enabled with health check monitoring
- Consider backup and disaster recovery procedures

### Licensing
- This configuration uses BYOL FortiGate images from `fortigcp-project-001`
- Ensure you have valid FortiGate licenses for your instances
- Update the image source in `main.tf` if using different licensing model

## Troubleshooting

### Common Issues

**Instance Template Creation Fails**
- Verify FortiGate image access permissions
- Check machine type availability in your region

**Health Checks Failing**
- Ensure FortiGate probe response is configured correctly
- Verify port 8080 is accessible on FortiGate instances

**Load Balancer Issues**
- Check that Geneve traffic (UDP 6081) is properly configured
- Verify backend service health

### Support Resources
- [FortiGate on GCP Documentation](https://docs.fortinet.com/document/fortigate-public-cloud)
- [GCP Network Service Insertion](https://cloud.google.com/vpc/docs/network-service-insertion)
- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)

## Cleanup

To destroy all resources:
```bash
terraform destroy
```

**Warning**: This will permanently delete all created resources. Ensure you have backups of any important configurations or data.