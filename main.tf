resource "google_project_service" "certapi" {
  project            = var.project_id
  service            = "certificatemanager.googleapis.com"
  disable_on_destroy = false
}

# -----------------------------
# LOCALS
# -----------------------------
locals {
  is_internal = var.lb_type == "internal"
  is_external = var.lb_type == "external"

  use_neg        = var.backend_type == "neg"
  use_bucket     = var.backend_type == "bucket"
  use_umig       = var.backend_type == "instance_group"
  use_serverless = var.backend_type == "serverless"

  use_cloud_run      = local.use_serverless && var.serverless_type == "cloud_run"
  use_cloud_function = local.use_serverless && var.serverless_type == "cloud_function"

  # Backend service exists for neg/umig/serverless (not bucket)
  need_external_backend_svc = local.is_external && !local.use_bucket
  need_internal_backend_svc = local.is_internal && !local.use_bucket

  # Health checks only apply to neg (VM IP:port) and instance_group backends.
  # Serverless NEGs don't support traditional health checks (outlier detection is used instead),
  # and bucket backends don't have a backend service at all.
  need_health_check = !local.use_bucket && !local.use_serverless
}
############################
# SSL CERTIFICATES
############################

data "google_storage_bucket_object_content" "certificate" {
  bucket = var.ssl_bucket
  name   = var.ssl_cert_object
}

data "google_storage_bucket_object_content" "private_key" {
  bucket = var.ssl_bucket
  name   = var.ssl_key_object
}

resource "google_compute_ssl_certificate" "external_ssl" {
  count = local.is_external ? 1 : 0

  name        = var.ssl_certificate_name
  project     = var.ssl_project_id

  private_key = data.google_storage_bucket_object_content.private_key.content
  certificate = data.google_storage_bucket_object_content.certificate.content

  lifecycle {
    create_before_destroy = true
  }
}
resource "google_compute_region_ssl_certificate" "internal_ssl" {
  count = local.is_internal ? 1 : 0

  name    = var.ssl_certificate_name
  project = var.ssl_project_id
  region  = var.region

  private_key = data.google_storage_bucket_object_content.private_key.content
  certificate = data.google_storage_bucket_object_content.certificate.content

  lifecycle {
    create_before_destroy = true
  }
}
 
# # -----------------------------
# # EXTERNAL LB (GLOBAL SSL CERT)
# # -----------------------------
# data "google_compute_ssl_certificate" "external_ssl" {
#   count   = local.is_external ? 1 : 0
#   name    = var.existing_ssl_name
#   project = var.project_id
# }

# # -----------------------------
# # INTERNAL LB (REGIONAL SSL CERT)
# # -----------------------------
# data "google_compute_region_ssl_certificate" "internal_ssl" {
#   count   = local.is_internal ? 1 : 0
#   name    = var.existing_ssl_name
#   project = var.project_id
#   region  = var.region
# }

# ============================================================
# BACKEND TYPE: INSTANCE GROUP (UMIG)
# ============================================================
resource "google_compute_instance_group" "instance_group" {
  count     = local.use_umig ? 1 : 0
  project   = var.project_id
  name      = "${var.name}-umig"
  zone      = var.zone
  instances = var.instances
  network   = var.network

  named_port {
    name = var.backend_port_name
    port = var.port
  }
}

# ============================================================
# BACKEND TYPE: NEG (VM IP:PORT) — zonal, used by both external and internal LB
# ============================================================
resource "google_compute_network_endpoint_group" "neg" {
  count                 = local.use_neg ? 1 : 0
  project               = var.project_id
  name                  = "${var.name}-neg"
  network               = var.network
  subnetwork            = var.subnetwork
  zone                  = var.zone
  network_endpoint_type = var.neg_type
  default_port          = var.port
}

resource "google_compute_network_endpoint" "neg_endpoints" {
  for_each = local.use_neg ? { for ep in var.neg_endpoints : ep.ip => ep } : {}

  project                = var.project_id
  network_endpoint_group = google_compute_network_endpoint_group.neg[0].name
  zone                    = var.zone
  ip_address             = each.value.ip
  port                   = each.value.port
  instance               = lookup(each.value, "instance", null)
}

# ============================================================
# BACKEND TYPE: SERVERLESS (Cloud Run / Cloud Functions)
# Always a REGIONAL NEG, even when fronted by an external (global-style) LB.
# Only one of cloud_run / cloud_function is set, matching var.serverless_type.
# Note: App Engine serverless NEGs are intentionally not modeled here — they
# are only supported behind global external LBs, not regional internal LBs,
# so they don't fit this module's internal/external symmetry. Add a third
# branch with an `app_engine {}` block if you need it for external-only use.
# ============================================================
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  count                 = local.use_serverless ? 1 : 0
  project               = var.project_id
  name                  = "${var.name}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  dynamic "cloud_run" {
    for_each = local.use_cloud_run ? [1] : []
    content {
      service = var.cloud_run_service_name
    }
  }

  dynamic "cloud_function" {
    for_each = local.use_cloud_function ? [1] : []
    content {
      function = var.cloud_function_name
    }
  }
}

# ============================================================
# BACKEND TYPE: GCS BUCKET
# Supported for external LBs only
# ============================================================
resource "google_compute_backend_bucket" "bucket_backend" {
  count       = local.use_bucket && local.is_external ? 1 : 0
  project     = var.project_id
  name        = "${var.name}-bucket-backend"
  bucket_name = var.bucket_name
  enable_cdn  = var.enable_cdn
}

# ============================================================
# HEALTH CHECKS — skipped for bucket and serverless
# ============================================================
resource "google_compute_health_check" "external_hc" {
  count   = local.need_external_backend_svc && local.need_health_check ? 1 : 0
  project = var.project_id
  name    = "${var.name}-hc"

  tcp_health_check {
    port = var.port
  }
}

resource "google_compute_region_health_check" "internal_hc" {
  count   = local.need_internal_backend_svc && local.need_health_check ? 1 : 0
  project = var.project_id
  region  = var.region
  name    = "${var.name}-hc"

  tcp_health_check {
    port = var.port
  }
}

# ============================================================
# BACKEND SERVICE — EXTERNAL (neg, umig, or serverless)
# ============================================================
resource "google_compute_backend_service" "external_backend" {
  count                           = local.need_external_backend_svc ? 1 : 0
  project                         = var.project_id
  name                            = "${var.name}-backend"
  port_name                       = local.use_umig ? var.backend_port_name : null
  protocol                        = local.use_serverless ? null : var.protocol
  load_balancing_scheme           = "EXTERNAL"
  connection_draining_timeout_sec = 300
  health_checks                   = local.need_health_check ? [google_compute_health_check.external_hc[0].id] : null
  session_affinity                = local.use_serverless ? null : "NONE"
  timeout_sec                     = local.use_serverless ? null : 30
  security_policy                 = var.security_policy_id != "" ? var.security_policy_id : null

  dynamic "backend" {
    for_each = local.use_umig ? [1] : []
    content {
      group           = google_compute_instance_group.instance_group[0].id
      balancing_mode  = "UTILIZATION"
      capacity_scaler = 1.0
      max_utilization = 1.0
    }
  }

  dynamic "backend" {
    for_each = local.use_neg ? [1] : []
    content {
      group                 = google_compute_network_endpoint_group.neg[0].id
      balancing_mode        = "RATE"
      max_rate_per_endpoint = var.neg_max_rate_per_endpoint
    }
  }

  # Serverless NEG backends do not support balancing_mode, capacity_scaler,
  # or max_rate_per_endpoint — GCP rejects the backend service if any are set.
  dynamic "backend" {
    for_each = local.use_serverless ? [1] : []
    content {
      group = google_compute_region_network_endpoint_group.serverless_neg[0].id
    }
  }
}

# ============================================================
# BACKEND SERVICE — INTERNAL (neg, umig, or serverless)
# ============================================================
resource "google_compute_region_backend_service" "internal_backend" {
  count                           = local.need_internal_backend_svc ? 1 : 0
  project                         = var.project_id
  region                          = var.region
  name                            = "${var.name}-backend"
  protocol                        = local.use_serverless ? null : var.protocol
  load_balancing_scheme           = "INTERNAL_MANAGED"
  port_name                       = local.use_umig ? var.backend_port_name : null
  connection_draining_timeout_sec = local.use_serverless ? null : 300
  health_checks                   = local.need_health_check ? [google_compute_region_health_check.internal_hc[0].id] : null
  session_affinity                = local.use_serverless ? null : "NONE"
  timeout_sec                     = local.use_serverless ? null : 30

  dynamic "backend" {
    for_each = local.use_umig ? [1] : []
    content {
      group           = google_compute_instance_group.instance_group[0].id
     balancing_mode =  "UTILIZATION"
      capacity_scaler = 1.0
      max_utilization = 1.0
    }
  }

  dynamic "backend" {
    for_each = local.use_neg ? [1] : []
    content {
      group           = google_compute_network_endpoint_group.neg[0].id
     balancing_mode =  "RATE"
      capacity_scaler = 1.0
      max_utilization = 1.0
    }
  }

  dynamic "backend" {
    for_each = local.use_serverless ? [1] : []
    content {
      group           = google_compute_region_network_endpoint_group.serverless_neg[0].id
        balancing_mode =  "UTILIZATION"
      capacity_scaler = 1.0
      
    }
  }
}

# ============================================================
# URL MAP
# ============================================================
resource "google_compute_url_map" "external_url_map" {
  count   = local.is_external ? 1 : 0
  project = var.project_id
  name    = "${var.name}-url-map"

  default_service = (local.use_bucket
  ? google_compute_backend_bucket.bucket_backend[0].id
  : google_compute_backend_service.external_backend[0].id)
}

resource "google_compute_region_url_map" "internal_url_map" {
  count           = local.is_internal ? 1 : 0
  project         = var.project_id
  region          = var.region
  name            = "${var.name}-url-map"
  default_service = google_compute_region_backend_service.internal_backend[0].id
}

# ============================================================
# HTTPS PROXY
# ============================================================
resource "google_compute_target_https_proxy" "external_proxy" {
  count            = local.is_external ? 1 : 0
  project          = var.project_id
  name             = "${var.name}-proxy"
  url_map          = google_compute_url_map.external_url_map[0].id
  ssl_certificates = [google_compute_ssl_certificate.external_ssl[0].self_link]
}

resource "google_compute_region_target_https_proxy" "internal_proxy" {
  count            = local.is_internal ? 1 : 0
  project          = var.project_id
  region           = var.region
  name             = "${var.name}-proxy"
  url_map          = google_compute_region_url_map.internal_url_map[0].id
  ssl_certificates = [google_compute_region_ssl_certificate.internal_ssl[0].self_link]
}

# ============================================================
# IP ADDRESS
# ============================================================
resource "google_compute_global_address" "external_ip" {
  count        = local.is_external ? 1 : 0
  project      = var.project_id
  name         = "${var.name}-ip"
  address_type = "EXTERNAL"
}

resource "google_compute_address" "internal_ip" {
  count        = local.is_internal ? 1 : 0
  project      = var.project_id
  region       = var.region
  name         = "${var.name}-internal-ip"
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
}

# ============================================================
# FORWARDING RULE
# ============================================================
resource "google_compute_global_forwarding_rule" "external_fr" {
  count                 = local.is_external ? 1 : 0
  project               = var.project_id
  name                  = "${var.name}-fr"
  target                = google_compute_target_https_proxy.external_proxy[0].id
  port_range            = "443"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  ip_address            = google_compute_global_address.external_ip[0].address
}

resource "google_compute_forwarding_rule" "internal_fr" {
  count                 = local.is_internal ? 1 : 0
  project               = var.project_id
  region                = var.region
  name                  = "${var.name}-fr"
  target                = google_compute_region_target_https_proxy.internal_proxy[0].id
  port_range            = "443"
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = var.network
  subnetwork            = var.subnetwork
  ip_address            = google_compute_address.internal_ip[0].address
}

resource "google_compute_security_policy" "ext_policy" {
  count                  = local.is_external ? 1 : 0
  name    = "${var.name}-cloud-policy"
  project = var.project_id
  rule {
    action   = "deny(403)"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default rule"
  }
  rule {
    action   = "allow"
    preview  = false
    priority = 1000

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = [
          "103.21.244.0/22",
          "103.22.200.0/22",
          "103.31.4.0/22",
          "108.162.192.0/18",
          "141.101.64.0/18",
          "173.245.48.0/20",
          "188.114.96.0/20",
          "190.93.240.0/20",
          "197.234.240.0/22",
          "198.41.128.0/17",
        ]
      }
    }
  }
  rule {
    action      = "allow"
    description = "rule 2"
    preview     = false
    priority    = 1001

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = [
          "104.16.0.0/13",
          "104.24.0.0/14",
          "131.0.72.0/22",
          "162.158.0.0/15",
          "172.64.0.0/13",
        ]
      }
    }
  }
}