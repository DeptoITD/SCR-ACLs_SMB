#!/usr/bin/env bash
set -euo pipefail

# scripts/validate.sh
# Valida entorno antes de aplicar ACLs POSIX desde INI transversal.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INI_FILE="${INI_FILE:-${REPO_DIR}/config/rules.d/acls.ini}"

fail=0

echo "[VALIDATE] Iniciando validación del entorno (INI=${INI_FILE})"

# -----------------------------
# Validar binarios requeridos
# -----------------------------
for bin in setfacl getfacl getent awk; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "[ERROR] Falta binario requerido: ${bin}"
    fail=1
  fi
done

# -----------------------------
# Validar INI
# -----------------------------
if [[ ! -f "${INI_FILE}" ]]; then
  echo "[ERROR] INI no existe: ${INI_FILE}"
  exit 1
fi

# -----------------------------
# Parse mínimo del INI
# -----------------------------
ROOT=""
PROJECT_GLOB="*"
WIP_FOLDER="01_WIP"
SPECIALTIES_COUNT=0

declare -A SEEN_PROFILES=()

section=""

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="$(trim "$raw")"

  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^\; ]] && continue
  [[ "$line" =~ ^# ]] && continue

  if [[ "$line" =~ ^\[(.+)\]$ ]]; then
    section="${BASH_REMATCH[1]}"
    # marca perfiles (todo lo que no sea GLOBAL ni SPECIALTIES)
    if [[ "$section" != "GLOBAL" && "$section" != "SPECIALTIES" ]]; then
      SEEN_PROFILES["$section"]=1
    fi
    continue
  fi

  if [[ "$section" == "SPECIALTIES" ]]; then
    # soporta comentarios inline "A_ARQ ; algo"
    line="${line%%;*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    ((SPECIALTIES_COUNT++))
    continue
  fi

  if [[ "$section" == "GLOBAL" && "$line" == *"="* ]]; then
    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"
    case "$key" in
      root) ROOT="$val" ;;
      project_glob) PROJECT_GLOB="$val" ;;
      wip_folder) WIP_FOLDER="$val" ;;
      *) : ;;
    esac
  fi
done < "${INI_FILE}"

# -----------------------------
# Validar GLOBAL.root
# -----------------------------
if [[ -z "${ROOT}" ]]; then
  echo "[ERROR] GLOBAL.root no definido en INI"
  fail=1
else
  echo "[OK] ROOT definido: ${ROOT}"
  if [[ ! -d "${ROOT}" ]]; then
    echo "[ERROR] ROOT no existe o no es directorio: ${ROOT}"
    fail=1
  fi
fi

# -----------------------------
# Validar SPECIALTIES
# -----------------------------
if [[ "${SPECIALTIES_COUNT}" -le 0 ]]; then
  echo "[ERROR] No hay SPECIALTIES en el INI (sección vacía o ausente)"
  fail=1
else
  echo "[OK] SPECIALTIES detectadas: ${SPECIALTIES_COUNT}"
fi

# -----------------------------
# Validar que existan perfiles
# -----------------------------
profiles_total="${#SEEN_PROFILES[@]}"
if [[ "${profiles_total}" -le 0 ]]; then
  echo "[ERROR] No hay perfiles (secciones) en el INI aparte de [GLOBAL]/[SPECIALTIES]"
  fail=1
else
  echo "[OK] Perfiles detectados en INI: ${profiles_total}"
fi

# -----------------------------
# Validar expansión de proyectos (no bloqueante, pero útil)
# -----------------------------
if [[ -n "${ROOT}" ]]; then
  shopt -s nullglob
  # shellcheck disable=SC2206
  PROJECT_PATHS=( ${ROOT}/${PROJECT_GLOB} )
  shopt -u nullglob

  if [[ "${#PROJECT_PATHS[@]}" -eq 0 ]]; then
    echo "[WARN] No hay proyectos que matcheen: ${ROOT}/${PROJECT_GLOB}"
  else
    echo "[OK] Proyectos matcheados: ${#PROJECT_PATHS[@]}"
    # opcional: validar que exista el WIP folder en al menos uno (warning)
    wip_found=0
    for pp in "${PROJECT_PATHS[@]}"; do
      [[ -d "${pp}" ]] || continue
      if [[ -d "${pp}/${WIP_FOLDER}" ]]; then
        wip_found=1
        break
      fi
    done
    if [[ "${wip_found}" -eq 0 ]]; then
      echo "[WARN] No se encontró '${WIP_FOLDER}' en los proyectos detectados (puede ser normal)."
    fi
  fi
fi

# -----------------------------
# Validar sujetos (usuarios/grupos) del INI (no bloqueante por AD/LDAP)
# -----------------------------
missing_subjects=0
for prof in "${!SEEN_PROFILES[@]}"; do
  if ! getent passwd "${prof}" >/dev/null 2>&1 && ! getent group "${prof}" >/dev/null 2>&1; then
    echo "[WARN] Perfil '${prof}' no existe localmente (getent). Samba/LDAP/AD podrían resolverlo."
    ((missing_subjects++))
  fi
done
echo "[OK] Perfiles no presentes localmente: ${missing_subjects}"

# -----------------------------
# Resultado final
# -----------------------------
if [[ "${fail}" -ne 0 ]]; then
  echo "[FAIL] Validación falló. No es seguro aplicar ACLs."
  exit 2
fi

echo "[OK] Validación completada correctamente"
