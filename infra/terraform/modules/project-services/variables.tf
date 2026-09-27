variable "project_id" {
  description = "GCP project ID to enable services on."
  type        = string
}

variable "services" {
  description = "List of API service names to enable. Defaults to the Stage 0 reference architecture set."
  type        = list(string)
  default = [
    "run.googleapis.com",
    "firestore.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "apikeys.googleapis.com", # manage the Firebase-auto-created API keys (security audit M3)
    "sts.googleapis.com",
    "vision.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "firebaseappcheck.googleapis.com",
    "identitytoolkit.googleapis.com",
    "billingbudgets.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudbilling.googleapis.com",
  ]
}
