#!/usr/bin/env bash
# Mesmo que build.ps1: contratos (mvn install) e depois services (mvn package).
# Sem "clean" (OneDrive) e com -DskipTests (como nos Jenkinsfiles).
set -euo pipefail
cd "$(dirname "$0")"
for d in product account; do echo "==> $d (install)"; (cd "$d" && mvn -B -q -DskipTests install); done
for d in product-service account-service auth-service gateway-service; do echo "==> $d (package)"; (cd "$d" && mvn -B -q -DskipTests package); done
echo "OK: jars gerados. Agora: docker compose up --build -d"
