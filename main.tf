terraform {
  required_version = ">= 1.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Random string for unique naming
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

# Data source for FortiGate image
data "google_compute_image" "fortigate_image" {
  family  = "fortigate-76-${var.fortigate_license_type}"
  project = "fortigcp-project-001"
}

locals {
  # Common naming prefix
  prefix = var.prefix

  # Network configurations based on gcloud commands
  vpc_networks = {
    # Data/Traffic inspection VPC
    inspection = {
      name                    = "${local.prefix}-fgt-nsi-ib-new"
      description             = "NIS data or traffic VPC network with regional subnets"
      auto_create_subnetworks = false
      mtu                     = 1768
    }

    # Management VPC  
    management = {
      name                    = "${local.prefix}-fgt-nsi-ib-new-mgmt"
      description             = "FortiGate management VPC network with regional subnets"
      auto_create_subnetworks = false
    }

    # Web VPC
    web = {
      name                    = "${local.prefix}-fgt-nsi-ib-new-web"
      description             = "Public Web VPC network with regional subnets"
      auto_create_subnetworks = false
    }

    # Second Web VPC for NSI demonstration
    web2 = {
      name                    = "${local.prefix}-fgt-nsi-ib-new-web2"
      description             = "Second Web VPC network for NSI traffic inspection demo"
      auto_create_subnetworks = false
    }
  }

  # Subnet configurations
  subnets = {
    # Inspection subnet
    inspection_central = {
      name                            = "${local.prefix}-fgt-nsi-central"
      vpc_key                         = "inspection"
      cidr_range                      = "10.50.160.0/24"
      region                          = var.region
      description                     = "Data or Traffic inspection Subnet in us-central1"
      enable_private_ip_google_access = true
    }

    # Management subnet
    management_central = {
      name                            = "${local.prefix}-fgt-nsi1-mgmt-central"
      vpc_key                         = "management"
      cidr_range                      = "10.50.180.0/24"
      region                          = var.region
      description                     = "FortiGate management Subnet in us-central1"
      enable_private_ip_google_access = true
    }

    # Web subnet
    web_central = {
      name                            = "${local.prefix}-fgt-nsi-web1-central"
      vpc_key                         = "web"
      cidr_range                      = "10.12.0.0/24"
      region                          = var.region
      description                     = "Public Web Subnet in us-central1"
      enable_private_ip_google_access = true
    }

    # Second Web subnet
    web2_central = {
      name                            = "${local.prefix}-fgt-nsi-web2-central"
      vpc_key                         = "web2"
      cidr_range                      = "10.13.0.0/24"
      region                          = var.region
      description                     = "Second Web Subnet in us-central1"
      enable_private_ip_google_access = true
    }
  }

  # Firewall rules
  firewall_rules = {
    # Inspection VPC - allow all ingress
    inspection_allow_ingress = {
      name          = "${local.prefix}-fgt-nsi-allow-all-in"
      network       = "inspection"
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["0-65535"]
        },
        {
          protocol = "udp"
          ports    = ["0-65535"]
        },
        {
          protocol = "icmp"
        }
      ]
      description = "Allow all incoming data traffic for inspection"
    }

    # Inspection VPC - allow all egress
    inspection_allow_egress = {
      name               = "${local.prefix}-fgt-nsi-allow-all-egr"
      network            = "inspection"
      direction          = "EGRESS"
      priority           = 1000
      destination_ranges = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["0-65535"]
        },
        {
          protocol = "udp"
          ports    = ["0-65535"]
        },
        {
          protocol = "icmp"
        }
      ]
      description = "Allow all outgoing traffic for inspection"
    }

    # Management VPC - allow all ingress
    management_allow_ingress = {
      name          = "${local.prefix}-fgt-nsi-allow-all-ing1"
      network       = "management"
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["0-65535"]
        },
        {
          protocol = "udp"
          ports    = ["0-65535"]
        },
        {
          protocol = "icmp"
        }
      ]
      description = "FortiGate management allow all incoming traffic"
    }

    # Management VPC - allow all egress
    management_allow_egress = {
      name               = "${local.prefix}-fgt-nsi-allow-all-egr1"
      network            = "management"
      direction          = "EGRESS"
      priority           = 1000
      destination_ranges = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["0-65535"]
        },
        {
          protocol = "udp"
          ports    = ["0-65535"]
        },
        {
          protocol = "icmp"
        }
      ]
      description = "FortiGate management allow all outgoing traffic"
    }

    # Health check firewall rule for inspection network
    inspection_health_check = {
      name          = "${local.prefix}-fgt-allow-health-check"
      network       = "inspection"
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
      target_tags   = ["allow-health-check"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["8080"]
        }
      ]
      description = "Allow Google Cloud health checks"
    }

    # Health check firewall rule for management network
    management_health_check = {
      name          = "${local.prefix}-fgt-allow-health-check-mgmt"
      network       = "management"
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
      target_tags   = ["allow-health-check"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["8080"]
        }
      ]
      description = "Allow Google Cloud health checks on management network"
    }

    # Web2 VPC - allow all ingress for demonstration
    web2_allow_ingress = {
      name          = "${local.prefix}-fgt-nsi-web2-allow-all-in"
      network       = "web2"
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["0-65535"]
        },
        {
          protocol = "udp"
          ports    = ["0-65535"]
        },
        {
          protocol = "icmp"
        }
      ]
      description = "Allow all incoming traffic for Web2 VPC"
    }

    # Web2 VPC - allow all egress
    web2_allow_egress = {
      name               = "${local.prefix}-fgt-nsi-web2-allow-all-egr"
      network            = "web2"
      direction          = "EGRESS"
      priority           = 1000
      destination_ranges = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["0-65535"]
        },
        {
          protocol = "udp"
          ports    = ["0-65535"]
        },
        {
          protocol = "icmp"
        }
      ]
      description = "Allow all outgoing traffic for Web2 VPC"
    }
  }
}