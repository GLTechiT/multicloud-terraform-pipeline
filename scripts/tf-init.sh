#!/usr/bin/env bash
# Inicializa o Terraform com o state do ambiente informado (um arquivo por ambiente no S3).
# Uso (de dentro de terraform/): ../scripts/tf-init.sh qa|dev|prd
set -euo pipefail

case "${1:-}" in
  qa | dev | prd) ;;
  *)
    echo "uso: $0 qa|dev|prd" >&2
    exit 1
    ;;
esac

terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${1}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"
