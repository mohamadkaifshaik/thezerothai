// Topics + OIDC push subscriptions to the api service's `/internal/*` async
// handlers. Every topic gets a DLQ so a poison message can't retry forever
// and burn through the free quota; max 5 delivery attempts (per-topic override, e.g. jobs = 10) before DLQ.

resource "google_pubsub_topic" "topics" {
  for_each = var.topics

  project = var.project_id
  name    = each.key
  labels  = var.labels

  message_retention_duration = "86400s" # 1 day, plenty for push delivery, keeps storage small
}

resource "google_pubsub_topic" "dlq" {
  for_each = var.topics

  project = var.project_id
  name    = "${each.key}-dlq"
  labels  = var.labels

  message_retention_duration = "604800s" # 7 days to give humans time to inspect/replay
}

// Push subscription's dead-letter policy needs the DLQ topic's publisher
// role granted to the Pub/Sub service agent.
resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  for_each = var.topics

  project = var.project_id
  topic   = google_pubsub_topic.dlq[each.key].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.pubsub_service_agent_email}"
}

resource "google_pubsub_subscription" "push" {
  for_each = var.topics

  project = var.project_id
  name    = "${each.key}-push"
  topic   = google_pubsub_topic.topics[each.key].id
  labels  = var.labels

  ack_deadline_seconds = 30

  push_config {
    push_endpoint = "${var.push_base_url}${each.value.push_path}"

    oidc_token {
      service_account_email = var.pubsub_push_service_account_email
      audience              = var.push_base_url
    }

    attributes = {
      "x-goog-version" = "v1"
    }
  }

  retry_policy {
    minimum_backoff = each.value.minimum_backoff
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq[each.key].id
    max_delivery_attempts = each.value.max_delivery_attempts
  }

  expiration_policy {
    ttl = "" # never expire due to inactivity
  }

  depends_on = [google_pubsub_topic_iam_member.dlq_publisher]
}

// Lets the Pub/Sub service agent ack/nack against the DLQ subscription path
// (required for dead-lettering to function) — granted at subscription level
// via the standard "subscriber can forward to DLQ" pattern.
resource "google_pubsub_subscription_iam_member" "dlq_ack" {
  for_each = var.topics

  project      = var.project_id
  subscription = google_pubsub_subscription.push[each.key].name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.pubsub_service_agent_email}"
}

resource "google_pubsub_topic_iam_member" "runtime_publisher" {
  for_each = var.runtime_publisher_topics

  project = var.project_id
  topic   = google_pubsub_topic.topics[each.key].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.runtime_service_account_email}"
}
