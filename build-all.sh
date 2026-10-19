#!/usr/bin/env bash
set -euo pipefail
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$REPOSITORY_ROOT/backend/build-backend.sh"
bash "$REPOSITORY_ROOT/macos/build-app.sh"
