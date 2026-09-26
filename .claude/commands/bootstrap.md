---
description: Scaffold the monorepo (Phase 0 of the roadmap) on the free-tier architecture
---
Load the `mvp-roadmap` and `free-tier-budget` skills and execute Phase 0:
1. `architect`: seed ADRs 0002–0007 (0001 exists), initial protos (identity, graph, posts, timeline, media),
   `firebase/firestore.indexes.json`, deny-all `firestore.rules` and `storage.rules`, and `docs/reviews/cost-model.md` v0.
2. `backend-developer`: `backend/` module, `pkg/platform`, `cmd/api` monolith with the `identity` module per `go-service`,
   Makefile targets (proto, ci, emulators, test-int, dev, cost, loadtest), `firebase.json` emulator config.
3. `frontend-developer`: Flutter app shell per `flutter-feature` — Firebase Auth (email/Google/Apple), App Check, router, theme,
   responsive scaffold, API client, local cache.
4. `production-deployer`: Terraform modules + `envs/dev` and `envs/prod` (including budget alerts, caps, dashboard),
   GitHub Actions CI/CD with Workload Identity Federation. Do NOT apply — show the plan and ask me to confirm the Firestore region.
5. `tester`: emulator-based CI test wiring and first smoke tests with budget assertions.
Report what exists, how to run it locally ($0), and the one-time manual steps (billing account link, Firebase project, domain).
