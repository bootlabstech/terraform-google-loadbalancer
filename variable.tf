variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "name" {
  type        = string
  description = "Base name used to derive names for all created resources."
}

variable "region" {
  type        = string
  description = "Region for internal LB resources and regional NEGs (serverless, regional VM-based)."
}

variable "zone" {
  type        = string
  default     = null
  description = "Zone for zonal resources (instance group, zonal NEG). Required when backend_type is 'instance_group' or 'neg' with an external LB."
}

variable "network" {
  type        = string
  default     = null
  description = "VPC network self_link or name. Required for instance_group, neg, and forwarding rule (internal)."
}

variable "subnetwork" {
  type        = string
  default     = null
  description = "Subnetwork self_link or name. Required for internal IP, internal forwarding rule, and NEGs that need it."
}

# -----------------------------
# LB TYPE / BACKEND TYPE
# -----------------------------
variable "lb_type" {
  type        = string
  description = "Load balancer scope: 'internal' or 'external'."
 
}

variable "backend_type" {
  type        = string
  description = "Backend implementation: 'neg', 'bucket', 'instance_group', or 'serverless'."
 
}

# -----------------------------
# SSL CERT
# -----------------------------
# variable "existing_ssl_name" {
#   type        = string
#   description = "Name of the existing SSL certificate (global cert for external LB, regional cert for internal LB)."
# }

# -----------------------------
# INSTANCE GROUP (UMIG) BACKEND
# -----------------------------
variable "instances" {
  type        = list(string)
  default     = []
  description = "Instance self_links to add to the unmanaged instance group. Required when backend_type = 'instance_group'."
}

variable "backend_port_name" {
  type        = string
  default     = "http"
  description = "Named port used by the instance group and referenced by the backend service port_name."
}

variable "port" {
  type        = number
  default     = 80
  description = "Port used for the named port (instance group), NEG default_port, and health checks."
}

# -----------------------------
# NEG (VM IP:PORT) BACKEND
# -----------------------------
variable "neg_type" {
  type        = string
  default     = "GCE_VM_IP_PORT"
  description = "Network endpoint type for VM-based NEGs. Must be GCE_VM_IP_PORT. (Use backend_type = 'serverless' for Cloud Run/Cloud Functions instead of setting this to SERVERLESS.)"
 
}

variable "neg_endpoints" {
  type = list(object({
    ip       = string
    port     = number
    instance = string
  }))
  default     = []
  description = "List of IP/port/instance endpoints to register in the VM-based NEG."
}

variable "neg_max_rate_per_endpoint" {
  type        = number
  default     = 100
  description = "max_rate_per_endpoint for the external backend service's RATE balancing mode on NEG backends."
}

# -----------------------------
# SERVERLESS BACKEND (Cloud Run / Cloud Functions)
# -----------------------------
variable "serverless_type" {
  type        = string
  default     = "cloud_run"
  description = "Which serverless product backs the NEG: 'cloud_run' or 'cloud_function'. Required when backend_type = 'serverless'."
  
}

variable "cloud_run_service_name" {
  type        = string
  default     = null
  description = "Name of the existing Cloud Run service. Required when backend_type = 'serverless' and serverless_type = 'cloud_run'."
}

variable "cloud_function_name" {
  type        = string
  default     = null
  description = "Name of the existing Cloud Function (2nd gen). Required when backend_type = 'serverless' and serverless_type = 'cloud_function'."
}

# -----------------------------
# BUCKET BACKEND
# -----------------------------
variable "bucket_name" {
  type        = string
  default     = null
  description = "GCS bucket name backing the LB. Required when backend_type = 'bucket' (external LB only)."
}

variable "enable_cdn" {
  type        = bool
  default     = false
  description = "Enable Cloud CDN on the backend bucket."
}

# -----------------------------
# BACKEND SERVICE COMMON
# -----------------------------
variable "protocol" {
  type        = string
  default     = "HTTP"
  description = "Protocol used by the backend service (HTTP, HTTPS, HTTP2). Not used for bucket or serverless backends."
}

variable "security_policy_id" {
  type        = string
  default     = ""
  description = "Cloud Armor security policy ID/self_link to attach to the external backend service. Leave empty to skip."
}

# SSL BUCKET to create SSL CERTIFICATE automatically

variable "ssl_bucket" {
  description = "Name of the Google Cloud Storage bucket containing the SSL certificate and private key."
  type        = string
}

variable "ssl_cert_object" {
  description = "Name of the SSL certificate file stored in the GCS bucket."
  type        = string

}

variable "ssl_key_object" {
  description = "Name of the private key file stored in the GCS bucket."
  type        = string
  
}

variable "ssl_certificate_name" {
  description = "Name to assign to the Google Cloud SSL certificate resource."
  type        = string
  
}
variable "ssl_project_id" {
  description = "Name to assign to the Google Cloud SSL certificate resource."
  type        = string
  
}