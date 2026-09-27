// Brings the three Firebase-auto-created API keys (browser, Android, iOS)
// under Terraform. Firebase creates these unrestricted the moment you add a
// web/Android/iOS app to a project (before this module ever runs) — there is
// no google_apikeys_key data source, so the calling env's `import` blocks
// (which must live in the root module, not here) attach the real resources by
// UID before the first `apply`. Security audit M3: restrict the browser key's
// HTTP referrers, the iOS key's bundle ID, and every key's api_targets;
// document the Android SHA-1 step for later in docs/runbooks/cloud-bootstrap.md.
//
// prevent_destroy: these UIDs are permanent and already embedded in shipped
// app builds (google-services.json / GoogleService-Info.plist / firebase_options.dart).
// Destroying and recreating one would orphan every already-installed client.
//
// project = var.project_number (NOT the project ID string): google_apikeys_key
// reads/stores project as the numeric project number, and project is ForceNew
// -- setting the ID string here plans a destroy+recreate of a live, imported
// key (verified against a real plan against dzeroth-dev 2026-09-27).

resource "google_apikeys_key" "browser" {
  project      = var.project_number
  name         = var.browser_key_uid
  display_name = "Browser key (auto created by Firebase)"

  restrictions {
    browser_key_restrictions {
      allowed_referrers = var.browser_allowed_referrers
    }

    dynamic "api_targets" {
      for_each = var.browser_api_targets
      content {
        service = api_targets.value
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_apikeys_key" "android" {
  project      = var.project_number
  name         = var.android_key_uid
  display_name = "Android key (auto created by Firebase)"

  restrictions {
    # No SHA-1 fingerprint yet (no Play Console listing) -- omitted entirely
    # rather than set with an empty allowed_applications list, which would
    # restrict the key to NO app and break it. See var.android_allowed_applications.
    dynamic "android_key_restrictions" {
      for_each = length(var.android_allowed_applications) > 0 ? [1] : []
      content {
        dynamic "allowed_applications" {
          for_each = var.android_allowed_applications
          content {
            package_name     = allowed_applications.value.package_name
            sha1_fingerprint = allowed_applications.value.sha1_fingerprint
          }
        }
      }
    }

    dynamic "api_targets" {
      for_each = var.android_api_targets
      content {
        service = api_targets.value
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_apikeys_key" "ios" {
  project      = var.project_number
  name         = var.ios_key_uid
  display_name = "iOS key (auto created by Firebase)"

  restrictions {
    ios_key_restrictions {
      allowed_bundle_ids = [var.ios_bundle_id]
    }

    dynamic "api_targets" {
      for_each = var.ios_api_targets
      content {
        service = api_targets.value
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
