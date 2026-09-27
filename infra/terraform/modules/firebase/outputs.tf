output "web_app_id" {
  value = google_firebase_web_app.default.app_id
}

output "android_app_id" {
  value = google_firebase_android_app.default.app_id
}

output "ios_app_id" {
  value = google_firebase_apple_app.default.app_id
}

output "hosting_site_id" {
  value = google_firebase_hosting_site.default.site_id
}

output "hosting_default_url" {
  value = "https://${google_firebase_hosting_site.default.site_id}.web.app"
}

// Records to create at the DNS provider, one flat list per custom domain. required_action is
// ADD or REMOVE; remove any conflicting records Firebase reports (e.g. a registrar placeholder A).
output "custom_domain_dns_records" {
  value = {
    for domain, cd in google_firebase_hosting_custom_domain.this : domain => flatten([
      for update in cd.required_dns_updates : [
        for desired in update.desired : [
          for r in desired.records : {
            name   = r.domain_name
            type   = r.type
            value  = r.rdata
            action = r.required_action
          }
        ]
      ]
    ])
  }
}

output "custom_domain_status" {
  value = {
    for domain, cd in google_firebase_hosting_custom_domain.this : domain => {
      host      = cd.host_state
      ownership = cd.ownership_state
      cert      = try(cd.cert[0].state, null)
    }
  }
}
