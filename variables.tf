# Required Variables
variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "organization_id" {
  description = "The GCP organization ID (required for NSI security profiles)"
  type        = string
}

variable "region" {
  description = "The GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "fgt-nsi"
}

# FortiGate Configuration Variables
variable "fortigate_license_type" {
  description = "FortiGate license type (payg or byol)"
  type        = string
  default     = "payg"
  validation {
    condition     = contains(["payg", "byol"], var.fortigate_license_type)
    error_message = "License type must be either 'payg' or 'byol'."
  }
}

variable "fortigate_machine_type" {
  description = "Machine type for FortiGate instances"
  type        = string
  default     = "c4-standard-4"
}

variable "fortigate_instance_count" {
  description = "Number of FortiGate instances in the MIG"
  type        = number
  default     = 3
}

variable "zones" {
  description = "List of zones for distributing FortiGate instances"
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-c"]
}

# FortiGate Admin Configuration
variable "admin_port" {
  description = "Admin port for FortiGate management"
  type        = number
  default     = 8443
}

variable "admin_password" {
  description = "Admin password for FortiGate management"
  type        = string
  sensitive   = true
  default     = "Fortinet123!"
}

variable "fmg" {
  type        = string
  description = "Will FortiManager be used for this deployment? (true/false)"
  default     = "false"
}

variable "fmg_ip" {
  description = "IP address of the FortiManager (if applicable)"
  type        = string
  default     = ""
}

# Test workload toggle
variable "deploy_web_servers" {
  description = "Deploy the demo web/web2 VPCs, subnets, firewall rules, VPC peering and web server VMs. Set to false to deploy only the FortiGate NSI producer side and associate your own workload VPCs instead."
  type        = bool
  default     = true
}

# Network Configuration Variables
variable "inspection_subnet_cidr" {
  description = "CIDR range for inspection subnet"
  type        = string
  default     = "10.50.160.0/24"
}

variable "management_subnet_cidr" {
  description = "CIDR range for management subnet"
  type        = string
  default     = "10.50.180.0/24"
}

variable "web_subnet_cidr" {
  description = "CIDR range for web subnet"
  type        = string
  default     = "10.12.0.0/24"
}

variable "web2_subnet_cidr" {
  description = "CIDR range for second web subnet"
  type        = string
  default     = "10.13.0.0/24"
}

# Cloud NAT Configuration (inspection VPC / FortiGate port1 egress)
# Both default to prefix-derived names. Override them to match resources that
# already exist so they can be adopted with 'terraform import' instead of
# being recreated.
variable "nat_router_name" {
  description = "Name of the Cloud Router for the inspection VPC NAT. Defaults to <prefix>-inspection-nat-router."
  type        = string
  default     = null
}

variable "nat_gateway_name" {
  description = "Name of the Cloud NAT gateway on the inspection VPC. Defaults to <prefix>-inspection-nat-gw."
  type        = string
  default     = null
}

# Load Balancer Configuration
variable "health_check_port" {
  description = "Port for health check"
  type        = number
  default     = 8080
}

variable "geneve_port" {
  description = "Port for Geneve traffic"
  type        = number
  default     = 6081
}

# Optional Variables
variable "enable_private_google_access" {
  description = "Enable private Google access on subnets"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "instance_configs" {
  description = "Per-instance configuration for FortiGate instances, keyed by zone"
  type = map(object({
    custom_metadata = optional(map(string), {})
    flx_tok         = optional(string)
    admin_port      = optional(number)
    admin_password  = optional(string)
    fmg_ip          = optional(string)
    fmg             = optional(string)
  }))
  default = {}
}