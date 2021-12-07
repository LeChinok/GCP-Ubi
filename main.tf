terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "4.0.0"
    }
  }
}

provider "google" {
  project = "ubitricity-chinok"
  region = var.region
  zone = "europe-west73-c"
  credentials = file("/Users/herrchinok/secrets/ubitricity-chinok-98e91238429a.json")
}

### VPC ###
resource "google_compute_network" "vpc_network" {
	name = "vpc-network"
	auto_create_subnetworks = false
}

### SUBNET ###

# public subnet #
resource "google_compute_subnetwork" "subnetwork" {
  name = "public"
  ip_cidr_range = "10.2.0.0/16"
  region = var.region
  network = google_compute_network.vpc_network.id

  secondary_ip_range {
    range_name    = "subnet-01-secondary-01"
    ip_cidr_range = "192.168.64.0/24"
  }
}

# private subnet #
resource "google_compute_subnetwork" "subnetwork_private" {
  name = "private"
  ip_cidr_range = "10.100.0.0/16"
  region = var.region
  network = google_compute_network.vpc_network.id
  private_ip_google_access = "true" 
}

# for user handler
resource "google_compute_instance" "user" {
  name = "user"
  machine_type = "e2-medium"
  zone = "europe-west3-c"

  metadata_startup_script = "sudo apt -y update; sudo apt -y install nginx;"
  tags = ["nginx"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-9"
    }
  }

  network_interface {
    network = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnetwork.id

    access_config {

	}
  }
}

# for companies handler
# for user handler
resource "google_compute_instance" "companies" {
  name = "companies"
  machine_type = "e2-medium"
  zone = "europe-west3-c"

  metadata_startup_script = "sudo apt -y update; sudo apt -y install nginx;"
  tags = ["nginx"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-9"
    }
  }

  network_interface {
    network = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnetwork.id

    access_config {

	}
  }
}

resource "google_compute_firewall" "default" {
  name = "allow-http"
  network = google_compute_network.vpc_network.id


  allow {
    protocol = "tcp"
    ports = ["80", "22", "443"]
  }

  source_tags = ["nginx"]
  source_ranges = ["0.0.0.0/0"]
}


### DATABASE ###
resource "google_sql_database" "database" {
  name     = "my-database"
  instance = google_sql_database_instance.db_instance.name
  project          = "ubitricity-chinok"
}

resource "google_sql_database_instance" "db_instance" {
  name             = "my-database-instance"
  database_version = "MYSQL_5_7"
  region           = var.region
  project          = "ubitricity-chinok"

  settings {
    # Second-generation instance tiers are based on the machine
    # type. See argument reference below.
    tier = "db-f1-micro"
    availability_type = "REGIONAL"
    activation_policy = "ALWAYS"
    disk_size    = 10
    disk_type    = "PD_SSD"
    pricing_plan = "PER_USE"
  }
}

resource "google_sql_user" "default" {
  count      = 1
  name       = "default"
  project    = "ubitricity-chinok"
  instance   = google_sql_database_instance.db_instance.name
  host       = "%"
  password   = "KSDFJ2398"
}

resource "google_sql_user" "additional_users" {
  project    = "ubitricity-chinok"
  name       = "chinok-db"
  password   = "KSDFJ2398"
  host       = "localhost"
  instance   = google_sql_database_instance.db_instance.name
}

### LOAD BALANCER ###

resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "l7-ilb-proxy-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

# http proxy
resource "google_compute_region_target_http_proxy" "default" {
  name     = "l7-ilb-target-http-proxy"
  region   = var.region
  url_map  = google_compute_region_url_map.default.id
}

# url map
resource "google_compute_region_url_map" "default" {
  name            = "l7-ilb-regional-url-map"
  region          = var.region
  default_service = google_compute_region_backend_service.default.id
}

# backend service
resource "google_compute_region_backend_service" "default" {
  name                  = "l7-ilb-backend-subnet"
  region                = var.region
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 10
  health_checks         = [google_compute_region_health_check.default.id]
  backend {
    group           = google_compute_region_instance_group_manager.mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance template
resource "google_compute_instance_template" "instance_template" {
  name         = "l7-ilb-mig-template"

  machine_type = "e2-small"
  tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnetwork.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_region_health_check" "default" {
  name     = "l7-ilb-hc"

  region   = var.region
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

# MIG
resource "google_compute_region_instance_group_manager" "mig" {
  name     = "l7-ilb-mig1"

  region   = var.region
  version {
    instance_template = google_compute_instance_template.instance_template.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# allow http from proxy subnet to backends
resource "google_compute_firewall" "fw-ilb-to-backends" {
  name          = "l7-ilb-fw-allow-ilb-to-backends"
  direction     = "INGRESS"
  network       = google_compute_network.vpc_network.id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080", "22"]
  }
}