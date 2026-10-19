#!/usr/bin/env bash
set -euo pipefail
BACKEND_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTNET_BIN="${HECRAS_DOTNET:-$(command -v dotnet)}"
mkdir -p "$BACKEND_ROOT/build"
python3 "$BACKEND_ROOT/Tools/verify_packages.py"
"$DOTNET_BIN" build "$BACKEND_ROOT/Ras.Backend.slnx" \
    -c Release -warnaserror \
    -p:RestoreAdditionalProjectSources="$BACKEND_ROOT/Packages" \
    -p:RestorePackagesPath="$BACKEND_ROOT/build/packages" \
    --artifacts-path "$BACKEND_ROOT/build/artifacts" "$@"
"$DOTNET_BIN" publish "$BACKEND_ROOT/Host/Ras.Backend.Host.csproj" \
    -c Release -r osx-arm64 --self-contained true -warnaserror \
    -p:PublishSingleFile=false -p:PublishTrimmed=false \
    -p:RestoreAdditionalProjectSources="$BACKEND_ROOT/Packages" \
    -p:RestorePackagesPath="$BACKEND_ROOT/build/packages" \
    --artifacts-path "$BACKEND_ROOT/build/artifacts" \
    -o "$BACKEND_ROOT/build/publish/osx-arm64" "$@"
HECRAS_DOTNET="$DOTNET_BIN" python3 "$BACKEND_ROOT/Tools/audit_product_compile.py"
