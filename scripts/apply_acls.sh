#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Config base
INI_FILE="${INI_FILE:-${REPO_DIR}/config/acl_matrix.ini}"
LOG_DIR="${REPO_DIR}/logs"
LOG_FILE="${LOG_DIR}/apply_acls.log"
mkdir -p "${LOG_DIR}"

DRY_RUN="${DRY_RUN:-0}"
DEFAULT_ON_NONRECURSIVE_DIRS="${DEFAULT_ON_NONRECURSIVE_DIRS:-1}"

ts() { date -Is; }
log_info() { echo "[INFO] $(ts) $*" | tee -a "${LOG_FILE}"; }
log_warn() { echo "[WARN] $(ts) $*" | tee -a "${LOG_FILE}"; }
log_err()  { echo "[ERROR] $(ts) $*" | tee -a "${LOG_FILE}"; }
log_ok()   { echo "[OK] $(ts) $*" | tee -a "${LOG_FILE}"; }
die() { log_err "$*"; exit 1; }

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# --- u: vs g: ---
resolve_acl_subject() {
  local raw="$1"
  local kind="u"
  local name="$raw"

  if [[ "$raw" =~ ^[ug]: ]]; then
    kind="${raw%%:*}"
    name="${raw#*:}"
    printf "%s:%s" "$kind" "$name"
    return 0
  fi

  if getent group "$raw" >/dev/null 2>&1; then
    kind="g"
  elif getent passwd "$raw" >/dev/null 2>&1; then
    kind="u"
  else
    kind="u"
  fi

  printf "%s:%s" "$kind" "$raw"
}

warn_if_unknown_subject() {
  local raw="$1"
  local subj="$2"
  local name="${subj#*:}"
  if ! getent passwd "${name}" >/dev/null 2>&1 && ! getent group "${name}" >/dev/null 2>&1; then
    log_warn "Usuario/Grupo '${raw}' no existe en el sistema (getent). Se intentará aplicar igual (Samba/LDAP/AD podrían resolverlo)."
  fi
}

apply_acl_one() {
  local subject="$1"    # u:NAME o g:NAME
  local perms="$2"      # rwx, r-x, rx, etc.
  local abs_path="$3"
  local recursive="$4"  # true/false

  local kind="${subject%%:*}"
  local name="${subject#*:}"

  if [[ "${recursive}" == "true" ]]; then
    run_cmd setfacl -R -m "${kind}:${name}:${perms}" "${abs_path}"
    run_cmd setfacl -R -d -m "${kind}:${name}:${perms}" "${abs_path}"
  else
    run_cmd setfacl -m "${kind}:${name}:${perms}" "${abs_path}"
    if [[ -d "${abs_path}" && "${DEFAULT_ON_NONRECURSIVE_DIRS}" == "1" ]]; then
      run_cmd setfacl -d -m "${kind}:${name}:${perms}" "${abs_path}"
    fi
  fi
}

# --- Parse INI (simple, suficiente para tu formato) ---
# Lee secciones [GLOBAL], [SPECIALTIES], y perfiles [IND_*]
declare -A GLOBAL
declare -a SPECIALTIES
declare -A PROFILE_base_project
declare -A PROFILE_base_wip
declare -A PROFILE_wip_full_control
declare -A PROFILE_write
declare -A PROFILE_read

parse_ini() {
  [[ -f "${INI_FILE}" ]] || die "INI no existe: ${INI_FILE}"

  local section=""
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line="$(trim "$raw")"

    # comentarios / vacías
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^\; ]] && continue
    [[ "$line" =~ ^# ]] && continue

    # sección
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    # SPECIALTIES: una por línea
    if [[ "$section" == "SPECIALTIES" ]]; then
      SPECIALTIES+=("$line")
      continue
    fi

    # key=value
    if [[ "$line" == *"="* ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      key="$(trim "$key")"
      val="$(trim "$val")"

      if [[ "$section" == "GLOBAL" ]]; then
        GLOBAL["$key"]="$val"
      else
        # perfil
        case "$key" in
          base_project) PROFILE_base_project["$section"]="$val" ;;
          base_wip) PROFILE_base_wip["$section"]="$val" ;;
          wip_full_control) PROFILE_wip_full_control["$section"]="$val" ;;
          write) PROFILE_write["$section"]="$val" ;;
          read) PROFILE_read["$section"]="$val" ;;
          *) : ;; # ignora llaves no soportadas
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
  # trim de cada item
  for i in "${!out[@]}"; do
    out[$i]="$(trim "${out[$i]}")"
  done
}

# --- Main ---
log_info "Iniciando apply_acls (DRY_RUN=${DRY_RUN}) INI=${INI_FILE}"

parse_ini

ROOT="${GLOBAL[root]:-}"
PROJECT_GLOB="${GLOBAL[project_glob]:-*}"
WIP_FOLDER="${GLOBAL[wip_folder]:-01_WIP}"

[[ -n "${ROOT}" ]] || die "GLOBAL.root no definido en INI"
[[ -d "${ROOT}" ]] || die "ROOT no existe o no es directorio: ${ROOT}"
[[ "${#SPECIALTIES[@]}" -gt 0 ]] || die "No hay SPECIALTIES en el INI"

# Detectar perfiles: toda key en PROFILE_* (base_project o write o wip_full_control)
declare -a PROFILES
for p in "${!PROFILE_base_project[@]}" "${!PROFILE_wip_full_control[@]}" "${!PROFILE_write[@]}"; do
  PROFILES+=("$p")
done
# uniq
mapfile -t PROFILES < <(printf "%s\n" "${PROFILES[@]}" | awk '!seen[$0]++' | sort)

[[ "${#PROFILES[@]}" -gt 0 ]] || die "No hay perfiles en el INI (secciones tipo [IND_*])"

# Expandir proyectos existentes
shopt -s nullglob
# shellcheck disable=SC2206
PROJECT_PATHS=( ${ROOT}/${PROJECT_GLOB} )
shopt -u nullglob

if [[ "${#PROJECT_PATHS[@]}" -eq 0 ]]; then
  die "No hay proyectos que matcheen: ${ROOT}/${PROJECT_GLOB}"
fi

log_info "Proyectos encontrados: ${#PROJECT_PATHS[@]}"

for profile in "${PROFILES[@]}"; do
  local_base_project="${PROFILE_base_project[$profile]:-${GLOBAL[base_project]:-rx}}"
  local_base_wip="${PROFILE_base_wip[$profile]:-${GLOBAL[base_wip]:-rx}}"
  local_wip_full="${PROFILE_wip_full_control[$profile]:-}"
  local_write="${PROFILE_write[$profile]:-}"
  local_read="${PROFILE_read[$profile]:-}"

  subject="$(resolve_acl_subject "$profile")"
  warn_if_unknown_subject "$profile" "$subject"

  log_info "Perfil=${profile} subject=${subject} base_project=${local_base_project} base_wip=${local_base_wip} wip_full=${local_wip_full:-N/A} read=${local_read:-N/A} write=${local_write:-N/A}"

  # Construir sets de especialidades write/read
  declare -A is_write
  if [[ -n "$local_write" ]]; then
    declare -a write_list
    split_csv "$local_write" write_list
    for sp in "${write_list[@]}"; do
      [[ -n "$sp" ]] && is_write["$sp"]=1
    done
  fi

  # Recorre proyectos
  for proj_path in "${PROJECT_PATHS[@]}"; do
    [[ -d "$proj_path" ]] || continue
    proj_name="$(basename "$proj_path")"

    # base_project sobre el proyecto (no recursivo)
    apply_acl_one "$subject" "$local_base_project" "$proj_path" "false"
    log_ok "Aplicado base_project: ${profile} ${local_base_project} ${proj_path}"

    wip_path="${proj_path}/${WIP_FOLDER}"
    if [[ ! -d "$wip_path" ]]; then
      log_warn "WIP no existe (se omite): ${wip_path}"
      continue
    fi

    # base_wip sobre el WIP (no recursivo)
    apply_acl_one "$subject" "$local_base_wip" "$wip_path" "false"
    log_ok "Aplicado base_wip: ${profile} ${local_base_wip} ${wip_path}"

    # Si tiene full control de WIP, aplica y sigue
    if [[ -n "$local_wip_full" ]]; then
      apply_acl_one "$subject" "$local_wip_full" "$wip_path" "true"
      log_ok "Aplicado wip_full_control: ${profile} ${local_wip_full} ${wip_path} (recursivo)"
      continue
    fi

    # Si no hay full control, aplica por especialidad según matriz
    for sp in "${SPECIALTIES[@]}"; do
      sp_path="${wip_path}/${sp}"
      [[ -e "$sp_path" ]] || continue

      if [[ "${is_write[$sp]+x}" ]]; then
        # write => rwx recursivo
        apply_acl_one "$subject" "rwx" "$sp_path" "true"
        log_ok "Aplicado WRITE: ${profile} rwx ${sp_path}"
      else
        # read: si dice ALL_EXCEPT_WRITE, entonces r-x a todo lo demás
        if [[ "$local_read" == "ALL_EXCEPT_WRITE" ]]; then
          apply_acl_one "$subject" "r-x" "$sp_path" "true"
          log_ok "Aplicado READ: ${profile} r-x ${sp_path}"
        elif [[ -n "$local_read" ]]; then
          # si algún día defines CSV de lectura explícita, lo puedes extender aquí
          :
        fi
      fi
    done
  done
done

log_info "apply_acls finalizado"
