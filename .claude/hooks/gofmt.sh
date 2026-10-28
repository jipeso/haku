#!/usr/bin/env bash
f=$(jq -r '.tool_input.file_path // empty')
[[ "$f" == *.go && -f "$f" ]] && gofmt -w "$f"
exit 0
