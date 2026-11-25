# Two VPC NSI demo

With `deploy_web_servers = true`, Terraform creates web and web2 workload VPCs and their test VMs. It attaches both VPCs to the NSI endpoint group and global network firewall policy, and adds both as spokes to an NCC **MESH** hub. The inspection and management VPCs stay outside that hub.

Configure `terraform.tfvars` from `terraform.tfvars.example`, then run:

```bash
terraform init
terraform plan
terraform apply
```

Check `terraform output nsi_resources` for the NSI attachments and `terraform output` for test VM and FortiGate details. To inspect or route additional existing VPCs, set `nsi_consumer_vpc_names` or `ncc_existing_vpc_names` respectively and run `terraform plan` and `terraform apply` again.

The default NSI policy rules match all IPv4 ingress and egress traffic. Review them before using this configuration with production VPCs. See [SETUP_GUIDE.md](SETUP_GUIDE.md) for prerequisites, migration, and removal.
