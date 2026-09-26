#!/usr/bin/env bash
# Block edits to generated code and secret files. Exit 2 = block with message to Claude.
f=$(jq -r '.tool_input.file_path // empty')
case "$f" in
  */gen/*|*.pb.go|*.connect.go|*.pb.dart|*.pbgrpc.dart|*.g.dart|*.freezed.dart)
    echo "Generated file: edit the source (.proto / annotated class) and run 'make proto' or 'dart run build_runner build' instead." >&2; exit 2 ;;
  *.env|*.env.*|*.pem|*credentials*.json|*sa-key*.json)
    echo "Secrets must live in Secret Manager, not in the repo." >&2; exit 2 ;;
esac
exit 0
