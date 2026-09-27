output "topic_names" {
  value = { for k, v in google_pubsub_topic.topics : k => v.name }
}

output "dlq_topic_names" {
  value = { for k, v in google_pubsub_topic.dlq : k => v.name }
}
