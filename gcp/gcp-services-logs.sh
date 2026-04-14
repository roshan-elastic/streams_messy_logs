#!/bin/zsh
# Thin wrapper around gcp-services-logs.py so all GCP log generators can be
# invoked with the same `./<name>.sh [flags]` pattern.
SCRIPT_DIR="${0:A:h}"
exec python3 "$SCRIPT_DIR/gcp-services-logs.py" "$@"
