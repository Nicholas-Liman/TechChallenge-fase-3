#!/usr/bin/env bash
# Roda o db/init.sql de cada serviço no seu RDS. Os bancos são privados, então o psql roda num pod
# temporário dentro do cluster. A connection string vem do Secret "mysecret" de cada namespace (k8s/03-secrets.yaml).
# O init.sql do auth também cadastra a chave de serviço que o evaluation usa (SERVICE_API_KEY).
# Uso: ./scripts/init-db.sh [servico...]   (ex.: ./scripts/init-db.sh flag)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICES=("${@:-auth flag targeting}")

for svc in ${SERVICES[@]}; do
  url="$(kubectl get secret mysecret -n "${svc}" -o jsonpath='{.data.DATABASE_URL}' | base64 -d)"
  echo ">> init.sql do ${svc}"
  kubectl run "psql-${svc}" -n "${svc}" --rm -i --restart=Never --image=postgres:17-alpine -- \
    psql "${url}" <"${ROOT}/services/${svc}-service/db/init.sql"
done
