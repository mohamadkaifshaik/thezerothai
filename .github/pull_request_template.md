## What

<!-- One concern per PR. What changes, in a sentence or two. -->

## Why

<!-- The problem or ticket this solves. -->

## Verification

<!-- What you ran and what it showed. -->

- [ ] `make ci` green
- [ ] `make test-int` green (backend changes)
- [ ] `make proto` run and the generated diff committed (proto changes)

## Flags and rollout

<!-- New public RPC: FEATURE_<NAME> registered in config.go and scripts/promotion/flag-ceiling.json. Anything that needs an
owner step (terraform apply, allowlist, index deploy)? Say which, and the order. "None" is a fine answer. -->

## Screenshots

<!-- UI changes: phone, tablet, desktop. Delete this section otherwise. -->
