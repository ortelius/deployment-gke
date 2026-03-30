# ---------------------------
# Providers & APIs
# ---------------------------
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "apis" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "cloudbuild.googleapis.com"
  ])
  service            = each.key
  disable_on_destroy = false
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ---------------------------
# Service Accounts
# ---------------------------
resource "google_service_account" "function_sa" {
  account_id   = "gke2-func-sa-${random_id.suffix.hex}"
  display_name = "GKE2Release Function SA"
}

resource "google_project_iam_member" "function_logging" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_service_account" "invoker_sa" {
  account_id   = "gke2-invoker-sa-${random_id.suffix.hex}"
  display_name = "GKE2Release Invoker SA"
}

resource "google_service_account_key" "invoker_key" {
  service_account_id = google_service_account.invoker_sa.name
}

# ---------------------------
# Storage & Source
# ---------------------------
data "archive_file" "source_zip" {
  type        = "zip"
  source_dir  = path.module
  output_path = "/tmp/gke2release-source.zip"
  excludes    = ["main.tf", "variables.tf", "terraform.tfvars", "terraform.tfstate", ".terraform", ".git"]
}

resource "google_storage_bucket" "source_bucket" {
  name          = "${var.project_id}-gke2release-src-${random_id.suffix.hex}"
  location      = "US"
  force_destroy = true
}

resource "google_storage_bucket_object" "source_object" {
  name   = "source-${data.archive_file.source_zip.output_md5}.zip"
  bucket = google_storage_bucket.source_bucket.name
  source = data.archive_file.source_zip.output_path
}

# ---------------------------
# Cloud Function v2
# ---------------------------
resource "google_cloudfunctions2_function" "gke2release_func" {
  name     = "gke2release"
  location = var.region

  build_config {
    runtime     = "go126"
    entry_point = "SyncDeployments"

    # Disable VCS stamping during Cloud Build
    environment_variables = {
      GOFLAGS = "-buildvcs=false"
    }

    source {
      storage_source {
        bucket = google_storage_bucket.source_bucket.name
        object = google_storage_bucket_object.source_object.name
      }
    }
  }

  service_config {
    service_account_email = google_service_account.function_sa.email
    ingress_settings      = "ALLOW_ALL"
    available_memory      = "4096Mi"
    available_cpu         = "1"
    timeout_seconds       = 900

    # Base + ORG environment variables
    environment_variables = merge(
      {
        GCP_PROJECT = var.project_id
      },
      {
        for k, v in var.org_mappings :
        "ORG_${replace(
          replace(
            replace(base64encode(k), "+", "-"),
            "/", "_"
          ),
          "=", ""
        )}" => v
      }
    )
  }

  depends_on = [
    google_project_service.apis,
    google_storage_bucket_object.source_object
  ]
}

# ---------------------------
# IAM & Invoker
# ---------------------------
resource "google_cloud_run_service_iam_member" "invoker" {
  project  = google_cloudfunctions2_function.gke2release_func.project
  location = google_cloudfunctions2_function.gke2release_func.location
  service  = google_cloudfunctions2_function.gke2release_func.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.invoker_sa.email}"
}

# ---------------------------
# Outputs
# ---------------------------
output "function_uri" {
  value = google_cloudfunctions2_function.gke2release_func.service_config[0].uri
}

output "curl_example" {
  value = "TOKEN=$(gcloud auth print-identity-token --impersonate-service-account=${google_service_account.invoker_sa.email}); curl -X POST ${google_cloudfunctions2_function.gke2release_func.service_config[0].uri} -H \"Authorization: Bearer $TOKEN\""
}
