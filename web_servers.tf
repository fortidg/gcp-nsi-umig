# Web Server VMs for testing NSI functionality
resource "google_compute_instance" "web_servers" {
  for_each = { for zone in var.zones : zone => "fgt-nsi-web-${replace(zone, "-", "")}" }

  name         = each.value
  machine_type = "e2-medium"
  zone         = each.key

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
    auto_delete = true
  }

  network_interface {
    network    = google_compute_network.vpc_networks["web"].id
    subnetwork = google_compute_subnetwork.subnets["web_central"].id

    access_config {
      network_tier = "PREMIUM"
    }
  }

  # Startup script to install iperf3 and apache2
  metadata = {
    enable-oslogin = "TRUE"
    startup-script = <<-EOF
      #!/bin/bash
      set -e

      # Log output to file
      exec > >(tee -a /var/log/startup-script.log)
      exec 2>&1

      echo "Starting startup script at $(date)"

      # Update package list
      apt-get update

      # Install packages with proper error handling
      DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 apache2

      # Wait for Apache2 to be fully installed
      sleep 5

      # Create a simple index page with hostname
      cat > /var/www/html/index.html <<HTML_EOF
      <!DOCTYPE html>
      <html>
      <head><title>NSI Test Server</title></head>
      <body>
        <h1>NSI Test Server - $(hostname)</h1>
        <p>Zone: ${each.key}</p>
        <p>Server Time: $(date)</p>
      </body>
      </html>
      HTML_EOF

      # Configure iperf3 as a service
      cat > /etc/systemd/system/iperf3.service <<'IPERF_EOF'
      [Unit]
      Description=iPerf3 Server
      After=network.target

      [Service]
      Type=simple
      ExecStart=/usr/bin/iperf3 -s
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
      IPERF_EOF

      # Reload systemd and start services
      systemctl daemon-reload

      # Enable and start iperf3
      systemctl enable iperf3
      systemctl start iperf3

      # Enable and restart apache2 to ensure clean start
      systemctl enable apache2
      systemctl restart apache2

      # Verify services are running
      sleep 2
      systemctl is-active --quiet apache2 && echo "Apache2 is running" || echo "Apache2 failed to start"
      systemctl is-active --quiet iperf3 && echo "iPerf3 is running" || echo "iPerf3 failed to start"

      echo "Startup script completed at $(date)"
    EOF
  }

  # Allow HTTP/HTTPS and SSH traffic
  tags = ["web-server", "allow-https-ssh"]
}

# Additional firewall rules for web servers
resource "google_compute_firewall" "web_server_firewall" {
  name        = "${local.prefix}-web-server-allow"
  network     = google_compute_network.vpc_networks["web"].id
  description = "Allow HTTP, HTTPS, SSH, and iperf3 to web servers"

  allow {
    protocol = "tcp"
    ports    = ["22", "443", "5201"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web-server", "allow-https-ssh"]
}
