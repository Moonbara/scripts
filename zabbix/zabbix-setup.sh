#!/usr/bin/env bash
# =============================================================================
#  zabbix-setup.sh - server-side automation of zabbix-3tier-setup-guide.md
#  Zabbix 8.0 LTS | Ubuntu 26.04 | MySQL 8 | Apache + PHP 8.5-FPM | Agent 2
# -----------------------------------------------------------------------------
#  Copy this same file to every server and run it there with sudo:
#
#    menu 1 / --mode single   Zabbix + MySQL on this VM          (Part 1 + 2)
#    menu 2 / --mode db       two VMs: this is the DATABASE node (Part 1) FIRST
#    menu 3 / --mode app      two VMs: this is the APP/WEB node  (Part 2) SECOND
#
#  Part 3 (the Windows 11 agent) is NOT automated. The run ends with a
#  NEXT STEPS block holding the exact values to type on Windows and in the UI.
#
#  Step numbers printed by the script (and by --dry-run) are the guide's
#  Part.Step numbers, so the output doubles as a revision sheet. Work the guide
#  does not contain is marked:
#    Part 0       preparation: 0.1 preflight, 0.2 admin user, 0.3 static IP,
#                 0.4 time sync + timezone
#    2.5a / 2.7a  extra sub-steps: PHP timezone, firewall for web + agents
#
#  Map of this file:
#     0. constants and defaults        6. Part 0 (steps 0.2 - 0.4)
#     1. output, logging, run()        7. Part 1 - database node (1.1 - 1.5)
#     2. validators and prompts        8. Part 2 - app/web node  (2.1 - 2.9)
#     3. config-file editing           9. hand-off, NEXT STEPS, state file
#     4. system and MySQL helpers     10. --verify
#     5. inputs and preflight (0.1)   11. main
# =============================================================================
set -Eeuo pipefail
umask 022

# =============================================================================
# 0. Constants and defaults - the only place versions, ports and paths live
# =============================================================================
readonly SCRIPT_VERSION="1.0.0"
readonly ZBX_VERSION="8.0"
readonly TARGET_UBUNTU="26.04"
readonly ZBX_REPO_BASE="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/release/ubuntu"
readonly -a ZBX_PACKAGES=(zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2)
readonly -a APACHE_MODS=(proxy proxy_fcgi proxy_http rewrite)
readonly DEFAULT_PHP_FPM="php8.5-fpm"
readonly ZBX_LOCALE="en_US.UTF-8"

readonly DEFAULT_DB_PORT=8090
readonly DEFAULT_DB_NAME="zabbix"
readonly DEFAULT_DB_USER="zabbix"
readonly DEFAULT_TIMEZONE="America/Toronto"
readonly MYSQL_DEFAULT_PORT=3306
readonly HTTP_PORT=80
readonly ZBX_TRAPPER_PORT=10051      # zabbix-server: active checks from agents
readonly ZBX_AGENT_PORT=10050        # agent: passive checks (Windows side)
readonly MIN_DISK_GB=5
readonly MIN_RAM_MB=2048
readonly PW_GEN_LEN=20
readonly PW_MIN_LEN=8
readonly PW_MAX_LEN=128
readonly NETPLAN_TRY_TIMEOUT=120

readonly LOG_FILE="/var/log/zabbix-setup.log"
readonly STATE_FILE="/etc/zabbix-setup.state"
readonly BACKUP_ROOT="/var/backups/zabbix-setup"
readonly MYSQLD_CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"
readonly ZBX_SERVER_CONF="/etc/zabbix/zabbix_server.conf"
readonly ZBX_SERVER_LOG="/var/log/zabbix/zabbix_server.log"
readonly ZBX_APACHE_CONF="/etc/zabbix/apache.conf"
readonly ZBX_PHP_POOL_GUESS="/etc/zabbix/php-fpm.conf"
readonly NETPLAN_DIR="/etc/netplan"
readonly NETPLAN_FILE="${NETPLAN_DIR}/99-zabbix-static.yaml"
readonly LOCALE_GEN="/etc/locale.gen"
# Zabbix 8.0 packages ship the schema under /usr/share/zabbix/sql-scripts
# (the older /usr/share/zabbix-sql-scripts path is kept as a fallback).
readonly -a SCHEMA_CANDIDATES=(/usr/share/zabbix/sql-scripts/mysql/server.sql.gz /usr/share/zabbix-sql-scripts/mysql/server.sql.gz)
readonly WIN_AGENT_DIR='C:\Program Files\Zabbix Agent 2'
readonly MASK='********'
readonly US=$'\x1f'                  # field separator for result tables

RUN_TS=$(date +%Y%m%d-%H%M%S)
readonly RUN_TS
readonly BACKUP_DIR="${BACKUP_ROOT}/${RUN_TS}"
OUT_DIR=$PWD
readonly OUT_DIR
readonly HANDOFF_FILE="${OUT_DIR}/zabbix-handoff.txt"
readonly NEXT_STEPS_FILE="${OUT_DIR}/zabbix-next-steps.txt"
readonly MANUAL_STEPS_FILE="${OUT_DIR}/zabbix-manual-steps.txt"

# --- Run options (set by flags) ---------------------------------------------
DRY_RUN=false; DO_VERIFY=false; RESET=false; FORCE=false; ASSUME_YES=false
SHOW_HELP=false; ADD_USER=""; PW_FILE=""; ARGS_TEXT=""

# --- Inputs: every one can come from a flag, an environment variable or a
#     prompt (in that priority). SRC[VAR] remembers where a value came from.
declare -A SRC=()
readonly -a INPUT_VARS=(MODE APP_IP DB_IP DB_PORT DB_NAME DB_USER TIMEZONE WIN_HOSTNAME WIN_IP
                        IFACE STATIC_IP PREFIX GATEWAY DNS SSH_KEY_FILE)
for _v in "${INPUT_VARS[@]}"; do
  if [[ -n ${!_v:-} ]]; then SRC[$_v]="environment"; else printf -v "$_v" '%s' ""; fi
done
unset _v
# The password is never a flag. From the environment it is read once and then
# un-exported so apt, mysql and other children never inherit it.
PW_ORIGIN=""
if [[ -n ${DB_PASSWORD:-} ]]; then PW_ORIGIN="environment"; else DB_PASSWORD=""; fi
export -n DB_PASSWORD 2>/dev/null || true

# --- Run state ----------------------------------------------------------------
NET_ACTION=""            # keep | configure | skip  (step 0.3)
HOST_IP=""               # this machine's address after step 0.3 decisions
DET_IFACE=""; DET_IP=""; DET_PREFIX=""; DET_GW=""; DET_DNS=""; DET_DYNAMIC="unknown"
USER_EXISTS=false        # MySQL account already there (re-run)
PW_KEEP=false            # keep the existing MySQL password (re-run)
SINGLE_CUSTOM_PORT=false # single mode: TCP port instead of the default socket
TRUST_PENDING=false      # app mode: trust flag must still be reset on the DB node
PHP_FPM=$DEFAULT_PHP_FPM
SCHEMA_FILE=${SCHEMA_CANDIDATES[0]}
OS_ID=""; OS_VER=""
CUR_STEP="0"; ACTION_N=0
APT_FRESH=false
FW_CHANGED=(); FW_SKIPPED=()
V_ROWS=(); V_FAILS=0; V_WARNS=0
PF_HINTS=()
CNF=""; DBC_ARGS=()
ST_MODE=""; ST_APP_IP=""; ST_DB_IP=""; ST_DB_PORT=""; ST_DB_NAME=""; ST_DB_USER=""; ST_TIMEZONE=""

# =============================================================================
# 1. Output, logging and the run() wrapper
#    Everything shown goes to the terminal and, with a timestamp, to
#    /var/log/zabbix-setup.log. --dry-run writes to zabbix-manual-steps.txt
#    instead. Secrets never pass through these functions unmasked.
# =============================================================================
if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'; C_OFF=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_OFF=""
fi
LOG_ON=false
MANUAL_FILE=""
TMP_PATHS=()

_record() {   # plain line -> log (timestamped) and/or the dry-run manual file
  if [[ $LOG_ON == true ]]; then printf '[%(%F %T)T] %s\n' -1 "$1" >>"$LOG_FILE"; fi
  if [[ -n $MANUAL_FILE ]]; then printf '%s\n' "$1" >>"$MANUAL_FILE"; fi
}
_emit() { local color=$1; shift; printf '%s%s%s\n' "$color" "$*" "${color:+$C_OFF}"; _record "$*"; }
say()   { _emit "" "$*"; }
info()  { _emit "$C_CYAN" "      $*"; }
ok()    { _emit "$C_GREEN" "      OK: $*"; }
warn()  { _emit "$C_YELLOW" "      WARNING: $*"; }
skip()  { _emit "" "      skipped: $*"; }
err()   { local l; for l in "$@"; do _emit "$C_RED" "ERROR: $l" >&2; done; }
die()   { err "$@"; exit 1; }

part() { say ""; _emit "$C_BOLD" "==================== $* ===================="; }

step() {      # step NUMBER TITLE - numbers follow the guide
  CUR_STEP=$1; ACTION_N=0
  local t=""
  if [[ $DRY_RUN != true ]]; then t=$(printf '   [%(%H:%M:%S)T]' -1); fi
  say ""
  _emit "$C_BOLD" "--- Step $1: $2$t"
}

_action() {   # numbered action line ([1.2.3]) plus optional detail lines
  ACTION_N=$((ACTION_N + 1))
  say "  [${CUR_STEP}.${ACTION_N}] $1"
  shift
  local l
  for l in "$@"; do say "          $l"; done
}

_q() { local out="" a; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s' "${out% }"; }
_logpipe() { if [[ $LOG_ON == true ]]; then tee -a "$LOG_FILE"; else cat; fi; }

# run CMD...                 show "$ sudo CMD" and run it (output logged)
# run_show "TEXT" CMD...     show TEXT (the manual equivalent) and run CMD
# In --dry-run both only print. Note: CMD runs in a pipeline subshell, so it
# cannot set variables in the caller.
run() { run_show "sudo $(_q "$@")" "$@"; }
run_show() {
  local shown=$1 rc=0; shift
  _action "\$ $shown"
  if [[ $DRY_RUN == true ]]; then return 0; fi
  "$@" 2>&1 | _logpipe || rc=$?
  if ((rc != 0)); then err "command failed (exit ${rc}): ${shown}"; fi
  return "$rc"
}

cleanup() {
  local p
  for p in "${TMP_PATHS[@]}"; do [[ -n $p ]] && rm -rf -- "$p"; done
  return 0
}
trap cleanup EXIT

on_err() {
  local rc=$1 line=$2 cmd=$3
  if [[ $BASHPID != "$$" ]]; then exit "$rc"; fi   # subshell: parent reports
  trap - ERR
  err "Step ${CUR_STEP} failed (exit ${rc}, line ${line}): ${cmd}"
  if [[ $LOG_ON == true ]]; then err "Full output: ${LOG_FILE}"; fi
  err "Fix the cause and run the script again - it is safe to re-run."
  exit "$rc"
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

# =============================================================================
# 2. Validators and prompts
#    Validators return 0/1 and leave the reason in VERR.
# =============================================================================
VERR=""
v_mode()   { case $1 in single|db|app) return 0 ;; esac; VERR="mode must be single, db or app"; return 1; }
v_ip() {
  local ip=$1 o re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
  if [[ ! $ip =~ $re ]]; then VERR="'${ip}' is not an IPv4 address (format a.b.c.d)"; return 1; fi
  for o in "${BASH_REMATCH[@]:1}"; do
    if ((10#$o > 255)); then VERR="'${ip}': ${o} is larger than 255"; return 1; fi
  done
  if [[ $ip == 0.* || $ip == 127.* || $ip == 255.255.255.255 ]]; then VERR="'${ip}' is not a usable host address"; return 1; fi
  return 0
}
v_ip_opt() { [[ -z $1 ]] || v_ip "$1"; }
v_port() {
  if [[ $1 =~ ^[1-9][0-9]{3,4}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); then return 0; fi
  VERR="port must be a number from 1024 to 65535"; return 1
}
v_dbname() { [[ $1 =~ ^[A-Za-z0-9_]{1,64}$ ]] && return 0; VERR="use only letters, digits and _ (max 64)"; return 1; }
v_dbuser() { [[ $1 =~ ^[A-Za-z0-9_]{1,32}$ ]] && return 0; VERR="use only letters, digits and _ (max 32)"; return 1; }
v_winhost() {
  [[ -z $1 || $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] && return 0
  VERR="host name: letters, digits, . _ - (max 63), must start with a letter or digit"; return 1
}
v_iface()  { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,14}$ ]] && return 0; VERR="not a valid interface name"; return 1; }
v_prefix() { [[ $1 =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] && return 0; VERR="prefix must be 1-32 (e.g. 24)"; return 1; }
v_dns() {
  local -a list; local d
  IFS=', ' read -r -a list <<<"$1"
  ((${#list[@]} >= 1 && ${#list[@]} <= 3)) || { VERR="give 1-3 DNS server IPs, comma-separated"; return 1; }
  for d in "${list[@]}"; do v_ip "$d" || return 1; done
  return 0
}
v_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && return 0; VERR="lowercase letters, digits, _ and - (max 32)"; return 1; }
TZ_LIST=""
v_tz() {
  local tz=$1
  if [[ -z $tz ]]; then VERR="timezone is empty"; return 1; fi
  if [[ -z $TZ_LIST ]] && command -v timedatectl >/dev/null 2>&1; then
    TZ_LIST=$(timedatectl list-timezones 2>/dev/null || true)
  fi
  if [[ -n $TZ_LIST ]]; then
    grep -Fxq -- "$tz" <<<"$TZ_LIST" && return 0
    VERR="'${tz}' is not in 'timedatectl list-timezones' (e.g. ${DEFAULT_TIMEZONE}, Europe/London, UTC)"; return 1
  fi
  [[ $tz =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$ ]] && return 0
  VERR="'${tz}' does not look like a timezone (e.g. ${DEFAULT_TIMEZONE})"; return 1
}
# Passwords: any printable character is accepted (SQL, the MySQL option file
# and zabbix_server.conf are all written safely). Two things cannot work:
#  - control characters / newlines (config files are line based)
#  - leading/trailing spaces (Zabbix trims them when it reads DBPassword=)
v_password() {
  local p=$1
  if ((${#p} < PW_MIN_LEN)); then VERR="at least ${PW_MIN_LEN} characters"; return 1; fi
  if ((${#p} > PW_MAX_LEN)); then VERR="at most ${PW_MAX_LEN} characters"; return 1; fi
  if [[ $p == *[[:cntrl:]]* ]]; then VERR="control characters (tab, newline...) are not supported"; return 1; fi
  if [[ $p =~ ^[[:space:]] || $p =~ [[:space:]]$ ]]; then
    VERR="no space at the start or end (zabbix_server.conf trims it); spaces inside are fine"; return 1
  fi
  return 0
}

# ask VAR "Question" "default" validator
# Priority: flag > environment > prompt. --yes takes the default.
ask() {
  local var=$1 q=$2 def=$3 vfn=$4 cur=${!1:-} src=${SRC[$1]:-} ans hint
  if [[ -n $src ]]; then
    if "$vfn" "$cur"; then say "  ${q} ${cur}   (from ${src})"; return 0; fi
    warn "${var}='${cur}' from ${src} is invalid: ${VERR}"
    [[ $ASSUME_YES == true ]] && die "Fix the ${src} value for ${var} and re-run."
  elif [[ $ASSUME_YES == true ]]; then
    if "$vfn" "$def"; then printf -v "$var" '%s' "$def"; say "  ${q} ${def:-<blank>}   (default, --yes)"; return 0; fi
    die "${q} has no usable default (${VERR}). Pass it as a flag or environment variable (see --help)."
  fi
  if [[ -n $def ]]; then hint="[${def}]"; else hint="(Enter = leave blank)"; fi
  while true; do
    IFS= read -r -p "  ${q} ${hint}: " ans || die "Input ended while asking: ${q}"
    ans=${ans#"${ans%%[![:space:]]*}"}; ans=${ans%"${ans##*[![:space:]]}"}
    ans=${ans:-$def}
    if "$vfn" "$ans"; then printf -v "$var" '%s' "$ans"; _record "  ${q} ${ans}"; return 0; fi
    warn "${VERR} - try again."
  done
}

# ask_yn "Question" y|n  -> 0 for yes. --yes answers with the default.
ask_yn() {
  local q=$1 def=$2 ans hint="[y/N]"
  [[ $def == y ]] && hint="[Y/n]"
  if [[ $ASSUME_YES == true ]]; then say "  ${q} ${hint} ${def}   (default, --yes)"; [[ $def == y ]]; return; fi
  while true; do
    read -r -p "  ${q} ${hint} " ans || die "Input ended while asking: ${q}"
    ans=${ans:-$def}
    case ${ans,,} in
      y|yes) _record "  ${q} -> yes"; return 0 ;;
      n|no)  _record "  ${q} -> no"; return 1 ;;
    esac
    warn "Please answer y or n."
  done
}

read_hidden() {   # read_hidden VAR "prompt" - no echo, never logged
  local __v
  IFS= read -r -s -p "$2" __v || die "Input ended while reading a password."
  printf '\n' >&2
  printf -v "$1" '%s' "$__v"
}

# =============================================================================
# 3. Config-file editing (pure bash: values never go through sed, so any
#    character in a password survives). Every edit is preceded by a backup.
# =============================================================================

# backup_file PATH - cp -a into /var/backups/zabbix-setup/<timestamp>/<PATH>
backup_file() {
  local f=$1 dest="${BACKUP_DIR}$1"
  if [[ $DRY_RUN != true ]]; then
    [[ -e $f ]] || return 0
    [[ -e $dest ]] && return 0        # already backed up during this run
  fi
  _action "\$ sudo mkdir -p ${dest%/*} && sudo cp -a ${f} ${dest}"
  if [[ $DRY_RUN == true ]]; then return 0; fi
  mkdir -p "${dest%/*}"
  cp -a -- "$f" "$dest"
  info "backup: ${dest}"
}

# Rewrite FILE with the given lines while keeping its inode, owner and mode.
_write_lines() {
  local file=$1 tmp; shift
  tmp=$(mktemp); TMP_PATHS+=("$tmp")
  printf '%s\n' "$@" >"$tmp"
  if [[ -e $file ]]; then cat "$tmp" >"$file"; else cp "$tmp" "$file"; fi
  rm -f "$tmp"
}

# kv_set FILE SECTION KEY VALUE STYLE
#  STYLE ini   -> "key = value"   (mysqld.cnf, php-fpm pool, php.ini)
#  STYLE plain -> "Key=value"     (zabbix_server.conf; SECTION is "")
# Replaces the active KEY line inside SECTION; otherwise inserts after a
# commented example ("# key = ...") or after the section header; otherwise
# appends. Duplicate active lines are removed, so re-runs never stack lines.
# For keys, '-' and '_' are treated alike (bind-address == bind_address).
kv_set() {
  local file=$1 section=$2 key=$3 value=$4 style=$5
  local want=${3//-/_} newline cur="" k i l
  local -a lines=() out=()
  local -A drop=()
  local active=-1 commented=-1 header=-1 inserted=false
  local re_sec='^[[:space:]]*\[([^]]+)\][[:space:]]*$'
  local re_act='^[[:space:]]*([^#;[:space:]=][^=]*)='
  local re_com='^[[:space:]]*[#;]+[[:space:]]*([^#;[:space:]=][^=]*)='
  if [[ $style == ini ]]; then newline="${key} = ${value}"; else newline="${key}=${value}"; fi
  if [[ -f $file ]]; then mapfile -t lines <"$file"; fi
  for i in "${!lines[@]}"; do
    l=${lines[i]}
    if [[ $l =~ $re_sec ]]; then
      cur=${BASH_REMATCH[1]}
      if [[ $cur == "$section" ]]; then header=$i; fi
      continue
    fi
    [[ $cur == "$section" ]] || continue
    if [[ $l =~ $re_act ]]; then
      k=${BASH_REMATCH[1]}; k=${k%"${k##*[![:space:]]}"}; k=${k//-/_}
      if [[ $k == "$want" ]]; then
        if ((active < 0)); then active=$i; else drop[$i]=1; fi
      fi
    elif ((commented < 0)) && [[ $l =~ $re_com ]]; then
      k=${BASH_REMATCH[1]}; k=${k%"${k##*[![:space:]]}"}; k=${k//-/_}
      if [[ $k == "$want" ]]; then commented=$i; fi
    fi
  done
  for i in "${!lines[@]}"; do
    [[ -n ${drop[$i]:-} ]] && continue
    if ((i == active)); then out+=("$newline"); inserted=true; continue; fi
    out+=("${lines[i]}")
    if ((active < 0)) && [[ $inserted == false ]]; then
      if ((commented >= 0 && i == commented)) || ((commented < 0 && header >= 0 && i == header)); then
        out+=("$newline"); inserted=true
      fi
    fi
  done
  if [[ $inserted == false ]]; then
    if [[ -n $section ]] && ((header < 0)); then out+=("" "[${section}]"); fi
    out+=("$newline")
  fi
  _write_lines "$file" "${out[@]}"
}

# kv_get FILE SECTION KEY -> prints the value of the last active KEY line.
kv_get() {
  local file=$1 section=$2 want=${3//-/_} cur="" k l v found=false val=""
  local re_sec='^[[:space:]]*\[([^]]+)\][[:space:]]*$'
  local re_act='^[[:space:]]*([^#;[:space:]=][^=]*)='
  [[ -r $file ]] || return 1
  while IFS= read -r l || [[ -n $l ]]; do
    if [[ $l =~ $re_sec ]]; then cur=${BASH_REMATCH[1]}; continue; fi
    [[ $cur == "$section" ]] || continue
    if [[ $l =~ $re_act ]]; then
      k=${BASH_REMATCH[1]}; k=${k%"${k##*[![:space:]]}"}; k=${k//-/_}
      if [[ $k == "$want" ]]; then
        v=${l#*=}; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
        val=$v; found=true
      fi
    fi
  done <"$file"
  [[ $found == true ]] || return 1
  printf '%s' "$val"
}

# kv_comment FILE SECTION KEY - comment out active KEY lines ("# KEY=...").
kv_comment() {
  local file=$1 section=$2 want=${3//-/_} cur="" k l
  local -a out=()
  local re_sec='^[[:space:]]*\[([^]]+)\][[:space:]]*$'
  local re_act='^[[:space:]]*([^#;[:space:]=][^=]*)='
  [[ -f $file ]] || return 0
  while IFS= read -r l || [[ -n $l ]]; do
    if [[ $l =~ $re_sec ]]; then cur=${BASH_REMATCH[1]}
    elif [[ $cur == "$section" && $l =~ $re_act ]]; then
      k=${BASH_REMATCH[1]}; k=${k%"${k##*[![:space:]]}"}; k=${k//-/_}
      if [[ $k == "$want" ]]; then l="# ${l}"; fi
    fi
    out+=("$l")
  done <"$file"
  _write_lines "$file" "${out[@]}"
}

# edit_kv [--secret] FILE SECTION KEY VALUE STYLE - show, then apply.
edit_kv() {
  local secret=false
  if [[ $1 == --secret ]]; then secret=true; shift; fi
  local file=$1 section=$2 key=$3 value=$4 style=$5 shown=$4 where="" sep="="
  if [[ $secret == true ]]; then shown=$MASK; fi
  if [[ -n $section ]]; then where=" under [${section}]"; fi
  if [[ $style == ini ]]; then sep=" = "; fi
  _action "edit ${file}${where}:  ${key}${sep}${shown}"
  if [[ $DRY_RUN == true ]]; then return 0; fi
  kv_set "$file" "$section" "$key" "$value" "$style"
}

# write_private PATH < content - atomically, mode 600, owned by the sudo user
write_private() {
  local path=$1 tmp
  tmp=$(mktemp "${path%/*}/.zbxsetup.XXXXXX")
  chmod 600 "$tmp"
  cat >"$tmp"
  mv -f -- "$tmp" "$path"
  give_to_sudo_user "$path"
}
give_to_sudo_user() {
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then chown "${SUDO_USER}:" "$1" 2>/dev/null || true; fi
  return 0
}

# =============================================================================
# 4. System and MySQL helpers
# =============================================================================
pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == "install ok installed" ]]; }
svc_active()    { systemctl is-active --quiet "$1" 2>/dev/null; }

ufw_state() {     # prints active | inactive | absent  (never enables ufw)
  if ! command -v ufw >/dev/null 2>&1; then echo absent; return 0; fi
  local out; out=$(ufw status 2>/dev/null || true)
  if [[ $out == *"Status: active"* ]]; then echo active; else echo inactive; fi
}

read_os() {
  OS_ID=""; OS_VER=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_ID=$(. /etc/os-release && printf '%s' "${ID:-}")
    # shellcheck disable=SC1091
    OS_VER=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  fi
  return 0
}

local_ipv4s() {
  command -v ip >/dev/null 2>&1 || return 0
  local line re='inet ([0-9.]+)/'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
  done < <(ip -o -4 addr show 2>/dev/null || true)
  return 0
}
is_local_ip() { local a; for a in $(local_ipv4s); do [[ $a == "$1" ]] && return 0; done; return 1; }

# net_detect: interface, address/prefix, gateway, DNS and whether the address
# is a DHCP lease ("dynamic" flag in `ip addr`).
net_detect() {
  DET_IFACE=""; DET_IP=""; DET_PREFIX=""; DET_GW=""; DET_DNS=""; DET_DYNAMIC="unknown"
  command -v ip >/dev/null 2>&1 || return 0
  local line out w re_via='via ([0-9.]+)' re_dev='dev ([^ ]+)' re_inet='inet ([0-9.]+)/([0-9]+)'
  local -a dns=() words=()
  line=$(ip -4 route show default 2>/dev/null || true); line=${line%%$'\n'*}
  if [[ $line =~ $re_via ]]; then DET_GW=${BASH_REMATCH[1]}; fi
  if [[ $line =~ $re_dev ]]; then DET_IFACE=${BASH_REMATCH[1]}; fi
  if [[ -z $DET_IFACE ]]; then
    line=$(ip -o -4 addr show scope global 2>/dev/null || true); line=${line%%$'\n'*}
    read -r -a words <<<"$line"
    if ((${#words[@]} > 1)); then DET_IFACE=${words[1]}; fi
  fi
  [[ -n $DET_IFACE ]] || return 0
  line=$(ip -o -4 addr show dev "$DET_IFACE" scope global 2>/dev/null || true); line=${line%%$'\n'*}
  if [[ $line =~ $re_inet ]]; then DET_IP=${BASH_REMATCH[1]}; DET_PREFIX=${BASH_REMATCH[2]}; fi
  if [[ -n $line ]]; then
    if [[ $line == *" dynamic"* ]]; then DET_DYNAMIC=yes; else DET_DYNAMIC=no; fi
  fi
  if command -v resolvectl >/dev/null 2>&1; then
    out=$(resolvectl dns "$DET_IFACE" 2>/dev/null || true); out=${out#*:}
    read -r -a words <<<"$out"
    for w in "${words[@]}"; do v_ip "$w" && dns+=("$w"); done
  fi
  if ((${#dns[@]} == 0)) && [[ -r /run/systemd/resolve/resolv.conf ]]; then
    while read -r -a words; do
      if [[ ${words[0]:-} == nameserver ]] && v_ip "${words[1]:-}"; then dns+=("${words[1]}"); fi
    done </run/systemd/resolve/resolv.conf
  fi
  if ((${#dns[@]} > 0)); then DET_DNS=$(IFS=,; printf '%s' "${dns[*]:0:3}"); fi
  return 0
}

listen_addrs() {  # listen_addrs PORT -> "0.0.0.0:8090 [::]:8090" (empty if none)
  local out; local -a cols addrs=()
  out=$(ss -ltnH "sport = :$1" 2>/dev/null || true)
  while read -r -a cols; do
    if ((${#cols[@]} >= 4)); then addrs+=("${cols[3]}"); fi
  done <<<"$out"
  printf '%s' "${addrs[*]}"
}
port_owner() {    # port_owner PORT -> process name listening on it (empty if free)
  local out re='users:\(\("([^"]+)"'
  out=$(ss -ltnpH "sport = :$1" 2>/dev/null || true)
  [[ -z $out ]] && return 0
  if [[ $out =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf 'unknown'; fi
}
wait_for_listen() {
  local i
  for ((i = 0; i < ${2:-30}; i++)); do
    [[ -n $(listen_addrs "$1") ]] && return 0
    sleep 1
  done
  return 1
}
tcp_open() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }

http_code() {     # http_code URL -> 200, 404, ... or 000
  local code=""
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -L -r 0-0 --max-time 15 -w '%{http_code}' "$1" 2>/dev/null) || true
  elif command -v wget >/dev/null 2>&1; then
    local hdr re='HTTP/[0-9.]+ ([0-9]{3})'
    hdr=$(wget -S --spider -T 15 "$1" 2>&1 || true)
    if [[ $hdr =~ $re ]]; then code=${BASH_REMATCH[1]}; fi
  fi
  printf '%s' "${code:-000}"
}
fetch_url() {     # fetch_url URL DEST
  if command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"; else curl -fsSL -o "$2" "$1"; fi
}

gen_password() {  # 20 alphanumeric characters from openssl rand
  local p=""
  while ((${#p} < PW_GEN_LEN)); do
    p+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${p:0:PW_GEN_LEN}"
}

# --- MySQL --------------------------------------------------------------------
# SQL string literal: escape \ and ' (statements run with backslash escapes on).
sql_quote() { local s=$1; s=${s//\\/\\\\}; s=${s//\'/\\\'}; printf "'%s'" "$s"; }
# MySQL option-file value inside "...": escape \ and ".
cnf_escape() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

# make_cnf USER PASSWORD -> CNF = temp [client] option file (mode 600). The
# password never appears on a command line, so it is invisible in `ps`.
make_cnf() {
  CNF=$(mktemp); TMP_PATHS+=("$CNF")
  chmod 600 "$CNF"
  printf '[client]\nuser="%s"\npassword="%s"\n' "$(cnf_escape "$1")" "$(cnf_escape "$2")" >"$CNF"
}
# set_db_target HOST PORT -> DBC_ARGS (socket for localhost, TCP otherwise)
set_db_target() {
  if [[ -z $1 || $1 == localhost ]]; then
    DBC_ARGS=(--protocol=socket)
  else
    DBC_ARGS=(--protocol=tcp -h "$1" -P "${2:-$MYSQL_DEFAULT_PORT}" --get-server-public-key)
  fi
}
# root through the Ubuntu auth_socket account (sudo mysql)
mysql_root() { mysql --protocol=socket --default-character-set=utf8mb4 -uroot -N -B "$@"; }
# the Zabbix account, using CNF + DBC_ARGS
mysql_zbx() { mysql --defaults-extra-file="$CNF" --default-character-set=utf8mb4 --connect-timeout=5 "${DBC_ARGS[@]}" -N -B "$@"; }

# Feed SQL on stdin (never on the command line). SQL_PREAMBLE makes the
# escaping in sql_quote valid even if the server has NO_BACKSLASH_ESCAPES set.
readonly SQL_PREAMBLE="SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES', '');"
run_sql_root() {  # run_sql_root SQL_FOR_DISPLAY SQL_TO_RUN  (lines separated by \n)
  local -a sql_lines=() lines=()
  local l
  mapfile -t lines <<<"$1"
  for l in "${lines[@]}"; do sql_lines+=("mysql> ${l}"); done
  _action "\$ sudo mysql" "${sql_lines[@]}"
  if [[ $DRY_RUN == true ]]; then return 0; fi
  printf '%s\n%s\n' "$SQL_PREAMBLE" "$2" | mysql_root 2>&1 | _logpipe
}

# schema_state QUERYFN -> nodb | none | partial | full | unknown
schema_state() {
  local q=$1 n v u
  n=$("$q" -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${DB_NAME}'" 2>/dev/null) || { echo unknown; return 0; }
  [[ $n == 0 ]] && { echo nodb; return 0; }
  n=$("$q" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" 2>/dev/null) || { echo unknown; return 0; }
  [[ $n == 0 ]] && { echo none; return 0; }
  v=$("$q" -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.dbversion" 2>/dev/null) || v=0
  u=$("$q" -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.users" 2>/dev/null) || u=0
  if [[ $v != 0 && $u != 0 ]]; then echo full; else echo partial; fi
}

mysql_wait_ready() {
  local i
  for ((i = 0; i < 30; i++)); do
    mysqladmin --protocol=socket -uroot ping >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# MySQL client error -> one-line explanation (guide troubleshooting table)
explain_mysql_error() {
  local out=$1
  case $out in
    *"ERROR 1045"*) printf '%s' "Access denied: wrong password, or the DB user was created for a different IP than this machine (${APP_IP:-?}). Compare with the DB server's hand-off block." ;;
    *"ERROR 1130"*) printf '%s' "Host not allowed: the MySQL user is scoped to another IP. On the DB server re-run: sudo ./zabbix-setup.sh --mode db --app-ip ${APP_IP:-<this IP>}" ;;
    *"ERROR 1049"*) printf '%s' "Unknown database '${DB_NAME}': db mode has not finished on the DB server (or --db-name differs)." ;;
    *"ERROR 2003"*|*"ERROR 2002"*) printf '%s' "Connection refused (ERROR 2003): MySQL not running, bind-address still 127.0.0.1, port mismatch (mysqld.cnf port vs ${DB_PORT:-?}), or ufw on the DB server." ;;
    *"ERROR 2005"*) printf '%s' "Unknown host: check the DB server IP." ;;
    *"ERROR 2059"*|*"ERROR 2061"*) printf '%s' "Authentication plugin problem (caching_sha2_password). Install mysql-client from Ubuntu 26.04 and retry." ;;
    *) printf '%s' "${out%%$'\n'*}" ;;
  esac
}

# =============================================================================
# 5. Inputs, state file and preflight (step 0.1)
# =============================================================================
usage() {
  cat <<EOF
zabbix-setup.sh ${SCRIPT_VERSION} - Zabbix ${ZBX_VERSION} LTS server setup for Ubuntu ${TARGET_UBUNTU}

Usage: sudo ./zabbix-setup.sh [options]

With no options a menu asks which role this machine has:
  1) single   Zabbix + MySQL on this VM
  2) db       two VMs - this machine is the DATABASE server  (run it first)
  3) app      two VMs - this machine is the APP/WEB server   (run it second)

Actions
  --mode single|db|app   skip the menu
  --dry-run              print every command and file edit (numbered like the guide),
                         change nothing, save the list to ./zabbix-manual-steps.txt
  --verify               health check (PASS/WARN/FAIL table, exit 1 on any FAIL)
  --add-user NAME        create sudo user NAME and install an SSH public key
                         (alone: only that; with --mode: done as step 0.2)
  --reset                DROP and recreate the Zabbix database (db/single only, asks first)
  --force                continue on a non-${TARGET_UBUNTU} OS or a role mismatch
  --yes, -y              accept every default, never prompt
  --help, -h             this text

Values  (priority: flag > environment variable > prompt)
  --app-ip IP            APP_IP        db: app server allowed to connect
                                       app/single: this machine (detected)
  --db-ip IP             DB_IP         app: the database server
  --db-port PORT         DB_PORT       default ${DEFAULT_DB_PORT} (1024-65535)
  --db-name NAME         DB_NAME       default ${DEFAULT_DB_NAME}
  --db-user NAME         DB_USER       default ${DEFAULT_DB_USER}
  --db-password-file F   file holding the DB password (first line, or a
                         DB_PASSWORD= line, so the hand-off file works as is)
                         DB_PASSWORD   env var:  sudo --preserve-env=DB_PASSWORD ...
  --timezone TZ          TIMEZONE      default ${DEFAULT_TIMEZONE}
  --win-hostname NAME    WIN_HOSTNAME  only used in the printed Windows steps
  --win-ip IP            WIN_IP        only used in the printed Windows steps
  --iface IF  --static-ip IP  --prefix N  --gateway IP  --dns IP[,IP]
                         IFACE STATIC_IP PREFIX GATEWAY DNS   (static IP, step 0.3)
  --ssh-key-file F       SSH_KEY_FILE  public key for --add-user

There is no --db-password flag on purpose: it would leak into shell history and ps.

Examples
  sudo ./zabbix-setup.sh                                   # menu
  sudo ./zabbix-setup.sh --mode db --app-ip <APP_IP>
  sudo ./zabbix-setup.sh --mode app --db-ip <DB_IP> --db-port <DB_PORT>
  sudo ./zabbix-setup.sh --mode single --dry-run
  sudo ./zabbix-setup.sh --verify
EOF
}

_need() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 needs a value (see --help)"; }
_setv() { local var=$1; shift; _need "$@"; printf -v "$var" '%s' "$2"; SRC[$var]="flag $1"; }

parse_args() {
  ARGS_TEXT="$*"
  while (($#)); do
    if [[ $1 == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
    case $1 in
      --mode)             _setv MODE "$@"; shift 2 ;;
      --app-ip)           _setv APP_IP "$@"; shift 2 ;;
      --db-ip)            _setv DB_IP "$@"; shift 2 ;;
      --db-port)          _setv DB_PORT "$@"; shift 2 ;;
      --db-name)          _setv DB_NAME "$@"; shift 2 ;;
      --db-user)          _setv DB_USER "$@"; shift 2 ;;
      --timezone)         _setv TIMEZONE "$@"; shift 2 ;;
      --win-hostname)     _setv WIN_HOSTNAME "$@"; shift 2 ;;
      --win-ip)           _setv WIN_IP "$@"; shift 2 ;;
      --iface)            _setv IFACE "$@"; shift 2 ;;
      --static-ip)        _setv STATIC_IP "$@"; shift 2 ;;
      --prefix)           _setv PREFIX "$@"; shift 2 ;;
      --gateway)          _setv GATEWAY "$@"; shift 2 ;;
      --dns)              _setv DNS "$@"; shift 2 ;;
      --ssh-key-file)     _setv SSH_KEY_FILE "$@"; shift 2 ;;
      --db-password-file) _need "$@"; PW_FILE=$2; shift 2 ;;
      --add-user)         _need "$@"; ADD_USER=$2; shift 2 ;;
      --dry-run)          DRY_RUN=true; shift ;;
      --verify)           DO_VERIFY=true; shift ;;
      --reset)            RESET=true; shift ;;
      --force)            FORCE=true; shift ;;
      --yes|-y)           ASSUME_YES=true; shift ;;
      --help|-h)          SHOW_HELP=true; shift ;;
      --db-password|--password|--db-pass|--pw)
        die "There is deliberately no password flag (shell history, ps)." \
            "Use --db-password-file PATH, the DB_PASSWORD environment variable, or the hidden prompt." ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
  case ${MODE,,} in 1) MODE=single ;; 2) MODE=db ;; 3) MODE=app ;; *) MODE=${MODE,,} ;; esac
  return 0
}

# --- State file: non-secret settings of the last successful run -------------
load_state() {
  local line key val
  [[ -r $STATE_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^(MODE|APP_IP|DB_IP|DB_PORT|DB_NAME|DB_USER|TIMEZONE)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    printf -v "ST_${key}" '%s' "$val"
  done <"$STATE_FILE"
  return 0
}
write_state() {
  [[ $DRY_RUN == true ]] && return 0
  local port=$DB_PORT
  if [[ $MODE == single && $SINGLE_CUSTOM_PORT == false ]]; then port=0; fi
  {
    printf '# zabbix-setup.sh state - non-secret settings of the last successful run (read by --verify)\n'
    printf 'MODE=%s\nAPP_IP=%s\nDB_IP=%s\nDB_PORT=%s\nDB_NAME=%s\nDB_USER=%s\nTIMEZONE=%s\nUPDATED=%s\n' \
      "$MODE" "$APP_IP" "$DB_IP" "$port" "$DB_NAME" "$DB_USER" "$TIMEZONE" "$(date '+%F %T')"
  } >"${STATE_FILE}.tmp"
  chmod 600 "${STATE_FILE}.tmp"
  mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
  info "settings saved to ${STATE_FILE} (no password)"
}

choose_mode() {
  if [[ -n $MODE ]]; then v_mode "$MODE" || die "--mode: ${VERR}"; return 0; fi
  [[ $ASSUME_YES == true ]] && die "--yes needs --mode single|db|app"
  local c
  say ""
  say "Which scenario?"
  say "  1) Single VM (Zabbix + MySQL on the same machine)"
  say "  2) Two VMs: this machine is the DATABASE server"
  say "  3) Two VMs: this machine is the APP/WEB server"
  while true; do
    read -r -p "Choice [1-3]: " c || die "Input ended."
    case $c in 1) MODE=single; break ;; 2) MODE=db; break ;; 3) MODE=app; break ;; esac
    warn "Type 1, 2 or 3."
  done
  _record "Scenario chosen: ${MODE}"
}

# Step 0.3 questions (asked up front; applied after preflight)
static_ip_prompt() {
  local def=n dyn
  net_detect
  case $DET_DYNAMIC in yes) dyn="DHCP lease" ;; no) dyn="not from DHCP" ;; *) dyn="unknown" ;; esac
  say ""
  say "  Network now: interface ${DET_IFACE:-?}, address ${DET_IP:-?}/${DET_PREFIX:-?}, gateway ${DET_GW:-?}, DNS ${DET_DNS:-?} (${dyn})"
  say "  (The Windows agent needs a stable address for the app server, and the MySQL user is tied to the app server's IP.)"
  [[ $DET_DYNAMIC == no ]] && def=y
  [[ -n ${SRC[STATIC_IP]:-} ]] && def=n
  if ask_yn "Does this server already have a static IP?" "$def"; then
    if [[ -n $DET_IP ]] && ask_yn "Use ${DET_IP}/${DET_PREFIX} on ${DET_IFACE} (gateway ${DET_GW:-none}) as this server's address?" y; then
      NET_ACTION=keep; HOST_IP=$DET_IP
      IFACE=$DET_IFACE; STATIC_IP=$DET_IP; PREFIX=$DET_PREFIX; GATEWAY=$DET_GW; DNS=$DET_DNS
      return 0
    fi
  fi
  warn "A DHCP address can change on reboot or lease renewal. That silently breaks the MySQL user (tied to the app IP) and the Windows agent (Server=/ServerActive=)."
  if ask_yn "Configure a static IP now with netplan? (n = skip and continue)" n; then
    ask IFACE     "Interface:"                      "$DET_IFACE"             v_iface
    ask STATIC_IP "Static IP:"                      "$DET_IP"                v_ip
    ask PREFIX    "Prefix length:"                  "${DET_PREFIX:-24}"      v_prefix
    ask GATEWAY   "Gateway:"                        "$DET_GW"                v_ip
    ask DNS       "DNS server(s), comma-separated:" "${DET_DNS:-$GATEWAY}"   v_dns
    DNS=${DNS// /,}
    NET_ACTION=configure; HOST_IP=$STATIC_IP
  else
    NET_ACTION=skip; HOST_IP=$DET_IP
  fi
}

probe_existing_user() {   # re-run detection (real runs only)
  USER_EXISTS=false
  [[ $DRY_RUN == true || $MODE == app ]] && return 0
  command -v mysql >/dev/null 2>&1 && svc_active mysql || return 0
  local host n
  if [[ $MODE == single ]]; then host=localhost; else host=$APP_IP; fi
  n=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host IN ('${host}','${ST_APP_IP:-$host}')" 2>/dev/null) || n=0
  [[ $n != 0 ]] && USER_EXISTS=true
  return 0
}

read_password_file() {
  local f=$1 line first="" pw="" marker=false mode
  [[ -r $f ]] || die "Cannot read --db-password-file ${f}"
  mode=$(stat -c '%a' "$f" 2>/dev/null || echo 600)
  [[ $mode =~ [1-7]$ || $mode =~ [1-7].$ ]] && warn "${f} is readable by other users - chmod 600 it."
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line == *"zabbix-setup hand-off"* ]] && marker=true
    if [[ $line == DB_PASSWORD=* ]]; then pw=${line#DB_PASSWORD=}; break; fi
    if [[ -z $first && -n $line ]]; then first=$line; fi
  done <"$f"
  if [[ -z $pw ]]; then
    [[ $marker == true ]] && die "${f} is a hand-off file without a DB_PASSWORD= line (password was kept on a re-run). Use the earlier hand-off file or type the password."
    pw=$first
  fi
  DB_PASSWORD=$pw
}

previous_handoff_password() {   # DB_PASSWORD= line of an earlier hand-off file
  local line
  [[ -r $HANDOFF_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == DB_PASSWORD=* ]]; then printf '%s' "${line#DB_PASSWORD=}"; return 0; fi
  done <"$HANDOFF_FILE"
  return 0
}

collect_password() {
  local p1 p2 conf_pw="" keep_ok=false prompt
  if [[ -n $PW_FILE ]]; then read_password_file "$PW_FILE"; PW_ORIGIN="file ${PW_FILE}"; fi
  if [[ -n $PW_ORIGIN ]]; then
    v_password "$DB_PASSWORD" || die "DB password from ${PW_ORIGIN} rejected: ${VERR}"
    say "  DB password: ${MASK}   (from ${PW_ORIGIN})"
    return 0
  fi
  if [[ $DRY_RUN != true && $MODE != db && -r $ZBX_SERVER_CONF ]]; then
    conf_pw=$(kv_get "$ZBX_SERVER_CONF" "" DBPassword || true)
  fi

  if [[ $MODE == app ]]; then
    # Typed once: step 2.3 logs in with it straight away and stops on a typo.
    if [[ $ASSUME_YES == true ]]; then
      [[ -n $conf_pw ]] || die "--yes in app mode needs --db-password-file or DB_PASSWORD (from the DB server's hand-off)."
      DB_PASSWORD=$conf_pw; PW_ORIGIN="existing zabbix_server.conf"; return 0
    fi
    prompt="  DB password (from the DB server's hand-off block): "
    [[ -n $conf_pw ]] && prompt="  DB password (press Enter to reuse the one in zabbix_server.conf): "
    while true; do
      read_hidden p1 "$prompt"
      if [[ -z $p1 && -n $conf_pw ]]; then DB_PASSWORD=$conf_pw; PW_ORIGIN="existing zabbix_server.conf"; return 0; fi
      if v_password "$p1"; then DB_PASSWORD=$p1; PW_ORIGIN="typed"; return 0; fi
      warn "${VERR} - try again."
    done
  fi

  # db / single: Enter generates a password, or keeps it if the user exists.
  if [[ $USER_EXISTS == true ]]; then
    if [[ $MODE == db || -n $conf_pw ]]; then keep_ok=true; fi
  fi
  if [[ $ASSUME_YES == true ]]; then
    if [[ $keep_ok == true ]]; then _keep_password "$conf_pw"; else DB_PASSWORD=$(gen_password); PW_ORIGIN="generated"; fi
    say "  DB password: ${MASK}   (${PW_ORIGIN}, --yes)"
    return 0
  fi
  prompt="  DB password (press Enter to generate one): "
  [[ $keep_ok == true ]] && prompt="  DB password (press Enter to keep the current one): "
  while true; do
    read_hidden p1 "$prompt"
    if [[ -z $p1 ]]; then
      if [[ $keep_ok == true ]]; then _keep_password "$conf_pw"; else DB_PASSWORD=$(gen_password); PW_ORIGIN="generated"; fi
      return 0
    fi
    if ! v_password "$p1"; then warn "${VERR} - try again."; continue; fi
    read_hidden p2 "  Confirm DB password: "
    if [[ $p1 != "$p2" ]]; then warn "The two entries differ - try again."; continue; fi
    DB_PASSWORD=$p1; PW_ORIGIN="typed"; return 0
  done
}
_keep_password() {
  PW_KEEP=true
  if [[ $MODE == single ]]; then DB_PASSWORD=$1; else DB_PASSWORD=$(previous_handoff_password); fi
  PW_ORIGIN="kept (MySQL user already exists)"
}

collect_inputs() {
  part "Settings (${MODE})"
  if [[ $ST_MODE != "$MODE" ]]; then ST_APP_IP=""; ST_DB_IP=""; ST_DB_PORT=""; ST_DB_NAME=""; ST_DB_USER=""; fi
  static_ip_prompt
  case $MODE in
    db)
      ask APP_IP "App/web server IP (the only host allowed to connect to MySQL):" "${ST_APP_IP}" v_ip
      if [[ -z ${SRC[DB_IP]:-} ]]; then DB_IP=$HOST_IP; fi
      v_ip "$DB_IP" || die "Could not detect this server's IP for the hand-off; pass --db-ip."
      ask DB_PORT "Database port?" "${ST_DB_PORT:-$DEFAULT_DB_PORT}" v_port
      ;;
    app)
      ask APP_IP "This server's IP (APP_IP):" "${HOST_IP:-$ST_APP_IP}" v_ip
      ask DB_IP "Database server IP (DB_IP):" "${ST_DB_IP}" v_ip
      ask DB_PORT "Database port?" "${ST_DB_PORT:-$DEFAULT_DB_PORT}" v_port
      ;;
    single)
      ask APP_IP "This server's IP (APP_IP):" "${HOST_IP:-$ST_APP_IP}" v_ip
      DB_IP=""
      if [[ -n ${SRC[DB_PORT]:-} ]]; then
        SINGLE_CUSTOM_PORT=true
      elif [[ -n $ST_DB_PORT && $ST_DB_PORT != 0 ]]; then
        if ! ask_yn "Use the default MySQL setup (local socket, port 0 in the wizard)?" n; then SINGLE_CUSTOM_PORT=true; fi
      elif ! ask_yn "Use the default MySQL setup (local socket, port 0 in the wizard)?" y; then
        SINGLE_CUSTOM_PORT=true
      fi
      if [[ $SINGLE_CUSTOM_PORT == true ]]; then
        local def_port=$DEFAULT_DB_PORT
        [[ -n $ST_DB_PORT && $ST_DB_PORT != 0 ]] && def_port=$ST_DB_PORT
        ask DB_PORT "Custom MySQL port:" "$def_port" v_port
      else
        DB_PORT=0
      fi
      ;;
  esac
  ask DB_NAME "Database name:" "${ST_DB_NAME:-$DEFAULT_DB_NAME}" v_dbname
  ask DB_USER "Database user:" "${ST_DB_USER:-$DEFAULT_DB_USER}" v_dbuser
  probe_existing_user
  collect_password
  ask TIMEZONE "Timezone:" "${ST_TIMEZONE:-$DEFAULT_TIMEZONE}" v_tz
  if [[ $MODE != db ]]; then
    ask WIN_HOSTNAME "Windows host name for the printed steps:" "" v_winhost
    ask WIN_IP "Windows IP for the printed steps:" "" v_ip_opt
  fi
}

show_summary() {
  part "Summary"
  say "  Scenario      : ${MODE}"
  case $MODE in
    db)     say "  This DB server: ${DB_IP}   (port ${DB_PORT})"
            say "  App server    : ${APP_IP}  (only host allowed to log in)" ;;
    app)    say "  This server   : ${APP_IP}"
            say "  DB server     : ${DB_IP}:${DB_PORT}" ;;
    single) say "  This server   : ${APP_IP}"
            if [[ $SINGLE_CUSTOM_PORT == true ]]; then say "  MySQL         : localhost, custom port ${DB_PORT}"
            else say "  MySQL         : localhost via socket (wizard port 0)"; fi ;;
  esac
  say "  Database/user : ${DB_NAME} / ${DB_USER}"
  say "  DB password   : ${MASK}   (${PW_ORIGIN})"
  say "  Timezone      : ${TIMEZONE}"
  say "  Static IP     : ${NET_ACTION}${STATIC_IP:+ (${STATIC_IP}/${PREFIX} via ${GATEWAY:-?} on ${IFACE:-?})}"
  [[ -n $ADD_USER ]] && say "  Admin user    : ${ADD_USER}"
  [[ $RESET == true ]] && say "  RESET         : database ${DB_NAME} will be DROPPED and recreated"
  if [[ $MODE != db ]]; then say "  Windows host  : ${WIN_HOSTNAME:-<WIN_HOSTNAME>} / ${WIN_IP:-<WIN_IP>}"; fi
  return 0
}

# --- Result tables (preflight and --verify) ----------------------------------
vrow() {   # vrow PASS|WARN|FAIL "check" "detail" "fix"
  V_ROWS+=("${1}${US}${2}${US}${3}${US}${4:-}")
  case $1 in FAIL) V_FAILS=$((V_FAILS + 1)) ;; WARN) V_WARNS=$((V_WARNS + 1)) ;; esac
  return 0
}
print_rows() {
  local row st name detail fix color
  for row in "${V_ROWS[@]}"; do
    IFS=$US read -r st name detail fix <<<"$row"
    case $st in PASS) color=$C_GREEN ;; WARN) color=$C_YELLOW ;; *) color=$C_RED ;; esac
    _emit "$color" "$(printf '  %-5s %-44s %s' "$st" "$name" "$detail")"
    if [[ -n $fix && $st != PASS ]]; then say "        fix: ${fix}"; fi
  done
}

preflight() {
  part "Part 0 - Preparation"
  step 0.1 "Preflight checks (nothing has been changed yet)"
  V_ROWS=(); V_FAILS=0; V_WARNS=0; PF_HINTS=()
  local avail_kb mem_kb code url owner

  # root
  if [[ $EUID -eq 0 ]]; then vrow PASS "running as root" "uid 0"
  elif [[ $DRY_RUN == true ]]; then vrow WARN "running as root" "not root (fine for --dry-run)"
  else vrow FAIL "running as root" "uid ${EUID}" "sudo $0 ${ARGS_TEXT}"; fi

  # OS
  read_os
  if [[ $OS_ID == ubuntu && $OS_VER == "$TARGET_UBUNTU" ]]; then vrow PASS "OS is Ubuntu ${TARGET_UBUNTU}" "${OS_ID} ${OS_VER}"
  elif [[ $FORCE == true || $DRY_RUN == true ]]; then vrow WARN "OS is Ubuntu ${TARGET_UBUNTU}" "found '${OS_ID:-?} ${OS_VER:-?}'"
  else vrow FAIL "OS is Ubuntu ${TARGET_UBUNTU}" "found '${OS_ID:-?} ${OS_VER:-?}'" "use Ubuntu ${TARGET_UBUNTU}, or add --force to try anyway"; fi

  # disk / RAM
  avail_kb=$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $4}') || avail_kb=""
  if [[ -z $avail_kb ]]; then vrow WARN "free disk >= ${MIN_DISK_GB} GB" "could not read df"
  elif ((avail_kb >= MIN_DISK_GB * 1024 * 1024)); then vrow PASS "free disk >= ${MIN_DISK_GB} GB" "$((avail_kb / 1024 / 1024)) GB free on /var"
  else vrow FAIL "free disk >= ${MIN_DISK_GB} GB" "$((avail_kb / 1024 / 1024)) GB free on /var" "free space or grow the disk"; fi
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null) || mem_kb=""
  if [[ -z $mem_kb ]]; then vrow WARN "RAM >= ${MIN_RAM_MB} MB" "could not read /proc/meminfo"
  elif ((mem_kb >= MIN_RAM_MB * 1024 * 95 / 100)); then vrow PASS "RAM >= ${MIN_RAM_MB} MB" "$((mem_kb / 1024)) MB"
  else vrow WARN "RAM >= ${MIN_RAM_MB} MB" "$((mem_kb / 1024)) MB - Zabbix may be slow"; fi

  # Zabbix repo (needed for app/single) - catches the 404 from a wrong path
  if [[ $MODE != db ]]; then
    url=$(zbx_release_url)
    code=$(http_code "$url")
    case $code in
      200|206) vrow PASS "repo.zabbix.com reachable" "HTTP ${code} (release .deb)" ;;
      404) vrow FAIL "repo.zabbix.com reachable" "HTTP 404 for ${url}" "the URL must contain /release/ (zabbix/${ZBX_VERSION}/release/ubuntu/...) and Zabbix ${ZBX_VERSION} must exist for Ubuntu ${OS_VER:-$TARGET_UBUNTU}" ;;
      000) vrow FAIL "repo.zabbix.com reachable" "no connection" "check internet access, DNS (resolvectl status) and any proxy" ;;
      *)   vrow FAIL "repo.zabbix.com reachable" "HTTP ${code}" "open ${url} in a browser to see the error" ;;
    esac
  fi

  # Does the chosen role fit this machine?
  if [[ -n $ST_MODE && $ST_MODE != "$MODE" ]]; then
    if [[ $FORCE == true ]]; then vrow WARN "scenario matches this machine" "state file says '${ST_MODE}'"
    else vrow FAIL "scenario matches this machine" "${STATE_FILE} says this machine is '${ST_MODE}'" "choose '${ST_MODE}', or add --force if you are rebuilding it"; fi
  fi
  case $MODE in
    db)
      if pkg_installed zabbix-server-mysql; then
        if [[ $FORCE == true ]]; then vrow WARN "role: DB server" "zabbix-server is installed here"
        else vrow FAIL "role: DB server" "zabbix-server is installed here - this looks like the APP or single VM" "pick option 3 (app) or 1 (single), or --force"; fi
      fi
      if is_local_ip "$APP_IP"; then
        vrow FAIL "APP_IP is another machine" "${APP_IP} belongs to THIS server" "for one VM pick option 1 (single); otherwise enter the app server's IP"
      fi
      owner=$(port_owner "$DB_PORT")
      if [[ -z $owner ]]; then vrow PASS "port ${DB_PORT} free (ss -ltn)" "nothing listening"
      elif [[ $owner == mysqld ]]; then vrow PASS "port ${DB_PORT} free (ss -ltn)" "already MySQL (re-run)"
      else vrow FAIL "port ${DB_PORT} free (ss -ltn)" "in use by ${owner}" "choose another --db-port or stop ${owner}"; fi
      if command -v ping >/dev/null 2>&1 && ping -c1 -W2 "$APP_IP" >/dev/null 2>&1; then vrow PASS "app server ${APP_IP} answers ping" ""
      else vrow WARN "app server ${APP_IP} answers ping" "no reply (may just block ICMP)"; fi
      ;;
    app)
      if is_local_ip "$DB_IP"; then
        vrow FAIL "DB_IP is another machine" "${DB_IP} belongs to THIS server" "for one VM pick option 1 (single)"
      fi
      if [[ $DRY_RUN != true ]] && ! is_local_ip "$APP_IP"; then vrow WARN "APP_IP is this machine" "${APP_IP} is not on any local interface (OK only behind NAT)"; fi
      if pkg_installed mysql-server; then vrow WARN "role: APP server" "mysql-server is installed here - is this the DB machine (option 2)?"; fi
      _action "\$ timeout 3 bash -c '</dev/tcp/${DB_IP}/${DB_PORT}'   # is the DB server answering?"
      if tcp_open "$DB_IP" "$DB_PORT"; then vrow PASS "DB server ${DB_IP}:${DB_PORT} answers" "TCP connect OK"
      else
        vrow FAIL "DB server ${DB_IP}:${DB_PORT} answers" "no TCP answer within 3 s" "see the likely causes below"
        PF_HINTS+=("Likely causes, checked on the DB server ${DB_IP}:"
                   "  1. db mode not run yet          -> sudo ./zabbix-setup.sh --mode db --app-ip ${APP_IP}"
                   "  2. MySQL not running            -> sudo systemctl status mysql"
                   "  3. bind-address is 127.0.0.1    -> /etc/mysql/mysql.conf.d/mysqld.cnf must say 0.0.0.0"
                   "  4. port mismatch                -> sudo ss -ltn | grep mysqld  (must show ${DB_PORT})"
                   "  5. ufw blocks the port          -> sudo ufw status")
      fi
      ;;
    single)
      if [[ $DRY_RUN != true ]] && ! is_local_ip "$APP_IP"; then vrow WARN "APP_IP is this machine" "${APP_IP} is not on any local interface"; fi
      if [[ $SINGLE_CUSTOM_PORT == true ]]; then
        owner=$(port_owner "$DB_PORT")
        if [[ -z $owner || $owner == mysqld ]]; then vrow PASS "port ${DB_PORT} free (ss -ltn)" "${owner:-nothing listening}"
        else vrow FAIL "port ${DB_PORT} free (ss -ltn)" "in use by ${owner}" "choose another port"; fi
      fi
      ;;
  esac
  if [[ $MODE != db ]] && pkg_installed zabbix-agent; then
    vrow WARN "classic zabbix-agent absent" "installed - it also uses port ${ZBX_AGENT_PORT}" "sudo apt remove zabbix-agent (this setup uses zabbix-agent2)"
  fi
  if [[ $RESET == true && $MODE == app ]]; then
    vrow FAIL "--reset on the right node" "app mode cannot drop the remote DB" "run --reset on the DB server: sudo ./zabbix-setup.sh --mode db --reset"
  fi
  vrow PASS "ufw" "$(ufw_state) (it is never enabled by this script)"

  print_rows
  local h
  for h in "${PF_HINTS[@]}"; do say "  ${h}"; done
  if ((V_FAILS > 0)); then
    if [[ $DRY_RUN == true ]]; then warn "A real run would stop here (${V_FAILS} FAIL). Continuing because this is --dry-run."
    else die "Preflight: ${V_FAILS} check(s) failed. Nothing was changed."; fi
  else
    ok "preflight passed (${V_WARNS} warning(s))"
  fi
}

zbx_release_url() {
  local ver=${OS_VER:-$TARGET_UBUNTU}
  [[ $OS_ID == ubuntu ]] || ver=$TARGET_UBUNTU
  printf '%s/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu%s_all.deb' "$ZBX_REPO_BASE" "$ver"
}

# =============================================================================
# 6. Part 0 - optional admin user (0.2), static IP (0.3), time (0.4)
# =============================================================================
apt_update() {
  if [[ $APT_FRESH == true ]]; then _action "\$ sudo apt update"; skip "package lists already refreshed in this run"; return 0; fi
  run_show "sudo apt update" apt-get -o DPkg::Lock::Timeout=300 update
  APT_FRESH=true
}
# apt_install "TEXT SHOWN" PKG... - installs only what is missing
apt_install() {
  local shown=$1 p; shift
  local -a missing=()
  if [[ $DRY_RUN == true ]]; then missing=("$@")
  else for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done; fi
  if ((${#missing[@]} == 0)); then _action "\$ ${shown}"; skip "already installed: $*"; return 0; fi
  run_show "$shown" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y "${missing[@]}"
}

# Step 0.2 - sudo user + SSH key. sshd_config is never touched.
add_admin_user() {
  local name=$ADD_USER home key="" ans
  v_username "$name" || die "--add-user '${name}': ${VERR}"
  step 0.2 "Create admin user '${name}' with an SSH key (sshd_config is not touched)"
  home="/home/${name}"
  if [[ $DRY_RUN != true ]] && id "$name" >/dev/null 2>&1; then
    home=$(getent passwd "$name" | cut -d: -f6)
    _action "\$ sudo useradd -m -s /bin/bash ${name}"; skip "user ${name} already exists"
  else
    run useradd -m -s /bin/bash "$name"
  fi
  run usermod -aG sudo "$name"

  # The public key: --ssh-key-file / SSH_KEY_FILE, or a prompt (path or key)
  if [[ -n $SSH_KEY_FILE ]]; then
    [[ -r $SSH_KEY_FILE ]] || die "Cannot read SSH key file ${SSH_KEY_FILE}"
    key=$(grep -m1 -E '^(ssh-|ecdsa-|sk-)' "$SSH_KEY_FILE" || true)
  elif [[ $ASSUME_YES != true ]]; then
    IFS= read -r -p "  SSH public key for ${name} (path to a .pub file, or paste the key line; Enter = skip): " ans || ans=""
    if [[ -n $ans && -r $ans ]]; then key=$(grep -m1 -E '^(ssh-|ecdsa-|sk-)' "$ans" || true); else key=$ans; fi
  fi
  key=${key%$'\r'}
  local re_key='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( .*)?$'
  if [[ -z $key ]]; then
    warn "No SSH key given - add one later to ${home}/.ssh/authorized_keys"
  elif [[ ! $key =~ $re_key ]]; then
    die "That does not look like an OpenSSH public key (expected 'ssh-ed25519 AAAA... comment')."
  else
    run mkdir -p "${home}/.ssh"
    _action "append the key to ${home}/.ssh/authorized_keys (if not already there)" "${key:0:60}..."
    if [[ $DRY_RUN != true ]]; then
      touch "${home}/.ssh/authorized_keys"
      if grep -qxF -- "$key" "${home}/.ssh/authorized_keys"; then info "key already present"
      else printf '%s\n' "$key" >>"${home}/.ssh/authorized_keys"; fi
    fi
    run chown -R "${name}:${name}" "${home}/.ssh"
    run chmod 700 "${home}/.ssh"
    run chmod 600 "${home}/.ssh/authorized_keys"
  fi
  # A password is needed to use sudo; passwd prompts on its own (never logged).
  if [[ $DRY_RUN == true ]]; then
    _action "\$ sudo passwd ${name}   # needed so ${name} can use sudo"
  elif [[ $ASSUME_YES != true ]] && ask_yn "Set a login password for ${name} now (needed for sudo)?" y; then
    passwd "$name" || warn "passwd failed - run: sudo passwd ${name}"
  else
    info "Remember: sudo passwd ${name}"
  fi
}

# Step 0.3 - static IP with netplan try (never a bare netplan apply)
apply_static_ip() {
  step 0.3 "Static IP for this server"
  case $NET_ACTION in
    keep) ok "static address ${HOST_IP} on ${IFACE} - nothing to change"; return 0 ;;
    skip)
      warn "Skipped. If this address (${HOST_IP:-unknown}) changes, the MySQL user / Windows agent config break. Re-run later to fix, or reserve the IP in DHCP."
      return 0 ;;
  esac
  local f yaml dns_list
  dns_list=${DNS//,/, }
  yaml=$(cat <<EOF
# Written by zabbix-setup.sh ${RUN_TS} - static address for the Zabbix setup.
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/${PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${dns_list}]
EOF
)
  if [[ $DRY_RUN == true ]]; then
    _action "\$ sudo mkdir -p ${BACKUP_DIR}${NETPLAN_DIR} && sudo cp -a ${NETPLAN_DIR}/*.yaml ${BACKUP_DIR}${NETPLAN_DIR}/"
  else
    for f in "$NETPLAN_DIR"/*.yaml; do [[ -e $f ]] && backup_file "$f"; done
  fi
  local -a ylines; mapfile -t ylines <<<"$yaml"
  _action "write ${NETPLAN_FILE}:" "${ylines[@]}"
  _action "\$ sudo chmod 600 ${NETPLAN_FILE}"
  _action "\$ sudo netplan try --timeout ${NETPLAN_TRY_TIMEOUT}   # press ENTER to keep; no ENTER = automatic rollback"
  [[ $DRY_RUN == true ]] && return 0

  warn "Changing the IP over SSH can drop your session. netplan try rolls back after ${NETPLAN_TRY_TIMEOUT} s unless you press ENTER."
  if [[ $STATIC_IP != "$DET_IP" ]]; then
    warn "The address changes (${DET_IP:-?} -> ${STATIC_IP}). Over SSH you will lose this session and cannot confirm - use the VM console for this step."
  fi
  if [[ $ASSUME_YES == true ]] || ! ask_yn "Apply this static IP now?" n; then
    warn "Not applied. Reminder: a changing DHCP address will break the setup later."
    return 0
  fi
  printf '%s\n' "$yaml" >"$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"
  if ! netplan generate 2>&1 | _logpipe; then
    rm -f "$NETPLAN_FILE"; warn "netplan generate rejected the file - removed it, nothing applied."; return 0
  fi
  netplan try --timeout "$NETPLAN_TRY_TIMEOUT" || true
  net_detect
  if [[ $DET_IP == "$STATIC_IP" && $DET_DYNAMIC != yes ]]; then
    ok "static IP ${STATIC_IP}/${PREFIX} active on ${IFACE}"
  else
    rm -f "$NETPLAN_FILE"
    warn "Static IP not confirmed (rolled back). Removed ${NETPLAN_FILE}; previous files are in ${BACKUP_DIR}${NETPLAN_DIR}."
  fi
}

# Step 0.4 - chrony + system timezone
setup_time() {
  step 0.4 "Time sync (chrony) and timezone ${TIMEZONE}"
  apt_update
  apt_install "sudo apt install chrony -y" chrony
  run systemctl enable --now chrony
  run timedatectl set-timezone "$TIMEZONE"
  _action "\$ timedatectl show -p NTPSynchronized --value; chronyc tracking   # expect 'yes' / Leap status Normal"
  [[ $DRY_RUN == true ]] && return 0
  local i
  for ((i = 0; i < 15; i++)); do
    if chrony_synced; then ok "clock synchronised by chrony"; return 0; fi
    sleep 2
  done
  warn "chrony is running but not synchronised yet - check: chronyc sources -v (outbound UDP 123 must be allowed)"
}
chrony_synced() {
  local t re='Leap status[[:space:]]*:[[:space:]]*Normal'
  [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]] && return 0
  t=$(chronyc -n tracking 2>/dev/null || true)
  [[ $t =~ $re ]]
}

# =============================================================================
# 7. Part 1 - Database node (db mode; single mode runs it locally)
# =============================================================================
db_user_host() { if [[ $MODE == single ]]; then printf 'localhost'; else printf '%s' "$APP_IP"; fi; }

part1_database() {
  part "Part 1 - Database node"

  # ---- 1.1 Install MySQL --------------------------------------------------
  step 1.1 "Install MySQL"
  apt_update
  apt_install "sudo apt install mysql-server -y" mysql-server
  run systemctl enable --now mysql
  if [[ $DRY_RUN != true ]]; then
    mysql_wait_ready || die "MySQL did not start. Check: sudo systemctl status mysql; sudo journalctl -u mysql -n 50"
  fi

  # ---- 1.2 bind-address and port ------------------------------------------
  if [[ $MODE == db ]]; then
    step 1.2 "Allow remote connections and set port ${DB_PORT}"
    backup_file "$MYSQLD_CNF"
    edit_kv "$MYSQLD_CNF" mysqld bind-address 0.0.0.0 ini
    edit_kv "$MYSQLD_CNF" mysqld port "$DB_PORT" ini
    restart_mysql_on_port "$DB_PORT"
  elif [[ $SINGLE_CUSTOM_PORT == true ]]; then
    step 1.2 "Set MySQL port ${DB_PORT} (single VM: bind-address stays 127.0.0.1)"
    backup_file "$MYSQLD_CNF"
    edit_kv "$MYSQLD_CNF" mysqld port "$DB_PORT" ini
    restart_mysql_on_port "$DB_PORT"
  else
    step 1.2 "Remote access / custom port"
    local cur_port=""
    [[ $DRY_RUN != true ]] && cur_port=$(kv_get "$MYSQLD_CNF" mysqld port || true)
    if [[ -n $cur_port && $cur_port != "$MYSQL_DEFAULT_PORT" ]]; then
      info "an earlier run set port ${cur_port}; going back to the default"
      backup_file "$MYSQLD_CNF"
      edit_kv "$MYSQLD_CNF" mysqld port "$MYSQL_DEFAULT_PORT" ini
      restart_mysql_on_port "$MYSQL_DEFAULT_PORT"
    else
      skip "single VM: keep bind-address 127.0.0.1 and the local socket - no edit needed"
    fi
  fi

  # ---- 1.3 Firewall ----------------------------------------------------------
  step 1.3 "Open the firewall for MySQL"
  if [[ $MODE == db ]]; then
    open_db_firewall
  else
    skip "single VM: MySQL is only used locally - nothing to open"
  fi

  # ---- 1.4 Database and user ---------------------------------------------------
  step 1.4 "Create the database and user (CREATE USER before GRANT - MySQL 8)"
  if [[ $DRY_RUN != true ]]; then
    mysql_root -e "SELECT 1" >/dev/null 2>&1 || die "Cannot log in to MySQL as root through the socket (sudo mysql)." \
      "If root has a password, put it in /root/.my.cnf ([client] password=...) and re-run."
  fi
  [[ $RESET == true ]] && reset_database
  local host state trust grant_db sql_show sql_real pw_lit
  host=$(db_user_host)
  grant_db=${DB_NAME//_/\\_}           # _ is a wildcard in GRANT ... ON db.*
  [[ $MODE == db ]] && rename_moved_user
  # Trust must be 1 while the schema is imported (Part 2 step 3) and 0
  # afterwards. A re-run after the import therefore switches it back to 0.
  state=none
  [[ $DRY_RUN != true ]] && state=$(schema_state mysql_root)
  trust=1
  [[ $state == full ]] && trust=0
  pw_lit=$(sql_quote "$DB_PASSWORD")
  sql_show="CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
  sql_real=$sql_show
  if [[ $PW_KEEP == true ]]; then
    sql_show+=$'\n'"-- '${DB_USER}'@'${host}' exists: password kept"
  else
    sql_show+=$'\n'"CREATE USER IF NOT EXISTS '${DB_USER}'@'${host}' IDENTIFIED BY '${MASK}';"
    sql_show+=$'\n'"ALTER USER '${DB_USER}'@'${host}' IDENTIFIED BY '${MASK}';   -- re-run safe"
    sql_real+=$'\n'"CREATE USER IF NOT EXISTS '${DB_USER}'@'${host}' IDENTIFIED BY ${pw_lit};"
    sql_real+=$'\n'"ALTER USER '${DB_USER}'@'${host}' IDENTIFIED BY ${pw_lit};"
  fi
  local tail_sql="GRANT ALL PRIVILEGES ON \`${grant_db}\`.* TO '${DB_USER}'@'${host}';"
  tail_sql+=$'\n'"SET GLOBAL log_bin_trust_function_creators = ${trust};"
  tail_sql+=$'\n'"FLUSH PRIVILEGES;"
  sql_show+=$'\n'"$tail_sql"; sql_real+=$'\n'"$tail_sql"
  run_sql_root "$sql_show" "$sql_real"
  if [[ $trust == 0 ]]; then
    ok "schema already imported - log_bin_trust_function_creators is back to 0 (guide Part 2 step 3)"
  else
    info "log_bin_trust_function_creators = 1 until the schema is imported (Part 2 step 3)"
  fi

  # ---- 1.5 Verify ------------------------------------------------------------
  if [[ $MODE == db ]]; then
    step 1.5 "Verify remote access works"
    _action "\$ sudo ss -ltn | grep :${DB_PORT}   # expect 0.0.0.0:${DB_PORT}"
    _action "\$ sudo mysql -e \"SELECT user,host FROM mysql.user WHERE user='${DB_USER}';\"   # expect ${DB_USER} | ${APP_IP}"
    if [[ $DRY_RUN != true ]]; then
      local addrs n
      addrs=$(listen_addrs "$DB_PORT")
      [[ $addrs == *"0.0.0.0:${DB_PORT}"* || $addrs == *"*:${DB_PORT}"* ]] \
        || die "MySQL is not listening on 0.0.0.0:${DB_PORT} (found: ${addrs:-nothing}). Check bind-address/port in ${MYSQLD_CNF}."
      ok "listening on ${addrs}"
      n=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='${APP_IP}'")
      [[ $n == 1 ]] || die "User '${DB_USER}'@'${APP_IP}' was not created."
      ok "user '${DB_USER}'@'${APP_IP}' exists"
    fi
    info "The real test runs FROM the app server (${APP_IP}), not here:"
    info "    mysql -h ${DB_IP} -P ${DB_PORT} -u ${DB_USER} -p"
    info "app mode does exactly this before it imports the schema."
  else
    step 1.5 "Verify the zabbix user can log in (local socket)"
    _action "\$ mysql -u ${DB_USER} -p ${DB_NAME} -e 'SELECT 1;'"
    if [[ $DRY_RUN != true ]]; then
      make_cnf "$DB_USER" "$DB_PASSWORD"; set_db_target localhost ""
      local out
      out=$(mysql_zbx "$DB_NAME" -e "SELECT 1" 2>&1) || die "Login as ${DB_USER} failed: $(explain_mysql_error "$out")"
      ok "${DB_USER}@localhost can log in"
    fi
  fi
}

restart_mysql_on_port() {
  run systemctl restart mysql
  _action "\$ sudo ss -ltn | grep :$1   # MySQL must listen on $1"
  [[ $DRY_RUN == true ]] && return 0
  mysql_wait_ready || die "MySQL did not come back after the restart. Check: sudo journalctl -u mysql -n 50"
  wait_for_listen "$1" 30 || die "MySQL is running but not listening on port $1. Check port = in ${MYSQLD_CNF} and: sudo ss -ltnp"
  ok "MySQL listening on $(listen_addrs "$1")"
}

open_db_firewall() {
  local st
  if [[ $DRY_RUN == true ]]; then
    _action "\$ sudo ufw status"
    _action "\$ sudo ufw allow from ${APP_IP} to any port ${DB_PORT} proto tcp   # only if ufw is active (guide: sudo ufw allow ${DB_PORT}/tcp)"
    return 0
  fi
  st=$(ufw_state)
  _action "\$ sudo ufw status   # -> ${st}"
  if [[ $st != active ]]; then
    skip "ufw is ${st} - nothing to open (this script never enables ufw)"
    FW_SKIPPED+=("${DB_PORT}/tcp (ufw ${st})")
    return 0
  fi
  # A previous run with another port or app IP: remove its rule first.
  if [[ $ST_MODE == db && -n $ST_DB_PORT && -n $ST_APP_IP ]] && [[ $ST_DB_PORT != "$DB_PORT" || $ST_APP_IP != "$APP_IP" ]]; then
    run ufw delete allow from "$ST_APP_IP" to any port "$ST_DB_PORT" proto tcp || true
  fi
  run ufw allow from "$APP_IP" to any port "$DB_PORT" proto tcp
  FW_CHANGED+=("allow ${DB_PORT}/tcp from ${APP_IP}")
  say "      firewall changed: ${FW_CHANGED[*]}"
}

# The app server's IP changed since the last run: move the account over.
rename_moved_user() {
  [[ $DRY_RUN == true || -z $ST_APP_IP || $ST_APP_IP == "$APP_IP" ]] && return 0
  local old new
  old=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='${ST_APP_IP}'")
  new=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='${APP_IP}'")
  if [[ $old == 1 && $new == 0 ]]; then
    run_sql_root "RENAME USER '${DB_USER}'@'${ST_APP_IP}' TO '${DB_USER}'@'${APP_IP}';" \
                 "RENAME USER '${DB_USER}'@'${ST_APP_IP}' TO '${DB_USER}'@'${APP_IP}';"
  elif [[ $old == 1 ]]; then
    warn "'${DB_USER}'@'${ST_APP_IP}' (old app IP) still exists. Remove it if unused: sudo mysql -e \"DROP USER '${DB_USER}'@'${ST_APP_IP}';\""
  fi
  return 0
}

# --reset: the only destructive action. Always asks, even with --yes.
reset_database() {
  _action "\$ sudo mysql -e \"DROP DATABASE IF EXISTS \\\`${DB_NAME}\\\`;\"   # --reset (guide troubleshooting: ERROR 1050)"
  [[ $DRY_RUN == true ]] && return 0
  warn "--reset will permanently DELETE the database '${DB_NAME}' and all Zabbix data in it."
  [[ $MODE == db ]] && warn "Stop zabbix-server on the app server first: sudo systemctl stop zabbix-server"
  local ans=""
  IFS= read -r -p "  Type the database name (${DB_NAME}) to confirm the DROP: " ans || ans=""
  [[ $ans == "$DB_NAME" ]] || die "Not confirmed - nothing was dropped."
  if [[ $MODE == single ]] && svc_active zabbix-server; then run systemctl stop zabbix-server; fi
  printf '%s\n' "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" | mysql_root 2>&1 | _logpipe
  ok "database ${DB_NAME} dropped - it is recreated empty below"
}

# =============================================================================
# 8. Part 2 - App & Web server (app mode; single mode runs it locally)
# =============================================================================
part2_app() {
  part "Part 2 - App & Web server"
  local db_host=$DB_IP db_port=$DB_PORT
  if [[ $MODE == single ]]; then db_host=localhost; [[ $SINGLE_CUSTOM_PORT == true ]] || db_port=""; fi

  # ---- 2.1 Repository ----------------------------------------------------------
  step 2.1 "Add the Zabbix ${ZBX_VERSION} repository (Ubuntu ${OS_VER:-$TARGET_UBUNTU})"
  local url deb tmpd
  url=$(zbx_release_url); deb=${url##*/}
  if [[ $DRY_RUN != true ]] && grep -rqs "zabbix/${ZBX_VERSION}/release" /etc/apt/sources.list.d/; then
    _action "\$ wget ${url}"
    skip "the Zabbix ${ZBX_VERSION} repository is already configured"
  else
    if [[ $DRY_RUN == true ]]; then tmpd="."; else tmpd=$(mktemp -d); TMP_PATHS+=("$tmpd"); fi
    run_show "wget ${url}" fetch_url "$url" "${tmpd}/${deb}" \
      || die "Download failed. A 404 means a wrong path: it must include /release/ (zabbix/${ZBX_VERSION}/release/ubuntu/...)." "URL: ${url}"
    run_show "sudo dpkg -i ${deb}" dpkg -i "${tmpd}/${deb}"
    APT_FRESH=false
  fi
  if [[ $DRY_RUN != true ]] && ! command -v add-apt-repository >/dev/null 2>&1; then
    apt_install "sudo apt install software-properties-common -y" software-properties-common
  fi
  run add-apt-repository universe -y
  APT_FRESH=false
  apt_update

  # ---- 2.2 Packages --------------------------------------------------------------
  step 2.2 "Install Zabbix packages (agent 2, not the classic agent)"
  apt_install "sudo apt install ${ZBX_PACKAGES[*]} -y" "${ZBX_PACKAGES[@]}"
  if [[ $MODE == app ]]; then
    apt_install "sudo apt install mysql-client curl -y   # mysql CLI for step 2.3 (the guide assumes it)" mysql-client curl
  else
    apt_install "sudo apt install curl -y   # used by the final HTTP check" curl
  fi
  detect_php_fpm
  detect_schema_file

  # ---- 2.3 Schema import -------------------------------------------------------
  if [[ $MODE == app ]]; then step 2.3 "Import the schema into the remote DB node ${DB_IP}:${DB_PORT}"
  else step 2.3 "Import the schema"; fi
  import_schema "$db_host" "$db_port"

  # ---- 2.4 zabbix_server.conf ----------------------------------------------------
  step 2.4 "Point the server at the database (${ZBX_SERVER_CONF})"
  if [[ $DRY_RUN != true && ! -f $ZBX_SERVER_CONF ]]; then die "${ZBX_SERVER_CONF} is missing - did zabbix-server-mysql install? (step 2.2)"; fi
  backup_file "$ZBX_SERVER_CONF"
  edit_kv "$ZBX_SERVER_CONF" "" DBHost "$db_host" plain
  if [[ -n $db_port ]]; then
    edit_kv "$ZBX_SERVER_CONF" "" DBPort "$db_port" plain
  else
    _action "edit ${ZBX_SERVER_CONF}:  comment out DBPort= (local socket)"
    [[ $DRY_RUN == true ]] || kv_comment "$ZBX_SERVER_CONF" "" DBPort
  fi
  edit_kv "$ZBX_SERVER_CONF" "" DBName "$DB_NAME" plain
  edit_kv "$ZBX_SERVER_CONF" "" DBUser "$DB_USER" plain
  edit_kv --secret "$ZBX_SERVER_CONF" "" DBPassword "$DB_PASSWORD" plain

  # ---- 2.5 Apache modules ------------------------------------------------------
  step 2.5 "Configure Apache for PHP 8.5-FPM (proxy modules)"
  run a2enmod "${APACHE_MODS[@]}"
  _action "\$ sudo apache2ctl configtest"
  if [[ $DRY_RUN != true ]]; then
    local out
    if ! out=$(apache2ctl configtest 2>&1); then
      printf '%s\n' "$out" | _logpipe
      if [[ $out == *AH00526* ]]; then
        die "Apache: AH00526 Invalid command 'ProxyTimeout' - the proxy modules are not enabled." \
            "Fix: sudo a2enmod ${APACHE_MODS[*]} && sudo systemctl restart apache2"
      fi
      die "apache2ctl configtest failed (output above)."
    fi
    ok "Apache configuration OK"
  fi

  # ---- 2.5a PHP timezone ---------------------------------------------------------
  set_php_timezone

  # ---- 2.6 Locale ----------------------------------------------------------------
  step 2.6 "Generate the ${ZBX_LOCALE} locale"
  if [[ $DRY_RUN != true ]] && has_locale; then
    _action "\$ sudo locale-gen ${ZBX_LOCALE}"; skip "${ZBX_LOCALE} already generated"
  else
    if [[ $DRY_RUN != true ]] && ! command -v locale-gen >/dev/null 2>&1; then
      apt_install "sudo apt install locales -y" locales
    fi
    if [[ $DRY_RUN == true || -f $LOCALE_GEN ]]; then
      backup_file "$LOCALE_GEN"
      run_show "sudo sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' ${LOCALE_GEN}" \
        sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' "$LOCALE_GEN"
    fi
    run locale-gen "$ZBX_LOCALE"
  fi
  run update-locale "LANG=${ZBX_LOCALE}"
  if [[ $DRY_RUN != true ]]; then has_locale || die "Locale ${ZBX_LOCALE} is still missing (locale -a)."; fi

  # ---- 2.7 Services --------------------------------------------------------------
  step 2.7 "Start and enable services"
  [[ $DRY_RUN == true ]] || stop_zabbix_server
  run systemctl restart zabbix-server zabbix-agent2 apache2 "$PHP_FPM"
  run systemctl enable zabbix-server zabbix-agent2 apache2 "$PHP_FPM"
  if [[ $DRY_RUN != true ]]; then
    local s
    for s in zabbix-server zabbix-agent2 apache2 "$PHP_FPM"; do
      if svc_active "$s"; then ok "${s} active"; else warn "${s} is not active - sudo journalctl -u ${s} -n 50"; fi
    done
    if wait_for_listen "$ZBX_TRAPPER_PORT" 30; then ok "zabbix-server listening on ${ZBX_TRAPPER_PORT}"
    else warn "zabbix-server is not listening on ${ZBX_TRAPPER_PORT} yet - see ${ZBX_SERVER_LOG}"; fi
  fi

  # ---- 2.7a Firewall -------------------------------------------------------------
  step 2.7a "Open the firewall for the web UI (${HTTP_PORT}) and active agent checks (${ZBX_TRAPPER_PORT})"
  open_app_firewall

  # ---- 2.8 / 2.9 Manual ----------------------------------------------------------
  step 2.8 "Complete the frontend web wizard - manual, values in NEXT STEPS"
  step 2.9 "Log into the Zabbix website (Admin / zabbix) - manual, see NEXT STEPS"
}

# On stop, zabbix-server first flushes its history cache to the database. If
# the database moved (new port/IP on a re-run) that never finishes, and the
# packaged unit has no stop timeout - so allow 60 s, then kill it.
stop_zabbix_server() {
  svc_active zabbix-server || return 0
  info "stopping the running zabbix-server first (it flushes its cache to the DB)"
  if timeout 60 systemctl stop zabbix-server 2>&1 | _logpipe; then return 0; fi
  warn "zabbix-server did not stop within 60 s - its old database is unreachable. Killing it (unsent history is lost)."
  systemctl kill --signal=SIGKILL zabbix-server 2>&1 | _logpipe || true
  local i
  for ((i = 0; i < 15; i++)); do svc_active zabbix-server || break; sleep 1; done
  return 0
}

detect_php_fpm() {
  PHP_FPM=$DEFAULT_PHP_FPM
  [[ $DRY_RUN == true ]] && return 0
  local u
  u=$(systemctl list-unit-files --type=service --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | sort -V | tail -n1) || u=""
  [[ -n $u ]] && PHP_FPM=${u%.service}
  info "PHP-FPM service: ${PHP_FPM}"
  return 0
}
detect_schema_file() {
  local f
  for f in "${SCHEMA_CANDIDATES[@]}"; do
    if [[ -f $f ]]; then SCHEMA_FILE=$f; return 0; fi
  done
  [[ $DRY_RUN == true ]] && return 0
  f=$(dpkg -L zabbix-sql-scripts 2>/dev/null | grep -m1 '/mysql/server.sql.gz$' || true)
  [[ -n $f ]] || die "Cannot find mysql/server.sql.gz from zabbix-sql-scripts (step 2.2)."
  SCHEMA_FILE=$f
}
has_locale() { local l; l=$(locale -a 2>/dev/null || true); [[ ${l,,} == *en_us.utf8* || ${l,,} == *en_us.utf-8* ]]; }

# Step 2.3: test the login, import (skipped if already there), reset trust.
import_schema() {
  local host=$1 port=$2 shown_conn out state flags rc=0 errf
  if [[ $MODE == app ]]; then
    shown_conn="mysql -h ${host} -P ${port} -u ${DB_USER} -p"
  else
    shown_conn="mysql -u ${DB_USER} -p"
  fi
  make_cnf "$DB_USER" "$DB_PASSWORD"
  set_db_target "$host" "$port"

  _action "\$ ${shown_conn} ${DB_NAME} -e 'SELECT VERSION();'   # test the connection first"
  if [[ $DRY_RUN != true ]]; then
    out=$(mysql_zbx "$DB_NAME" -e "SELECT VERSION()" 2>&1) || die "Cannot log in to ${DB_NAME} as ${DB_USER}: $(explain_mysql_error "$out")"
    ok "connected - MySQL ${out}"
    state=$(schema_state mysql_zbx)
  else
    state=none
  fi

  _action "\$ zcat ${SCHEMA_FILE} | ${shown_conn} --default-character-set=utf8mb4 ${DB_NAME}   # 1-2 minutes"
  case $state in
    full)
      skip "schema already imported (dbversion and users tables present)" ;;
    partial)
      die "The database '${DB_NAME}' holds a PARTIAL schema - importing again would stop with ERROR 1050 (table already exists)." \
          "Recreate it on the DB node:  sudo ./zabbix-setup.sh --mode $([[ $MODE == app ]] && echo db || echo single) --reset" ;;
    *)
      if [[ $DRY_RUN != true ]]; then
        flags=$(mysql_zbx -e "SELECT CONCAT(@@GLOBAL.log_bin, ' ', @@GLOBAL.log_bin_trust_function_creators)" 2>/dev/null || echo "")
        if [[ $flags == "1 0" ]]; then
          die "log_bin_trust_function_creators is 0 on the DB server - the import would fail (ERROR 1419)." \
              "On the DB node run:  sudo mysql -e 'SET GLOBAL log_bin_trust_function_creators = 1;'  (or re-run --mode db), then re-run this."
        fi
        info "importing ${SCHEMA_FILE} - this takes 1-2 minutes..."
        errf=$(mktemp); TMP_PATHS+=("$errf")
        zcat "$SCHEMA_FILE" | mysql_zbx --default-character-set=utf8mb4 "$DB_NAME" 2>"$errf" || rc=$?
        if ((rc != 0)); then
          _logpipe <"$errf"
          if grep -q "ERROR 1050" "$errf" && [[ $(schema_state mysql_zbx) == full ]]; then
            warn "ERROR 1050: the tables already existed - schema is complete, continuing."
          elif grep -q "ERROR 1050" "$errf"; then
            die "ERROR 1050 (table already exists): a partial schema is in the way." \
                "Recreate the database on the DB node with --reset, then re-run this step."
          else
            die "Schema import failed: $(explain_mysql_error "$(<"$errf")")"
          fi
        else
          ok "schema imported"
        fi
      fi
      ;;
  esac

  # Trust back to 0 (guide: "reconnect to the DB node and turn it off").
  if [[ $MODE == single ]]; then
    run_sql_root "SET GLOBAL log_bin_trust_function_creators = 0;" "SET GLOBAL log_bin_trust_function_creators = 0;"
  else
    _action "on the DB node ${DB_IP}:  mysql> SET GLOBAL log_bin_trust_function_creators = 0;"
    [[ $DRY_RUN == true ]] && return 0
    # The zabbix account normally lacks the privilege; then the DB node does it.
    if [[ $(mysql_zbx -e "SELECT @@GLOBAL.log_bin_trust_function_creators" 2>/dev/null || true) == 0 ]]; then
      ok "log_bin_trust_function_creators is already 0 on ${DB_IP}"
    elif mysql_zbx -e "SET GLOBAL log_bin_trust_function_creators = 0" >/dev/null 2>&1; then
      ok "log_bin_trust_function_creators = 0 on ${DB_IP}"
    else
      TRUST_PENDING=true
      warn "ACTION ON THE DB SERVER (${DB_IP}): the zabbix account may not change global settings. Run there:"
      warn "    sudo mysql -e 'SET GLOBAL log_bin_trust_function_creators = 0;'"
      warn "  or re-run  sudo ./zabbix-setup.sh --mode db --yes  (it sees the imported schema and sets 0)."
    fi
  fi
}

# Step 2.5a: find where THIS install's PHP for Zabbix takes date.timezone.
# Inspects /etc/zabbix/*.conf and the php-fpm pools instead of assuming.
set_php_timezone() {
  step 2.5a "Set the PHP timezone for the Zabbix frontend (${TIMEZONE}) - the wizard checks it"
  local ver=${PHP_FPM#php}; ver=${ver%-fpm}
  if [[ $DRY_RUN == true ]]; then
    _action "inspect ${ZBX_APACHE_CONF} (SetHandler proxy:unix:<socket>) and /etc/zabbix/*.conf, /etc/php/${ver}/fpm/pool.d/*.conf for the pool listening on that socket"
    backup_file "$ZBX_PHP_POOL_GUESS"
    edit_kv "$ZBX_PHP_POOL_GUESS" zabbix "php_value[date.timezone]" "$TIMEZONE" ini
    run systemctl restart "$PHP_FPM"
    return 0
  fi
  local sock="" f real content pool="" section="" l cur="" v
  local -A seen=()
  local -a cands=()
  local re_sock='proxy:unix:([^|"[:space:]]+)' re_sec='^[[:space:]]*\[([^]]+)\]' re_listen='^[[:space:]]*listen[[:space:]]*=[[:space:]]*([^[:space:];]+)'
  # 1. Which socket does Apache hand Zabbix's PHP files to?
  for f in "$ZBX_APACHE_CONF" /etc/apache2/conf-enabled/zabbix.conf; do
    [[ -r $f ]] || continue
    content=$(<"$f")
    if [[ $content =~ $re_sock ]]; then sock=${BASH_REMATCH[1]}; break; fi
  done
  info "Apache sends Zabbix PHP to: ${sock:-<no FPM socket found>}"
  # 2. Which pool listens on that socket?
  for f in /etc/zabbix/*.conf /etc/php/*/fpm/pool.d/*.conf; do
    [[ -f $f ]] || continue
    real=$(readlink -f "$f")
    [[ -n ${seen[$real]:-} ]] && continue
    seen[$real]=1; cands+=("$real")
  done
  for f in "${cands[@]}"; do
    cur=""
    while IFS= read -r l || [[ -n $l ]]; do
      if [[ $l =~ $re_sec ]]; then cur=${BASH_REMATCH[1]}; continue; fi
      if [[ $l =~ $re_listen ]]; then
        v=${BASH_REMATCH[1]}
        if [[ -n $sock && ${v#/var} == "${sock#/var}" ]]; then pool=$f; section=$cur; break 2; fi
      fi
    done <"$f"
  done
  if [[ -n $pool ]]; then
    info "PHP-FPM pool [${section}] in ${pool} serves the frontend"
    backup_file "$pool"
    edit_kv "$pool" "$section" "php_value[date.timezone]" "$TIMEZONE" ini
  else
    local ini="/etc/php/${ver}/fpm/php.ini"
    [[ -f $ini ]] || die "Could not find the PHP-FPM pool for Zabbix nor ${ini}. Set date.timezone = ${TIMEZONE} by hand."
    warn "no Zabbix-specific FPM pool found - using ${ini}"
    backup_file "$ini"
    edit_kv "$ini" Date date.timezone "$TIMEZONE" ini
  fi
  if a2query -m "php${ver}" >/dev/null 2>&1; then
    warn "mod_php is also enabled - the php_value date.timezone line in ${ZBX_APACHE_CONF} applies to it; edit it by hand if you use mod_php."
  fi
  run systemctl restart "$PHP_FPM"
}

open_app_firewall() {
  local st p
  if [[ $DRY_RUN == true ]]; then
    _action "\$ sudo ufw status"
    _action "\$ sudo ufw allow ${HTTP_PORT}/tcp   # only if ufw is active - web UI"
    _action "\$ sudo ufw allow ${ZBX_TRAPPER_PORT}/tcp   # only if ufw is active - active checks from the Windows agent"
    return 0
  fi
  st=$(ufw_state)
  _action "\$ sudo ufw status   # -> ${st}"
  if [[ $st != active ]]; then
    skip "ufw is ${st} - nothing to open (this script never enables ufw)"
    FW_SKIPPED+=("${HTTP_PORT}/tcp" "${ZBX_TRAPPER_PORT}/tcp")
  else
    for p in "$HTTP_PORT" "$ZBX_TRAPPER_PORT"; do
      run ufw allow "${p}/tcp"
      FW_CHANGED+=("allow ${p}/tcp")
    done
  fi
  say "      firewall changed: ${FW_CHANGED[*]:-nothing}   skipped: ${FW_SKIPPED[*]:-nothing}"
}

# =============================================================================
# 9. Hand-off (db), NEXT STEPS (app/single). The password appears ONLY on the
#    terminal and in the chmod-600 file - the log gets the masked version.
# =============================================================================
render_handoff() {   # render_handoff PASSWORD_OR_MASK
  local pwline="DB_PASSWORD=$1"
  [[ -z $1 ]] && pwline="# DB_PASSWORD unchanged (kept on a re-run) - use the value from the first run"
  cat <<EOF
###########################################################################
#  zabbix-setup hand-off - values for the APP server  ($(date '+%F %T'))
###########################################################################
DB_IP=${DB_IP}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
${pwline}
APP_IP=${APP_IP}

Next, on the APP server (${APP_IP}), with this same script:
  sudo ./zabbix-setup.sh --mode app --app-ip ${APP_IP} --db-ip ${DB_IP} --db-port ${DB_PORT} --db-name ${DB_NAME} --db-user ${DB_USER} --timezone ${TIMEZONE}
It prompts for the password. Or copy this file over securely (scp) and add:
  --db-password-file ./zabbix-handoff.txt
Delete this file once the app server is done.

When the app server has imported the schema, come back to THIS server and run:
  sudo ./zabbix-setup.sh --mode db --yes
(it detects the schema and sets log_bin_trust_function_creators back to 0)
###########################################################################
EOF
}

render_next_steps() {   # render_next_steps PASSWORD_OR_MASK
  local pw=$1 host port port_note wh=${WIN_HOSTNAME:-<WIN_HOSTNAME>} wi=${WIN_IP:-<WIN_IP>}
  if [[ $MODE == app ]]; then
    host=$DB_IP; port=$DB_PORT
    port_note="type it explicitly - 0 means 3306 and the test would fail"
  elif [[ $SINGLE_CUSTOM_PORT == true ]]; then
    host=localhost; port=$DB_PORT; port_note="custom port chosen for this VM"
  else
    host=localhost; port=0; port_note="0 = default (local socket)"
  fi
  [[ -z $pw ]] && pw="<unchanged - the password from the first run>"
  cat <<EOF
###########################################################################
#  NEXT STEPS (manual)  - ${MODE} setup on ${APP_IP}, $(date '+%F %T')
###########################################################################
EOF
  if [[ $TRUST_PENDING == true ]]; then
    cat <<EOF

0. FIRST, on the DB server ${DB_IP} (finishes guide Part 2 step 3):
     sudo mysql -e 'SET GLOBAL log_bin_trust_function_creators = 0;'
   or: sudo ./zabbix-setup.sh --mode db --yes
EOF
  fi
  cat <<EOF

1. Web setup wizard  (guide Part 2, steps 8-9)
   Open      http://${APP_IP}/zabbix
   Database type   MySQL
   Database host   ${host}
   Database port   ${port}      (${port_note})
   Database name   ${DB_NAME}
   User            ${DB_USER}
   Password        ${pw}
   Time zone       ${TIMEZONE}
   Then log in as  Admin / zabbix   and change it IMMEDIATELY:
                   Users > Users > Admin > Change password

2. Windows 11 - install Zabbix agent 2  (guide Part 3, step 1)
   Download from https://www.zabbix.com/download_agents :
     Zabbix ${ZBX_VERSION} LTS, Windows, amd64, OpenSSL, MSI  -> run it.
   In the installer, or afterwards in ${WIN_AGENT_DIR}\\zabbix_agent2.conf:
     Hostname=${wh}
     Server=${APP_IP}
     ServerActive=${APP_IP}

3. Windows firewall  (guide Part 3, step 2) - PowerShell as Administrator:
     New-NetFirewallRule -DisplayName "Zabbix Agent Port ${ZBX_AGENT_PORT}" -Direction Inbound -Protocol TCP -LocalPort ${ZBX_AGENT_PORT} -Action Allow
     Restart-Service "Zabbix Agent 2"

4. Add the host in the web UI  (guide Part 3, step 3)
   Data collection > Hosts > Create host
     Host name    ${wh}   (identical to Hostname= - case-sensitive)
     Host groups  pick or type one, e.g. "Windows hosts"
     Interfaces   Add > Agent: IP ${wi}, port ${ZBX_AGENT_PORT}
                  (the template needs an Agent interface even for active checks)
     Templates    Windows by Zabbix agent

5. Verify
   On Windows (PowerShell):  Test-NetConnection ${APP_IP} -Port ${ZBX_TRAPPER_PORT}   -> TcpTestSucceeded : True
   Web UI: Monitoring > Latest data, host ${wh} - CPU, memory, disk within minutes
   Agent log: ${WIN_AGENT_DIR}\\zabbix_agent2.log
   On this server, any time:  sudo ./zabbix-setup.sh --verify
###########################################################################
EOF
}

# Show a block with the real password on the terminal only, save it (600),
# and record only the masked version in the log.
emit_secret_block() {   # emit_secret_block RENDER_FN FILE
  local fn=$1 file=$2 pw=$DB_PASSWORD line
  if [[ $DRY_RUN == true ]]; then
    while IFS= read -r line; do say "$line"; done < <("$fn" "$MASK")
    return 0
  fi
  printf '\n'
  "$fn" "$pw"
  "$fn" "$pw" | write_private "$file"
  if [[ $LOG_ON == true ]]; then
    while IFS= read -r line; do _record "$line"; done < <("$fn" "$MASK")
  fi
  printf '\n%s\n' "Saved to ${file} (chmod 600). The password above is shown once and is not in ${LOG_FILE}."
}

# =============================================================================
# 10. --verify: PASS/WARN/FAIL health check (also the end-of-run summary)
# =============================================================================
vc_service() {
  if svc_active "$1"; then vrow PASS "service $1 active" ""
  else vrow FAIL "service $1 active" "$(systemctl is-active "$1" 2>/dev/null || true)" "sudo systemctl enable --now $1; sudo journalctl -u $1 -n 50"; fi
}
vc_listen() {   # vc_listen PORT LABEL FIX
  local a; a=$(listen_addrs "$1")
  if [[ -n $a ]]; then vrow PASS "$2 listening on $1" "$a"; else vrow FAIL "$2 listening on $1" "nothing listening" "$3"; fi
}
vc_chrony() {
  if ! svc_active chrony; then vrow FAIL "chrony time sync" "chrony not running" "sudo apt install -y chrony && sudo systemctl enable --now chrony"
  elif chrony_synced; then vrow PASS "chrony time sync" "synchronised"
  else vrow WARN "chrony time sync" "running, not synchronised yet" "chronyc sources -v (UDP 123 outbound must be allowed)"; fi
}
vc_ufw() {      # vc_ufw PORT [FROM_IP]
  local port=$1 from=${2:-} st out line found="" broad="" re
  st=$(ufw_state)
  if [[ $st != active ]]; then vrow PASS "ufw allows ${port}/tcp" "ufw ${st} - nothing to check"; return 0; fi
  out=$(ufw status 2>/dev/null || true)
  re="^${port}(/tcp)?[[:space:]]+ALLOW"
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    if [[ -n $from && $line == *"$from"* ]]; then found=$line; fi
    if [[ $line == *Anywhere* ]]; then broad=$line; fi
  done <<<"$out"
  local fix="sudo ufw allow ${port}/tcp"
  [[ -n $from ]] && fix="sudo ufw allow from ${from} to any port ${port} proto tcp"
  if [[ -n $found ]]; then vrow PASS "ufw allows ${port}/tcp${from:+ from ${from}}" "rule present"
  elif [[ -n $broad && -n $from ]]; then vrow WARN "ufw allows ${port}/tcp from ${from}" "open to Anywhere" "scope it: ${fix}"
  elif [[ -n $broad ]]; then vrow PASS "ufw allows ${port}/tcp" "rule present"
  else vrow FAIL "ufw allows ${port}/tcp${from:+ from ${from}}" "no rule" "$fix"; fi
}

# MySQL-side checks shared by db and single
vc_mysql_local() {
  local host=$1 n trust state
  vc_service mysql
  if ! mysql_root -e "SELECT 1" >/dev/null 2>&1; then
    vrow FAIL "MySQL root login (sudo mysql)" "failed" "sudo systemctl status mysql; root must use auth_socket or /root/.my.cnf"
    return 0
  fi
  state=$(schema_state mysql_root)
  case $state in
    full) vrow PASS "database ${DB_NAME} has the schema" "$(mysql_root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'") tables" ;;
    none) if [[ $MODE == db ]]; then vrow WARN "database ${DB_NAME} has the schema" "exists, still empty" "run app mode on ${APP_IP} (Part 2 step 3)"
          else vrow FAIL "database ${DB_NAME} has the schema" "exists, empty" "re-run: sudo ./zabbix-setup.sh --mode single"; fi ;;
    partial) vrow FAIL "database ${DB_NAME} has the schema" "partial import" "sudo ./zabbix-setup.sh --mode ${MODE} --reset, then import again" ;;
    *) vrow FAIL "database ${DB_NAME} exists" "missing" "re-run: sudo ./zabbix-setup.sh --mode ${MODE}" ;;
  esac
  n=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='${host}'" 2>/dev/null || echo 0)
  if [[ $n == 1 ]]; then vrow PASS "user '${DB_USER}'@'${host}' exists" ""
  else vrow FAIL "user '${DB_USER}'@'${host}' exists" "missing" "re-run: sudo ./zabbix-setup.sh --mode ${MODE}"; fi
  trust=$(mysql_root -e "SELECT @@GLOBAL.log_bin_trust_function_creators" 2>/dev/null || echo "?")
  if [[ $trust == 0 ]]; then vrow PASS "log_bin_trust_function_creators = 0" ""
  elif [[ $state != full ]]; then vrow WARN "log_bin_trust_function_creators = 0" "1 (expected until the schema is imported)"
  else vrow FAIL "log_bin_trust_function_creators = 0" "is ${trust}" "sudo mysql -e 'SET GLOBAL log_bin_trust_function_creators = 0;'"; fi
  return 0
}

verify_db() {
  local bind remote extra=""
  vc_mysql_local "$APP_IP" || true
  vc_listen "$DB_PORT" "MySQL" "set port = ${DB_PORT} in ${MYSQLD_CNF}; sudo systemctl restart mysql"
  bind=$(mysql_root -e "SELECT @@GLOBAL.bind_address" 2>/dev/null || echo "?")
  if [[ $bind == 0.0.0.0 || $bind == "*" ]]; then vrow PASS "bind-address is 0.0.0.0" "$bind"
  else vrow FAIL "bind-address is 0.0.0.0" "is ${bind}" "bind-address = 0.0.0.0 under [mysqld] in ${MYSQLD_CNF}; sudo systemctl restart mysql"; fi
  vc_ufw "$DB_PORT" "$APP_IP"
  remote=$(mysql_root -e "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE host NOT IN ('localhost','127.0.0.1','::1') ORDER BY 1" 2>/dev/null || echo "?")
  local a
  for a in $remote; do [[ $a == "${DB_USER}@${APP_IP}" ]] || extra+="${a} "; done
  if [[ $remote == "${DB_USER}@${APP_IP}" ]]; then vrow PASS "only remote account is ${DB_USER}@${APP_IP}" ""
  elif [[ -n $extra ]]; then vrow FAIL "only remote account is ${DB_USER}@${APP_IP}" "also: ${extra% }" "remove unused ones: sudo mysql -e \"DROP USER 'name'@'host';\""
  else vrow FAIL "only remote account is ${DB_USER}@${APP_IP}" "none found" "re-run: sudo ./zabbix-setup.sh --mode db"; fi
  vc_chrony
}

verify_app() {
  local s h p n u pw out m code recent errs
  for s in zabbix-server zabbix-agent2 apache2 "$PHP_FPM"; do vc_service "$s"; done
  vc_listen "$ZBX_TRAPPER_PORT" "zabbix-server" "check ${ZBX_SERVER_LOG}; sudo systemctl restart zabbix-server"
  for m in "${APACHE_MODS[@]}"; do
    if a2query -m "$m" >/dev/null 2>&1; then vrow PASS "Apache module ${m} enabled" ""
    else vrow FAIL "Apache module ${m} enabled" "disabled" "sudo a2enmod ${APACHE_MODS[*]} && sudo systemctl restart apache2"; fi
  done
  if has_locale; then vrow PASS "locale ${ZBX_LOCALE} exists" ""
  else vrow FAIL "locale ${ZBX_LOCALE} exists" "missing" "sudo locale-gen ${ZBX_LOCALE} && sudo systemctl restart ${PHP_FPM}"; fi
  # DB login with exactly what zabbix-server uses
  if [[ ! -r $ZBX_SERVER_CONF ]]; then
    vrow FAIL "DB login with zabbix_server.conf" "${ZBX_SERVER_CONF} unreadable" "re-run the setup"
  else
    h=$(kv_get "$ZBX_SERVER_CONF" "" DBHost || true); p=$(kv_get "$ZBX_SERVER_CONF" "" DBPort || true)
    n=$(kv_get "$ZBX_SERVER_CONF" "" DBName || true); u=$(kv_get "$ZBX_SERVER_CONF" "" DBUser || true)
    pw=$(kv_get "$ZBX_SERVER_CONF" "" DBPassword || true)
    make_cnf "$u" "$pw"; set_db_target "$h" "$p"
    if out=$(mysql_zbx "$n" -e "SELECT 1" 2>&1); then
      vrow PASS "DB login with zabbix_server.conf" "${u}@${h:-localhost}${p:+:$p}/${n}"
      local saved=$DB_NAME; DB_NAME=$n
      case $(schema_state mysql_zbx) in
        full) vrow PASS "schema present in ${n}" "dbversion + users found" ;;
        *)    vrow FAIL "schema present in ${n}" "not (fully) imported" "re-run setup (Part 2 step 3); partial -> --reset on the DB node" ;;
      esac
      DB_NAME=$saved
    else
      vrow FAIL "DB login with zabbix_server.conf" "$(explain_mysql_error "$out")" "check DBHost/DBPort/DBName/DBUser/DBPassword in ${ZBX_SERVER_CONF}"
    fi
  fi
  # zabbix_server.log since the last start
  if [[ -r $ZBX_SERVER_LOG ]]; then
    recent=$(tail -n 400 "$ZBX_SERVER_LOG" | awk '/Starting Zabbix Server/ {buf=""} {buf = buf $0 ORS} END {printf "%s", buf}') || recent=""
    errs=$(grep -Ei 'database is down|connection to database .* failed|cannot (connect|use) (to )?(the )?database|Access denied for user|\[Z300[0-9]\]' <<<"$recent" || true)
    if [[ -z $errs ]]; then vrow PASS "no DB errors in zabbix_server.log" "since last start"
    else vrow FAIL "no DB errors in zabbix_server.log" "${errs%%$'\n'*}" "fix the DB* settings / reachability, then sudo systemctl restart zabbix-server"; fi
  else
    vrow WARN "no DB errors in zabbix_server.log" "${ZBX_SERVER_LOG} not found"
  fi
  code=$(http_code "http://localhost/zabbix")
  if [[ $code == 200 || $code == 206 ]]; then vrow PASS "frontend http://localhost/zabbix" "HTTP ${code}"
  else vrow FAIL "frontend http://localhost/zabbix" "HTTP ${code}" "sudo apache2ctl configtest; sudo systemctl restart apache2 ${PHP_FPM}; tail /var/log/apache2/error.log"; fi
  vc_ufw "$HTTP_PORT"
  vc_ufw "$ZBX_TRAPPER_PORT"
}

verify_single() {
  vc_mysql_local localhost || true
  if [[ -n $DB_PORT && $DB_PORT != 0 ]]; then
    vc_listen "$DB_PORT" "MySQL" "set port = ${DB_PORT} in ${MYSQLD_CNF}; sudo systemctl restart mysql"
  fi
  verify_app
  vc_chrony
}

mysql_port_report() {
  local port addrs
  case $MODE in
    db|single)
      port=$(mysql_root -e "SELECT @@port" 2>/dev/null || echo "?")
      addrs=$(listen_addrs "$port")
      say "  MySQL is actually listening on port ${port}: ${addrs:-<not listening>}"
      if [[ $MODE == single && ${DB_PORT:-0} == 0 ]]; then say "  (Zabbix connects through the local socket - wizard port 0)"; fi ;;
    app)
      if [[ -r $ZBX_SERVER_CONF ]]; then
        make_cnf "$(kv_get "$ZBX_SERVER_CONF" "" DBUser || true)" "$(kv_get "$ZBX_SERVER_CONF" "" DBPassword || true)"
        set_db_target "$(kv_get "$ZBX_SERVER_CONF" "" DBHost || true)" "$(kv_get "$ZBX_SERVER_CONF" "" DBPort || true)"
        port=$(mysql_zbx -e "SELECT @@port" 2>/dev/null || echo "?")
        say "  MySQL on ${DB_IP:-the DB server} reports it listens on port ${port}"
      fi ;;
  esac
  return 0
}

run_verify() {   # returns 1 if any FAIL
  V_ROWS=(); V_FAILS=0; V_WARNS=0
  part "Verification (${MODE})"
  case $MODE in
    db) verify_db ;;
    app) verify_app; vc_chrony ;;
    single) verify_single ;;
  esac
  print_rows
  mysql_port_report
  if ((V_FAILS > 0)); then _emit "$C_RED" "  Result: ${V_FAILS} FAIL, ${V_WARNS} WARN"; return 1; fi
  _emit "$C_GREEN" "  Result: all checks passed (${V_WARNS} WARN)"
  return 0
}

# --verify without a state file: work out the role from installed packages.
resolve_verify_settings() {
  load_state
  local srv=false my=false
  pkg_installed zabbix-server-mysql && srv=true
  pkg_installed mysql-server && my=true
  if [[ -z $MODE ]]; then
    if [[ -n $ST_MODE ]]; then MODE=$ST_MODE
    elif [[ $srv == true && $my == true ]]; then MODE=single
    elif [[ $srv == true ]]; then MODE=app
    elif [[ $my == true ]]; then MODE=db
    else die "Nothing to verify: neither zabbix-server-mysql nor mysql-server is installed."; fi
    [[ -n $ST_MODE ]] || warn "No ${STATE_FILE} - role detected from installed packages: ${MODE}"
  fi
  [[ -n $APP_IP ]] || APP_IP=$ST_APP_IP
  [[ -n $DB_IP ]] || DB_IP=$ST_DB_IP
  [[ -n $DB_PORT ]] || DB_PORT=$ST_DB_PORT
  [[ -n $DB_NAME ]] || DB_NAME=${ST_DB_NAME:-$DEFAULT_DB_NAME}
  [[ -n $DB_USER ]] || DB_USER=${ST_DB_USER:-$DEFAULT_DB_USER}
  if [[ $MODE == db ]]; then
    [[ -n $DB_PORT ]] || DB_PORT=$(mysql_root -e "SELECT @@port" 2>/dev/null || echo "$MYSQL_DEFAULT_PORT")
    [[ -n $APP_IP ]] || APP_IP=$(mysql_root -e "SELECT host FROM mysql.user WHERE user='${DB_USER}' AND host NOT IN ('localhost','127.0.0.1','::1') LIMIT 1" 2>/dev/null || true)
  fi
  if [[ $MODE == app && -z $DB_IP ]]; then DB_IP=$(kv_get "$ZBX_SERVER_CONF" "" DBHost || true); fi
  detect_php_fpm >/dev/null
  return 0
}

# =============================================================================
# 11. main
# =============================================================================
init_output() {
  if [[ $DRY_RUN == true ]]; then
    MANUAL_FILE=$MANUAL_STEPS_FILE
    : >"$MANUAL_FILE" || die "Cannot write ${MANUAL_FILE}"
    give_to_sudo_user "$MANUAL_FILE"
    return 0
  fi
  [[ $EUID -eq 0 ]] || die "Run as root:  sudo $0 ${ARGS_TEXT}" "(--dry-run works without root)"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  LOG_ON=true
  _record "===== zabbix-setup.sh ${SCRIPT_VERSION} started: ${ARGS_TEXT:-<no arguments>} ====="
}

main() {
  parse_args "$@"
  if [[ $SHOW_HELP == true ]]; then usage; exit 0; fi
  init_output
  _emit "$C_BOLD" "zabbix-setup.sh ${SCRIPT_VERSION} - Zabbix ${ZBX_VERSION} LTS on Ubuntu ${TARGET_UBUNTU}$([[ $DRY_RUN == true ]] && echo '   [DRY RUN - nothing will be changed]')"
  [[ $LOG_ON == true ]] && say "Log: ${LOG_FILE}"

  # --verify ------------------------------------------------------------------
  if [[ $DO_VERIFY == true ]]; then
    [[ $DRY_RUN == true ]] && die "--verify and --dry-run do not combine."
    resolve_verify_settings
    local rc=0
    run_verify || rc=$?
    exit "$rc"
  fi

  # --add-user on its own ---------------------------------------------------------
  if [[ -n $ADD_USER && -z $MODE ]]; then
    part "Part 0 - Preparation"
    add_admin_user
    exit 0
  fi

  load_state
  choose_mode
  if [[ $DRY_RUN == true ]]; then
    say "Scenario: ${MODE}. Every command below is numbered with the guide's Part.Step."
    say "Saved to: ${MANUAL_FILE} (password masked)."
  fi
  collect_inputs
  show_summary
  if [[ $DRY_RUN != true && $ASSUME_YES != true ]]; then
    ask_yn "Proceed with these settings?" y || die "Stopped - nothing was changed."
  fi

  preflight                                   # 0.1
  [[ -n $ADD_USER ]] && add_admin_user        # 0.2
  apply_static_ip                             # 0.3
  setup_time                                  # 0.4

  case $MODE in
    db)     part1_database ;;
    app)    part2_app ;;
    single) part1_database; part2_app ;;
  esac

  if [[ $MODE != db ]]; then part "Part 3 - Windows 11 agent (manual - see NEXT STEPS)"; fi

  if [[ $DRY_RUN == true ]]; then
    part "Final blocks this run would print (password masked)"
    if [[ $MODE == db ]]; then emit_secret_block render_handoff "$HANDOFF_FILE"
    else emit_secret_block render_next_steps "$NEXT_STEPS_FILE"; fi
    say ""
    say "DRY RUN complete - nothing was changed. Steps saved to ${MANUAL_FILE}"
    exit 0
  fi

  write_state
  local vrc=0
  run_verify || vrc=$?
  say ""
  say "  Backups of edited files: ${BACKUP_DIR}$([[ -d $BACKUP_DIR ]] || echo ' (none needed)')"
  say "  Log: ${LOG_FILE}"
  if [[ $MODE == db ]]; then
    emit_secret_block render_handoff "$HANDOFF_FILE"
  else
    emit_secret_block render_next_steps "$NEXT_STEPS_FILE"
  fi
  if ((vrc != 0)); then
    err "Setup finished but verification reported FAIL - see the fixes in the table above."
    exit 1
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
