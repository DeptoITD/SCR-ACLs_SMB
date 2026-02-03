#!/usr/bin/env bash
set -euo pipefail

# scripts/apply_acls.sh
# Aplica reglas ACL declarativas definidas en config/rules.d/*.rules
#
# Formato de reglas (una por línea):
#   <usuario>;<permisos>;<ruta_relativa>;<recursivo>
#
# Ejemplos:
#   IND_A;rx;1288_UDQ;false
#   IND_A;rx;1288_UDQ/01_WIP;false
#   IND_A;rwx;1288_UDQ/01_WIP/A_ARQ;true
#
# Notas:
# - ruta_relativa se concatena con BASE (config/projects.conf)
# - recursivo=true aplica ACL y Default ACL recursivo (-R y -R -d)
# - Idempotente: se puede ejecutar múltiples veces.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_DIR}/config/projects.conf"
# shellcheck source=/dev/null
source "${REPO_DIR}/config/users.conf"

RULES_DIR="${REPO_DIR}/config/rules.d"
LOG_FILE="${REPO_DIR}/logs/apply_acls.log"
mkdir -p "${REPO_DIR}/logs"

apply_acl() {
  local user="$1"
  local perms="$2"
  local abs_path="$3"
  local recursive="$4"

  if [[ "${recursive}" == "true" ]]; then
    setfacl -R -m "u:${user}:${perms}" "${abs_path}"
    setfacl -R -d -m "u:${user}:${perms}" "${abs_path}"
  else
    setfacl -m "u:${user}:${perms}" "${abs_path}"
    setfacl -d -m "u:${user}:${perms}" "${abs_path}" 2>/dev/null || true
  fi
}

echo "[INFO] $(date -Is) Iniciando apply_acls" | tee -a "${LOG_FILE}"

"${REPO_DIR}/scripts/validate.sh" | tee -a "${LOG_FILE}"

shopt -s nullglob
rule_files=("${RULES_DIR}"/*.rules)

if [[ "${#rule_files[@]}" -eq 0 ]]; then
  echo "[ERROR] No hay archivos de reglas en ${RULES_DIR}" | tee -a "${LOG_FILE}"
  exit 3
fi

for rf in "${rule_files[@]}"; do
  echo "[INFO] Procesando reglas: ${rf}" | tee -a "${LOG_FILE}"
  while IFS= read -r line; do
    line="$(echo "${line}" | sed 's/[[:space:]]*$//')"
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^# ]] && continue

    IFS=';' read -r user perms rel_path recursive <<< "${line}"

    if [[ -z "${user}" || -z "${perms}" || -z "${rel_path}" || -z "${recursive}" ]]; then
      echo "[WARN] Regla inválida (campos faltantes): ${line}" | tee -a "${LOG_FILE}"
      continue
    fi

    abs_path="${BASE}/${rel_path}"

    if [[ ! -e "${abs_path}" ]]; then
      echo "[WARN] Ruta no existe, se omite: ${abs_path}" | tee -a "${LOG_FILE}"
      continue
    fi

    apply_acl "${user}" "${perms}" "${abs_path}" "${recursive}"
    echo "[OK] ${user} ${perms} ${abs_path} recursive=${recursive}" | tee -a "${LOG_FILE}"
  done < "${rf}"
done

echo "[DONE] $(date -Is) apply_acls finalizado" | tee -a "${LOG_FILE}"
