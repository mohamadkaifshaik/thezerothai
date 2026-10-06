#!/usr/bin/env bash
# Auto-format files after Claude edits them. Never fails the edit.
f=$(jq -r '.tool_input.file_path // empty')
[ -z "$f" ] && exit 0
case "$f" in
  *.go)    command -v gofmt >/dev/null && gofmt -w "$f"; command -v goimports >/dev/null && goimports -w "$f" ;;
  *.dart)  command -v dart  >/dev/null && dart format "$f" >/dev/null ;;
  *.tf)    command -v terraform >/dev/null && terraform fmt "$f" >/dev/null ;;
  *.proto) command -v buf >/dev/null && buf format -w "$f" ;;
esac
exit 0
