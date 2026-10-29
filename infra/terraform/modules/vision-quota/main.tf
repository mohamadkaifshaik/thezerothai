// Cloud Vision consumer-quota caps (security review of PR #449, finding M-A).
//
// Why: images:annotate checks no Vision IAM permission, only that the caller may bill the project
// (roles/serviceusage.serviceUsageConsumer, which the tf-plan service account holds so that Terraform's
// user_project_override works). Every Vision feature has its own project-wide per-minute quota that defaults to
// 1,800 and bills per unit, and none of them is tied to VISION_MONTHLY_CAP (an app-side counter). A stolen or
// early-minted plan token could therefore burn the credit (ADR-0022) in hours. These overrides make the API itself
// refuse the excess.
//
// The app uses exactly one feature: SAFE_SEARCH_DETECTION (backend/internal/media/vision.go), one image per
// request. So: that feature (and the umbrella `default_requests`) gets a per-minute cap sized from the app's peak
// (see var.safe_search_requests_per_minute), and every other billed feature, async and Product Search quota is
// set to 0, so a multi-feature request cannot pick a cheaper-to-abuse feature.
//
// No fixed cost: a quota override is free and scales nothing up. Lowering a quota by more than 10% is rejected by
// the Service Usage API unless force = true, and every override here is a large decrease, so force = true.
//
// The resource is google-beta only (google provider 8.8.1 has no google_service_usage_consumer_quota_override).
// `metric` and `limit` are passed URL-encoded, the form the resource documents; limit omits the "1/" prefix and
// the braces of the unit shown in the console ("1/min/{project}" becomes "/min/project").
//
// Reverse: delete the override (terraform destroy -target, or remove the entry and apply); the default returns.
// To raise the cap: change var.safe_search_requests_per_minute and apply.

locals {
  service = "vision.googleapis.com"

  // The one feature the app calls, and the umbrella request counter.
  used = {
    safe_search_detection_requests = { limit = "/min/project", value = var.safe_search_requests_per_minute }
    default_requests               = { limit = "/min/project", value = var.safe_search_requests_per_minute }
  }

  // Every other project-level Vision quota the service exposes (consumerQuotaMetrics, read 2026-10-29). The
  // celebrity_recognition_requests metric has no project-level bucket (restricted feature), so it cannot be overridden.
  unused = {
    crop_hints_requests                                = "/min/project"
    document_text_detection_requests                   = "/min/project"
    face_detection_requests                            = "/min/project"
    image_properties_requests                          = "/min/project"
    label_detection_requests                           = "/min/project"
    landmark_detection_requests                        = "/min/project"
    logo_detection_requests                            = "/min/project"
    object_localization_requests                       = "/min/project"
    text_detection_requests                            = "/min/project"
    web_detection_requests                             = "/min/project"
    product_search_requests                            = "/min/project"
    product_search_resource_management_requests        = "/min/project"
    product_search_resource_management_write_requests  = "/min/project"
    product_search_batch_requests                      = "/d/project"
    product_search_import_lines_in_processing_requests = "/project"
    async_images_in_processing_requests                = "/project"
    async_document_pages_in_processing_requests        = "/project"
  }

  overrides = merge(
    local.used,
    { for metric, limit in local.unused : metric => { limit = limit, value = var.unused_feature_limit } },
  )
}

resource "google_service_usage_consumer_quota_override" "vision" {
  for_each = local.overrides

  provider = google-beta

  project        = var.project_id
  service        = local.service
  metric         = urlencode("${local.service}/${each.key}")
  limit          = urlencode(each.value.limit)
  override_value = tostring(each.value.value)
  force          = true
}
