#!/usr/bin/env bash
# Builds the backend JARs through Nexus, so `docker compose build` can package them.
# The backend Dockerfiles copy target/*.jar: run this before `docker compose up --build`.
#
# Usage:
#   ./scripts/build-jars.sh                         # all 7 services
#   ./scripts/build-jars.sh api-gateway             # one service
#   ./scripts/build-jars.sh api-gateway cart-service
#   REVISION=1.0.42 ./scripts/build-jars.sh         # a given version (default: the poms' 0.0.0-SNAPSHOT)
#
# Needs (see docs/NEXUS.md):
#   export NEXUS_URL=https://nexus.ayoubnachti.dev   # or http://localhost:8090
#   export NEXUS_USER=<your Nexus user>
#   read -rs NEXUS_PASSWORD && export NEXUS_PASSWORD
set -euo pipefail

: "${NEXUS_URL:?export NEXUS_URL first (see the header of this script)}"
: "${NEXUS_USER:?export NEXUS_USER first}"
: "${NEXUS_PASSWORD:?export NEXUS_PASSWORD first}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALL_SERVICES="discovery-server api-gateway user-service product-service media-service order-service cart-service"
SERVICES=${*:-$ALL_SERVICES}
REV_ARG=${REVISION:+-Drevision=$REVISION}

# Fail early on a typo, before building anything
for svc in $SERVICES; do
  case " $ALL_SERVICES " in
    *" $svc "*) ;;
    *) echo "Unknown service: $svc (valid: $ALL_SERVICES)" >&2; exit 1 ;;
  esac
done

# The gateway packages its git-ignored HTTPS keystore into the JAR: it must exist first
if [[ " $SERVICES " == *" api-gateway "* && ! -f "$ROOT/backend/api-gateway/src/main/resources/keystore.p12" ]]; then
  echo "Missing backend/api-gateway/src/main/resources/keystore.p12 (see the README's HTTPS section)" >&2
  exit 1
fi

for svc in $SERVICES; do
  echo "=== Packaging $svc"
  (cd "$ROOT/backend/$svc" && ./mvnw -s "$ROOT/settings.xml" -B -ntp clean package -DskipTests $REV_ARG)
done
echo "Built: $SERVICES. Next: docker compose up --build"