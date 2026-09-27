// One-time `import` for the three Firebase-auto-created API keys (security
// audit M3). `import` blocks must live in the root module (not inside
// modules/apikeys) but are safe to leave here permanently: Terraform skips
// them silently once a resource is already in state (self-documenting, no
// separate `terraform import` command for anyone to forget).
//
// Resource name format is `projects/<project-number>/locations/global/keys/<uid>`
// (matches `gcloud services api-keys list --project=dzeroth-prod --format=json`).

import {
  to = module.apikeys.google_apikeys_key.browser
  id = "projects/${data.google_project.this.number}/locations/global/keys/${var.browser_key_uid}"
}

import {
  to = module.apikeys.google_apikeys_key.android
  id = "projects/${data.google_project.this.number}/locations/global/keys/${var.android_key_uid}"
}

import {
  to = module.apikeys.google_apikeys_key.ios
  id = "projects/${data.google_project.this.number}/locations/global/keys/${var.ios_key_uid}"
}
