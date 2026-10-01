terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial config: the bucket is created once, manually, outside Terraform
  # (see gcp-terraform skill — a small GCS bucket can't provision the bucket
  # it needs to store its own state). Supply the rest at `terraform init`:
  #   terraform init -backend-config="bucket=<state-bucket-name>"
  backend "gcs" {
    prefix = "thezerothai/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # User (ADC) credentials: bill API quota to this project. Required for the Billing Budgets and
  # Firebase APIs, which reject user credentials without a quota project.
  user_project_override = true
  billing_project       = var.project_id
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  # User (ADC) credentials: bill API quota to this project. Required for the Billing Budgets and
  # Firebase APIs, which reject user credentials without a quota project.
  user_project_override = true
  billing_project       = var.project_id
}
