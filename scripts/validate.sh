#!/bin/bash
set -euo pipefail

# scripts/validate.sh
# Valida entorno antes de aplicar ACLs POSIX

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECTS_CONF="${REPO_DIR}/config/projects.conf"
USERS_CONF="${REPO_DIR}/config/users.conf"

fail=0

echo "[VALIDATE] Iniciando validación del entorno"

# -----------------------------
# Validar archivos de config
# -----------------------------
if [[ ! -f "${PROJECTS_CONF}" ]]; then
  echo "[ERROR] No existe ${PROJECTS_CONF}"
  exit 1
fi

if [[ ! -f "${USERS_CONF}" ]]; then
  echo "[ERROR] No existe ${USERS_CONF}"
  exit 1
fi

# shellcheck source=/dev/null
source "${PROJECTS_CONF}"
# shellcheck source=/dev/null
source "${USERS_CONF}"

# -----------------------------
# Validar BASE
# -----------------------------
if [[ -z "${BASE:-}" ]]; then
  echo "[ERROR] BASE no está definida en projects.conf"
  exit 1
fi

echo "[OK] BASE definida: ${BASE}"

if [[ ! -d "${BASE}" ]]; then
  echo "[ERROR] BASE no existe en el filesystem: ${BASE}"
  exit 1
fi

# -----------------------------
# Validar PROJECTS
# -----------------------------
if [[ -z "${PROJECTS[*]:-}" ]]; then
  echo "[WARN] No hay proyectos definidos en PROJECTS[]"
else
  for p in "${PROJECTS[@]}"; do
    if [[ ! -d "${BASE}/${p}" ]]; then
      echo "[WARN] Proyecto no existe en este servidor: ${BASE}/${p}"
    fi
  done
fi

# -----------------------------
# Validar usuarios / grupos
# -----------------------------
if [[ -z "${ACL_USERS[*]:-}" ]]; then
  echo "[WARN] No hay usuarios definidos en ACL_USERS[]"
else
  for u in "${ACL_USERS[@]}"; do
    if ! id "${u}" &>/dev/null; then
      echo "[ERROR] Usuario o grupo no existe en el sistema: ${u}"
      fail=1
    fi
  done
fi

# -----------------------------
# Resultado final
# -----------------------------
if [[ "${fail}" -ne 0 ]]; then
  echo "[FAIL] Validación falló. No es seguro aplicar ACLs."
  exit 2
fi

echo "[OK] Validación completada correctamente"
