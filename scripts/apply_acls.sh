#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -------------------------
# Config base
# -------------------------
INI_FILE="${INI_FILE:-${REPO_DIR}/config/acls.ini}"

LOG_DIR="${REPO_DIR}/logs"
LOG_FILE="${LOG_DIR}/apply_acls.log"
mkdir -p "${LOG_DIR}"

DRY_RUN="${DRY_RUN:-0}"
DEFAULT_ON_NONRECURSIVE_DIRS="${DEFAULT_ON_NONRECURSIVE_DIRS:-1}"

# Si quieres velocidad en árboles enormes, pon SIMPLE_RECURSIVE=1 para usar setfacl -R
SIMPLE_RECURSIVE="${SIMPLE_RECURSIVE:-0}"

# Grupo de soporte: recibe rwx sobre todo el árbol antes del loop de perfiles
SOPORTE_GROUP="${SOPORTE_GROUP:-soporte}"

# -------------------------
# Logging
# -------------------------
ts() { date -Is; }

_log_line() {
  local level="$1"; shift
  local msg="$*"
  local line="[$level] $(ts) $msg"
  printf "%s\n" "$line" >> "${LOG_FILE}"
  printf "%s\n" "$line"
}

log_info() { _log_line "INFO"  "ℹ️  $*"; }
log_warn() { _log_line "WARN"  "⚠️  $*"; }
log_err()  { _log_line "ERROR" "❌ $*"; }
log_ok()   { _log_line "OK"    "✅ $*"; }

die() { log_err "$*"; exit 1; }

trap 'rc=$?; log_err "💥 Abortado (exit=$rc) en línea ${LINENO}: ${BASH_COMMAND}"; exit $rc' ERR

# -------------------------
# Helpers
# -------------------------
trim() {
  local s="$1"
  s="${s//$'\r'/}"                # mata CRLF de Windows
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

run_cmd() {
  log_info "🧾 [CMD] $*"
  [[ "${DRY_RUN}" == "1" ]] && return 0
  "$@"
}

# Normaliza permisos a formato POSIX ACL (3 chars)
# - "rx"  -> "r-x"
# - "rw"  -> "rw-"
# - "r"   -> "r--"
# - "--x" -> "--x" (ya OK)
# - "rwx" -> "rwx"
normalize_perms() {
  local p
  p="$(trim "$1")"

  # Si ya viene con 3 chars tipo r-x / rw- / --- / --x etc.
  if [[ "$p" =~ ^[r-][w-][x-]$ ]]; then
    printf "%s" "$p"
    return 0
  fi

  # Si viene abreviado (ej: rx, rw, r, x)
  local r="-" w="-" x="-"
  [[ "$p" == *"r"* ]] && r="r"
  [[ "$p" == *"w"* ]] && w="w"
  [[ "$p" == *"x"* ]] && x="x"

  local out="${r}${w}${x}"
  if [[ ! "$out" =~ ^[r-][w-][x-]$ ]]; then
    die "Permisos inválidos: '$p' (normalizado: '$out')"
  fi

  printf "%s" "$out"
}

resolve_acl_subject() {
  local raw="$1"

  # Si viene prefijado (u:... o g:...), se respeta
  if [[ "$raw" =~ ^[ug]: ]]; then
    printf "%s" "$raw"
    return 0
  fi

  # Preferimos grupo si existe
  if getent group "$raw" >/dev/null 2>&1; then
    printf "g:%s" "$raw"
    return 0
  fi

  # Si existe como usuario, úsalo como usuario
  if getent passwd "$raw" >/dev/null 2>&1; then
    printf "u:%s" "$raw"
    return 0
  fi

  # Fallback: usuario (AD/LDAP puede resolver)
  printf "u:%s" "$raw"
}

warn_if_unknown_subject() {
  local raw="$1"
  local subj="$2"
  local name="${subj#*:}"
  if ! getent passwd "${name}" >/dev/null 2>&1 && ! getent group "${name}" >/dev/null 2>&1; then
    log_warn "👤 '${raw}' no existe en getent (se intentará igual: Samba/LDAP/AD podrían resolverlo)."
  fi
}

apply_acl_nonrec() {
  local subject="$1" perms_raw="$2" path="$3"
  local kind="${subject%%:*}" name="${subject#*:}"
  local perms
  perms="$(normalize_perms "$perms_raw")"

  run_cmd setfacl -m "${kind}:${name}:${perms}" "${path}"

  # Default ACL solo aplica a directorios
  if [[ -d "${path}" && "${DEFAULT_ON_NONRECURSIVE_DIRS}" == "1" ]]; then
    run_cmd setfacl -d -m "${kind}:${name}:${perms}" "${path}"
  fi
}

# Aplica ACL recursivo separando dirs y files (DEFAULT solo en DIRS)
apply_acl_tree_split() {
  local subject="$1" dir_perms_raw="$2" file_perms_raw="$3" def_dir_raw="$4" path="$5"
  local kind="${subject%%:*}" name="${subject#*:}"
  local dir_perms file_perms def_dir
  dir_perms="$(normalize_perms "$dir_perms_raw")"
  file_perms="$(normalize_perms "$file_perms_raw")"
  def_dir="$(normalize_perms "$def_dir_raw")"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "🧾 [CMD] find '${path}' -type d -exec setfacl -m ${kind}:${name}:${dir_perms} {} +"
    log_info "🧾 [CMD] find '${path}' -type d -exec setfacl -d -m ${kind}:${name}:${def_dir} {} +"
    log_info "🧾 [CMD] find '${path}' -type f -exec setfacl -m ${kind}:${name}:${file_perms} {} +"
    return 0
  fi

  find -P "${path}" -xdev -type d -exec setfacl -m "${kind}:${name}:${dir_perms}" {} +
  find -P "${path}" -xdev -type d -exec setfacl -d -m "${kind}:${name}:${def_dir}" {} +
  find -P "${path}" -xdev -type f -exec setfacl -m "${kind}:${name}:${file_perms}" {} +
}

# Recursivo simple (rápido, menos fino)
apply_acl_tree_simple() {
  local subject="$1" perms_raw="$2" path="$3"
  local kind="${subject%%:*}" name="${subject#*:}"
  local perms
  perms="$(normalize_perms "$perms_raw")"

  run_cmd setfacl -R -m "${kind}:${name}:${perms}" "${path}"
  # Default ACL (solo en directorios): setfacl -R -d lo intenta sobre archivos también y puede avisar.
  # En SIMPLE_RECURSIVE aceptamos ese tradeoff.
  run_cmd setfacl -R -d -m "${kind}:${name}:${perms}" "${path}"
}

apply_deny_tree() {
  local subject="$1" path="$2"
  if [[ "${SIMPLE_RECURSIVE}" == "1" ]]; then
    apply_acl_tree_simple "${subject}" "---" "${path}"
  else
    apply_acl_tree_split "${subject}" "---" "---" "---" "${path}"
  fi
}

# Garantiza que el owner (user::) siempre tenga rwx y lo herede
ensure_owner_rwx() {
  local path="$1"
  run_cmd setfacl -m "user::rwx" "${path}"
  [[ -d "${path}" ]] && run_cmd setfacl -d -m "user::rwx" "${path}"
}

# -------------------------
# Parse INI
# -------------------------
declare -A GLOBAL
declare -a SPECIALTIES

declare -A PROFILE_base_project
declare -A PROFILE_base_wip
declare -A PROFILE_wip_full_control
declare -A PROFILE_write

parse_ini() {
  [[ -f "${INI_FILE}" ]] || die "INI no existe: ${INI_FILE}"

  local section=""
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line
    line="$(trim "$raw")"

    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^\; ]] && continue
    [[ "$line" =~ ^# ]] && continue

    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      section="$(trim "$section")"
      continue
    fi

    if [[ "$section" == "SPECIALTIES" ]]; then
      line="${line%%;*}"
      line="$(trim "$line")"
      [[ -z "$line" ]] && continue
      SPECIALTIES+=("$line")
      continue
    fi

    if [[ "$line" == *"="* ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      key="$(trim "$key")"
      val="$(trim "$val")"

      if [[ "$section" == "GLOBAL" ]]; then
        GLOBAL["$key"]="$val"
      else
        case "$key" in
          base_project)     PROFILE_base_project["$section"]="$val" ;;
          base_wip)         PROFILE_base_wip["$section"]="$val" ;;
          wip_full_control) PROFILE_wip_full_control["$section"]="$val" ;;
          write)            PROFILE_write["$section"]="$val" ;;
          *) : ;;
        esac
      fi
    fi
  done < "${INI_FILE}"
}

split_csv() {
  local csv="$1"
  local -n out="$2"
  out=()
  IFS=',' read -r -a out <<< "$csv"
  for i in "${!out[@]}"; do
    out[$i]="$(trim "${out[$i]}")"
  done
}

# -------------------------
# MAIN
# -------------------------
log_info "🚀 Iniciando apply_acls (DRY_RUN=${DRY_RUN}) INI=${INI_FILE} SIMPLE_RECURSIVE=${SIMPLE_RECURSIVE}"

command -v setfacl >/dev/null 2>&1 || die "setfacl no está instalado o no está en PATH"
command -v getent  >/dev/null 2>&1 || die "getent no está disponible"
command -v find    >/dev/null 2>&1 || die "find no está disponible"

parse_ini

ROOT="${GLOBAL[root]:-}"
PROJECT_GLOB="${GLOBAL[project_glob]:-*}"
WIP_FOLDER="${GLOBAL[wip_folder]:-01_WIP}"

BASE_ROOT_DEFAULT="${GLOBAL[base_root]:-rx}"
BASE_PROJECT_DEFAULT="${GLOBAL[base_project]:-rx}"
BASE_WIP_DEFAULT="${GLOBAL[base_wip]:-rx}"

WRITE_DIR="${GLOBAL[write_dir]:-rwx}"
WRITE_FILE="${GLOBAL[write_file]:-rw-}"
DEF_DIR="${GLOBAL[default_dir]:-${WRITE_DIR}}"

HIDE_NON_WRITE="${GLOBAL[hide_non_write]:-1}"

[[ -n "${ROOT}" ]] || die "GLOBAL.root no definido en INI"
[[ -d "${ROOT}" ]] || die "ROOT no existe o no es directorio: ${ROOT}"
[[ "${#SPECIALTIES[@]}" -gt 0 ]] || die "No hay SPECIALTIES en el INI"

EXPECTED_ROOT="/srv/samba/02_Proyectos"
[[ "${ROOT}" == "${EXPECTED_ROOT}" ]] || die "ROOT='${ROOT}' no coincide con EXPECTED_ROOT='${EXPECTED_ROOT}'. Abortando."

# Backup automático antes de tocar cualquier ACL (sobreescribe el anterior)
_backup_file="${REPO_DIR}/backups/acl_latest.facl"
mkdir -p "${REPO_DIR}/backups"
log_info "💾 Generando backup de ACLs en: ${_backup_file}"
[[ "${DRY_RUN}" == "1" ]] || getfacl -R --absolute-names "${ROOT}" > "${_backup_file}"
log_ok "💾 Backup listo: ${_backup_file}"
unset _backup_file

# Perfiles (secciones encontradas)
declare -a PROFILES
for p in \
  "${!PROFILE_base_project[@]}" \
  "${!PROFILE_base_wip[@]}" \
  "${!PROFILE_wip_full_control[@]}" \
  "${!PROFILE_write[@]}"
do
  PROFILES+=("$p")
done
mapfile -t PROFILES < <(printf "%s\n" "${PROFILES[@]}" | awk '!seen[$0]++' | sort)
[[ "${#PROFILES[@]}" -gt 0 ]] || die "No hay perfiles en el INI"

# Proyectos existentes
shopt -s nullglob
# shellcheck disable=SC2206
PROJECT_PATHS=( ${ROOT}/${PROJECT_GLOB} )
shopt -u nullglob
[[ "${#PROJECT_PATHS[@]}" -gt 0 ]] || die "No hay proyectos que matcheen: ${ROOT}/${PROJECT_GLOB}"

log_info "📁 Proyectos encontrados: ${#PROJECT_PATHS[@]}"
log_info "👥 Perfiles encontrados: ${#PROFILES[@]}"

APPLIED=0
SKIPPED_NO_WIP=0
SKIPPED_NO_SP=0

for profile in "${PROFILES[@]}"; do
  base_project="${PROFILE_base_project[$profile]:-${BASE_PROJECT_DEFAULT}}"
  base_wip="${PROFILE_base_wip[$profile]:-${BASE_WIP_DEFAULT}}"
  wip_full="${PROFILE_wip_full_control[$profile]:-}"
  write_csv="${PROFILE_write[$profile]:-}"

  subject="$(resolve_acl_subject "$profile")"
  warn_if_unknown_subject "$profile" "$subject"

  log_info "🧩 Perfil=${profile} subject=${subject} base_root=${BASE_ROOT_DEFAULT} base_project=${base_project} base_wip=${base_wip} wip_full=${wip_full:-N/A}"

  # base_root: listar proyectos en el root del share
  apply_acl_nonrec "$subject" "${BASE_ROOT_DEFAULT}" "$ROOT"
  ((++APPLIED))
  log_ok "📍 base_root: ${profile} ${BASE_ROOT_DEFAULT} ${ROOT}"

  # build write set
  unset -v is_write 2>/dev/null || true
  declare -A is_write
  if [[ -n "${write_csv}" ]]; then
    declare -a write_list
    split_csv "${write_csv}" write_list
    for sp in "${write_list[@]}"; do
      [[ -n "$sp" ]] && is_write["$sp"]=1
    done
  fi

  for proj_path in "${PROJECT_PATHS[@]}"; do
    [[ -d "$proj_path" ]] || continue
    wip_path="${proj_path}/${WIP_FOLDER}"

    # owner siempre rwx antes de cualquier otra ACL
    ensure_owner_rwx "$proj_path"

    # base_project: listar y entrar al proyecto
    apply_acl_nonrec "$subject" "$base_project" "$proj_path"
    ((++APPLIED))
    log_ok "📍 base_project: ${profile} ${base_project} ${proj_path}"

    # WIP existe?
    if [[ ! -d "$wip_path" ]]; then
      ((++SKIPPED_NO_WIP))
      log_warn "📁 WIP no existe (se omite): ${wip_path}"
      continue
    fi

    # owner siempre rwx antes de cualquier otra ACL
    ensure_owner_rwx "$wip_path"

    # base_wip: permitir entrar/listar WIP
    apply_acl_nonrec "$subject" "$base_wip" "$wip_path"
    ((++APPLIED))
    log_ok "🧷 base_wip: ${profile} ${base_wip} ${wip_path}"

    # BIM full control
    if [[ -n "$wip_full" ]]; then
      if [[ "${SIMPLE_RECURSIVE}" == "1" ]]; then
        apply_acl_tree_simple "$subject" "$wip_full" "$wip_path"
      else
        apply_acl_tree_split "$subject" "rwx" "rw-" "rwx" "$wip_path"
      fi
      ((++APPLIED))
      log_ok "🔓 wip_full_control: ${profile} ${wip_full} ${wip_path} (recursivo)"
      continue
    fi

    # Perfiles restringidos: write vs deny por especialidad
    for sp in "${SPECIALTIES[@]}"; do
      sp_path="${wip_path}/${sp}"
      [[ -e "$sp_path" ]] || { ((++SKIPPED_NO_SP)); continue; }

      ensure_owner_rwx "$sp_path"

      if [[ "${is_write[$sp]+x}" ]]; then
        if [[ "${SIMPLE_RECURSIVE}" == "1" ]]; then
          apply_acl_tree_simple "$subject" "rwx" "$sp_path"
        else
          apply_acl_tree_split "$subject" "${WRITE_DIR}" "${WRITE_FILE}" "${DEF_DIR}" "$sp_path"
        fi
        ((++APPLIED))
        log_ok "✍️ WRITE: ${profile} ${WRITE_DIR}/${WRITE_FILE} ${sp_path}"
      else
        if [[ "${HIDE_NON_WRITE}" == "1" ]]; then
          apply_deny_tree "$subject" "$sp_path"
          ((++APPLIED))
          log_ok "🙈 HIDDEN: ${profile} --- ${sp_path}"
        fi
      fi
    done
  done
done

# -------------------------
# Soporte: acceso total desde la raíz (siempre al final, pisa cualquier regla del loop)
# -------------------------
_soporte_subj="$(resolve_acl_subject "${SOPORTE_GROUP}")"
apply_acl_nonrec "${_soporte_subj}" "rwx" "${ROOT}"
for _proj in "${PROJECT_PATHS[@]}"; do
  [[ -d "${_proj}" ]] || continue
  apply_acl_tree_split "${_soporte_subj}" "rwx" "rw-" "rwx" "${_proj}"
done
log_ok "🔑 soporte (${_soporte_subj}): rwx aplicado sobre ${ROOT} y ${#PROJECT_PATHS[@]} proyecto(s)"
unset _soporte_subj _proj

log_ok "📊 Resumen: APPLIED=${APPLIED} SKIPPED_NO_WIP=${SKIPPED_NO_WIP} SKIPPED_NO_SPECIALTY_PATH=${SKIPPED_NO_SP}"
log_info "🏁 apply_acls finalizado"
