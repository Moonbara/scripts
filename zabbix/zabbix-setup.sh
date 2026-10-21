#!/usr/bin/env bash
# =============================================================================
#  zabbix-setup.sh - server-side automation of zabbix-3tier-setup-guide.md
#  Zabbix 8.0 LTS | Ubuntu 26.04 | MySQL 8 | Apache + PHP 8.5-FPM | Agent 2
# -----------------------------------------------------------------------------
#  Copy this same file to every server and run it there with sudo, or start
#  it in one line:  sudo bash -c 'bash <(curl -fsSL <SCRIPT_URL>) "$@"' _ [options]
#
#    menu 1 / --mode single   Zabbix + MySQL on this VM          (Part 1 + 2)
#    menu 2 / --mode db       two VMs: this is the DATABASE node (Part 1) FIRST
#    menu 3 / --mode app      two VMs: this is the APP/WEB node  (Part 2) SECOND
#
#  Values come from flags, ZBX_* environment variables, an env file
#  (--env-file, or ./zabbix-setup.env) or prompts - whiptail dialogs on a
#  terminal, plain text prompts otherwise (--no-dialog).
#
#  Part 3 (the Windows 11 agent) is NOT automated. The run ends with a
#  NEXT STEPS block holding the exact values to type on Windows and in the UI.
#
#  Output: one line per step, redrawn in place ([✗] while it runs, [✓] when
#  done, [-] when skipped). --verbose (-v, ZBX_VERBOSE=1) shows every command
#  ($ ...) and its live output instead. Piped / non-terminal output gets plain
#  [..] / [OK] / [FAIL] lines. The full output always goes to the log
#  (/var/log/zabbix-setup.log), never with the password.
#
#  Step numbers printed by the script (and by --dry-run) are the guide's
#  Part.Step numbers, so the output doubles as a revision sheet. Work the guide
#  does not contain is marked:
#    Part 0       preparation: 0.1 preflight, 0.2 admin user, 0.3 static IP,
#                 0.4 time sync + timezone
#    1.6          optional Agent 2 on the database server (db mode)
#    2.5a / 2.7a  extra sub-steps: PHP timezone, firewall for web + agents
#  Firewall: step 1.3 (db) / 2.7a (app, single) ENABLES ufw after a yes to
#  the listed rules - SSH first - unless --no-ufw / ZBX_ENABLE_UFW=no.
#  Every run ends with the REMEMBER: ZABBIX WEB WIZARD block (the password
#  is printed only there).
#
#  Map of this file:
#     0. constants and defaults        6. Part 0 (steps 0.2 - 0.4)
#     1. output, logging, run()        7. Part 1 - database node (1.1 - 1.6)
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
readonly SCRIPT_VERSION="1.5.0"
# Optional: where the script is published. Only used to print the one-line
# launch command (leave it empty to print <URL> instead). Pin a tag or a
# commit instead of main for anything you rely on.
readonly SCRIPT_URL="https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh"
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
readonly ZBX_AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
readonly ZBX_DEFAULT_AGENT_HOST="Zabbix server"   # package default = the built-in host
readonly UFW_COMMENT="zabbix-setup"   # every ufw rule this script adds carries it
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
readonly DEFAULT_ENV_FILE="${OUT_DIR}/zabbix-setup.env"

# How to start this script again, for the messages it prints. Run from a file
# -> ./zabbix-setup.sh. Run as the one-liner  bash <(curl ...)  the "file" is
# a pipe (/dev/fd/N), and with  bash -c "$(curl ...)"  there is none
# (BASH_SOURCE empty) -> print the one-liner. $0 is never used.
# (bash -c "$(curl ...)" no longer works for this script: Linux refuses a
# single argument over 128 KiB, and the script is bigger than that.)
if [[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != /dev/fd/* && ${BASH_SOURCE[0]} != /proc/*/fd/* ]]; then
  LAUNCH="./zabbix-setup.sh"
else
  LAUNCH="bash -c 'bash <(curl -fsSL ${SCRIPT_URL:-<URL>}) \"\$@\"' _"
fi
readonly LAUNCH

# --- Run options (set by flags) ---------------------------------------------
DRY_RUN=false; DO_VERIFY=false; RESET=false; FORCE=false; ASSUME_YES=false
SHOW_HELP=false; ADD_USER=""; PW_FILE=""; ARGS_TEXT=""
ENV_FILE=""; NO_ENV_PASSWORD=false; APPLY_NETWORK=false; NO_DIALOG=false
USE_DIALOG=false; RESET_CONFIRMED=false

# --- Inputs: every one can come from a flag, a ZBX_* environment variable,
#     an env file or a prompt (in that priority). SRC[VAR] remembers where a
#     value came from. Only ZBX_-prefixed names are read from the
#     environment, so a stray MODE or DNS in a root shell is never picked up.
#     The internal names (MODE, DB_PORT, ...) stay unprefixed.
declare -A SRC=()
readonly -a INPUT_VARS=(MODE APP_IP DB_IP DB_PORT DB_NAME DB_USER TIMEZONE WIN_HOSTNAME WIN_IP
                        IFACE STATIC_IP PREFIX GATEWAY DNS SSH_KEY_FILE INSTALL_AGENT AGENT_HOSTNAME VERBOSE ENABLE_UFW SSH_PORT)
for _v in "${INPUT_VARS[@]}"; do
  _e="ZBX_${_v}"
  if [[ -n ${!_e:-} ]]; then printf -v "$_v" '%s' "${!_e}"; SRC[$_v]="environment ${_e}"
  else printf -v "$_v" '%s' ""; fi
done
unset _v _e
# The password is never a flag. From the environment (ZBX_DB_PASSWORD, or the
# deprecated DB_PASSWORD) it is read once and then un-exported, so apt, mysql
# and other children never inherit it.
PW_ORIGIN=""; PW_ENV_DEPRECATED=false
if [[ -n ${ZBX_DB_PASSWORD:-} ]]; then
  DB_PASSWORD=$ZBX_DB_PASSWORD; PW_ORIGIN="environment ZBX_DB_PASSWORD"
elif [[ -n ${DB_PASSWORD:-} ]]; then
  PW_ORIGIN="environment DB_PASSWORD (deprecated)"; PW_ENV_DEPRECATED=true
else
  DB_PASSWORD=""
fi
export -n DB_PASSWORD ZBX_DB_PASSWORD 2>/dev/null || true
unset ZBX_DB_PASSWORD

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
ST_INSTALL_AGENT=""; ST_AGENT_HOSTNAME=""; ST_ENABLE_UFW=""; ST_SSH_PORT=""
SSH_PORTS=(); SSH_PORT_SRC=""; UFW_RULES=()

# =============================================================================
# 1. Output, logging and the run() wrapper
#    Everything shown goes to the terminal and, with a timestamp, to
#    /var/log/zabbix-setup.log. --dry-run writes to zabbix-manual-steps.txt
#    instead. Secrets never pass through these functions unmasked.
#    During a real run each step is shown as one line (see "Step display"
#    below) and what it prints goes to the log only, unless --verbose.
# =============================================================================
# No colours when NO_COLOR is set (no-color.org), on TERM=dumb or off a terminal
if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'; C_OFF=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_OFF=""
fi
LOG_ON=false
MANUAL_FILE=""
TMP_PATHS=()

# --- Step display state (set up by ui_init; see "Step display" below) -------
#  UI=classic   --dry-run, --verify, --help: the numbered output as before
#  UI=progress  terminal: one line per step, redrawn in place, with a spinner
#  UI=plain     stdout is not a terminal: "[..] step" then "[OK] step (14s)"
#  UI=verbose   --verbose: every command ($ ...) and its output, then the
#               step's [✓] / [✗] / [-] line
UI=classic
UI_TTY=false; [[ -t 1 ]] && UI_TTY=true
UI_REDRAW=false          # in-place line + spinner (terminal, colours allowed)
UI_PAUSE=0               # >0 while a question or netplan try has the terminal
INTERRUPTED=""           # INT / TERM / HUP received
STEP_FILE=""             # progress/plain: the current step's output (mode 600)
STEP_ON=false; STEP_NUM=""; STEP_TITLE=""; STEP_T0=0; STEP_STATUS=""; STEP_NOTE=""; STEP_INFO=""
STEP_INSTALLED=false     # apt_install installed something in this step
STEP_SHOWN=0             # bytes of STEP_FILE already shown above a question
STEP_HEADED=false        # that question already has the step header above it
STEP_N=0; STEP_TOTAL=0; STEP_LINES=(); RUN_T0=-1
SPIN_PID=""; CURSOR_HIDDEN=false; FAIL_CMD=""
M_RUN=""; M_OK=""; M_FAIL=""; M_SKIP=""; SPIN_FRAMES=()

_record() {   # plain line -> log (timestamped) and/or the dry-run manual file
  if [[ $LOG_ON == true ]]; then
    # inside a progress/plain step the line goes to the step file first (it is
    # appended to the log when the step ends, so the log keeps its order)
    if [[ $STEP_ON == true && -n $STEP_FILE ]]; then printf '[%(%F %T)T] %s\n' -1 "$1" >>"$STEP_FILE"
    else printf '[%(%F %T)T] %s\n' -1 "$1" >>"$LOG_FILE"; fi
  fi
  if [[ -n $MANUAL_FILE ]]; then printf '%s\n' "$1" >>"$MANUAL_FILE"; fi
}
# _screen: may a line go to the terminal now? Not inside a progress/plain
# step (it would break the step line), except while a question is shown.
_screen() { [[ $STEP_ON != true || -z $STEP_FILE || $UI_PAUSE -gt 0 ]]; }
_emit() { local color=$1; shift; if _screen; then printf '%s%s%s\n' "$color" "$*" "${color:+$C_OFF}"; fi; _record "$*"; }
say()   { _emit "" "$*"; }
info()  { _emit "$C_CYAN" "      $*"; }
ok()    { _emit "$C_GREEN" "      OK: $*"; }
warn()  { _emit "$C_YELLOW" "      WARNING: $*"; }
skip()  { _emit "" "      skipped: $*"; }
err()   { local l; for l in "$@"; do _emit "$C_RED" "ERROR: $l" >&2; done; }
die()   { err "$@"; exit 1; }

part() { step_close; say ""; _emit "$C_BOLD" "==================== $* ===================="; }

# step NUMBER TITLE - numbers follow the guide. In a real run this is also
# the step wrapper: it ends the previous step (its [✓] line) and starts this
# one (its [✗] line + spinner, output captured). See "Step display".
step() {
  CUR_STEP=$1; ACTION_N=0
  step_close
  local t=""
  if [[ $DRY_RUN != true ]]; then t=$(printf '   [%(%H:%M:%S)T]' -1); fi
  if [[ $UI == classic || $UI == verbose ]]; then
    say ""
    _emit "$C_BOLD" "--- Step $1: $2$t"
  fi
  [[ $UI == classic ]] && return 0
  step_begin "$1" "$2"
  if [[ -n $STEP_FILE ]]; then _record ""; _record "--- Step $1: $2$t"; fi
}

_action() {   # numbered action line ([1.2.3]) plus optional detail lines
  ACTION_N=$((ACTION_N + 1))
  say "  [${CUR_STEP}.${ACTION_N}] $1"
  shift
  local l
  for l in "$@"; do say "          $l"; done
}

# _q ARGS... - shell-quoted command line for display. An argument holding the
# DB password (never expected) is shown with it masked.
_q() {
  local out="" a q
  for a in "$@"; do
    if [[ -n ${DB_PASSWORD:-} && $a == *"$DB_PASSWORD"* ]]; then q=${a//"$DB_PASSWORD"/$MASK}
    else printf -v q '%q' "$a"; fi
    out+="${q} "
  done
  printf '%s' "${out% }"
}
# _logpipe: command output -> the log (or the current step's file); on the
# terminal too with --verbose (indented) or outside a progress step. The DB
# password is masked in case a command ever echoes it.
_logpipe() {
  if [[ $UI == classic ]]; then
    if [[ $LOG_ON == true ]]; then tee -a "$LOG_FILE"; else cat; fi
    return
  fi
  local l show=false dest=$LOG_FILE
  if [[ $STEP_ON == true && -n $STEP_FILE ]]; then dest=$STEP_FILE; fi
  if _screen; then show=true; fi
  {
    while IFS= read -r l || [[ -n $l ]]; do
      if [[ -n $DB_PASSWORD ]]; then l=${l//"$DB_PASSWORD"/$MASK}; fi
      printf '%s\n' "$l" >&4
      if [[ $show == true ]]; then printf '    %s\n' "$l"; fi
    done
  } 4>>"$dest"
}
# _xcmd "TEXT" - the exact command about to run: shown with --verbose and
# always logged (password masked; option files are named, never printed).
_xcmd() {
  local c=$1
  if [[ -n $DB_PASSWORD ]]; then c=${c//"$DB_PASSWORD"/$MASK}; fi
  _emit "" "  \$ ${c}"
}

# run CMD...                 show "$ sudo CMD" and run it (output logged)
# run_show "TEXT" CMD...     show TEXT (the manual equivalent) and run CMD
# In --dry-run both only print. Note: CMD runs in a pipeline subshell, so it
# cannot set variables in the caller.
run() { run_show "sudo $(_q "$@")" "$@"; }
run_show() {
  local shown=$1 rc=0; shift
  _action "\$ $shown"
  if [[ $DRY_RUN == true ]]; then return 0; fi
  # the exact command (a helper function such as fetch_url is shown by the
  # manual equivalent above instead)
  if ! declare -F "$1" >/dev/null; then _xcmd "$(_q "$@")"; fi
  "$@" 2>&1 | _logpipe || rc=$?
  if ((rc != 0)); then err "command failed (exit ${rc}): ${shown}"; fi
  return "$rc"
}

# --- Step display -------------------------------------------------------------
# One step = one line on the terminal. step() opens it; the next step(),
# part() or step_close closes it. While it is open, fds 1 and 2 point at
# STEP_FILE and the terminal is reached through fds 7 and 8 (saved by
# ui_init). Questions and netplan try get the terminal back through
# ui_pause / ui_resume, so no prompt ever appears under a spinner.
ui_init() {      # after flags and the env file: pick the display mode
  [[ $DRY_RUN == true || $DO_VERIFY == true ]] && return 0   # unchanged output
  if v_verbose "$VERBOSE"; then :; else die "VERBOSE='${VERBOSE}' from ${SRC[VERBOSE]:-?} is invalid: ${VERR}"; fi
  case ${VERBOSE,,} in 1|yes|true) UI=verbose ;; *) UI=progress ;; esac
  if [[ $UI == progress && $UI_TTY != true ]]; then UI=plain; fi
  if [[ $UI_TTY != true ]]; then
    M_RUN="[..]"; M_OK="[OK]"; M_FAIL="[FAIL]"; M_SKIP="[SKIP]"
  elif [[ $(locale charmap 2>/dev/null || true) == UTF-8 ]]; then
    M_RUN="[✗]"; M_OK="[✓]"; M_FAIL="[✗]"; M_SKIP="[-]"; SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    M_RUN="[ ]"; M_OK="[v]"; M_FAIL="[x]"; M_SKIP="[-]"; SPIN_FRAMES=('|' '/' '-' "\\")
  fi
  # no cursor tricks on TERM=dumb or with NO_COLOR: one line at the start, one at the end
  if [[ $UI == progress && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then UI_REDRAW=true; fi
  if [[ $UI != verbose ]]; then
    STEP_FILE=$(mktemp); TMP_PATHS+=("$STEP_FILE")
    chmod 600 "$STEP_FILE"
  fi
  exec 7>&1 8>&2
  trap 'on_signal 130 INT' INT
  trap 'on_signal 143 TERM' TERM
  trap 'on_signal 129 HUP' HUP
}
on_signal() { INTERRUPTED=$2; trap - INT TERM HUP; exit "$1"; }

# NOW = seconds since boot (/proc/uptime): monotonic, so step 0.4 (chrony
# stepping the clock, a new timezone) cannot distort the durations.
NOW=0
_now() { local u _rest; if read -r u _rest </proc/uptime 2>/dev/null; then NOW=${u%%.*}; else NOW=$SECONDS; fi; }
_dur() { if (($1 < 60)); then printf '%ds' "$1"; else printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); fi; }
_step_lead() {   # _step_lead MARKER -> "( 4/14) [✓] 2.3 Title"
  local c=""
  if ((STEP_TOTAL > 0)); then printf -v c '(%*d/%d) ' "${#STEP_TOTAL}" "$STEP_N" "$STEP_TOTAL"; fi
  printf '%s%s %s %s' "$c" "$1" "$STEP_NUM" "$STEP_TITLE"
}
_fit() {         # _fit TEXT -> TEXT cut to the terminal width (a wrapped line cannot be redrawn)
  local cols=80 s
  s=$(stty size </dev/tty 2>/dev/null || true)
  if [[ $s =~ ^[0-9]+\ ([0-9]+)$ ]] && ((BASH_REMATCH[1] >= 20)); then cols=${BASH_REMATCH[1]}; fi
  if ((${#1} > cols - 3)); then printf '%s...' "${1:0:cols-6}"; else printf '%s' "$1"; fi
}
spin_start() {   # spin_start TEXT - redraw "TEXT <frame>" until spin_stop
  local text=$1 parent=$$
  printf '\e[?25l' >&7; CURSOR_HIDDEN=true
  {
    _i=0
    # stops by itself if the script is gone (kill -9) or the terminal closed
    while kill -0 "$parent" 2>/dev/null; do
      printf '\r%s %s' "$text" "${SPIN_FRAMES[_i % ${#SPIN_FRAMES[@]}]}" || exit 0
      _i=$((_i + 1))
      sleep 0.15
    done
  } >&7 2>/dev/null </dev/null &
  SPIN_PID=$!
}
spin_stop() {    # stop the spinner, clear its line, show the cursor again
  if [[ -n $SPIN_PID ]]; then
    { kill "$SPIN_PID" && wait "$SPIN_PID"; } 2>/dev/null || true
    SPIN_PID=""
  fi
  if [[ $CURSOR_HIDDEN == true ]]; then printf '\r\e[K\e[?25h' >&7 2>/dev/null || true; CURSOR_HIDDEN=false; fi
  return 0
}
ui_line_start() {  # the line of a running step: redrawn with a spinner, or printed once
  if [[ $UI_REDRAW == true ]]; then spin_start "$(_fit "$(_step_lead "$M_RUN")...")"
  elif [[ $UI_TTY == true ]]; then printf '%s...\n' "$(_step_lead "$M_RUN")" >&7
  else printf '%s\n' "$(_step_lead "$M_RUN")" >&7; fi
}
step_begin() {
  _now
  STEP_ON=true; STEP_NUM=$1; STEP_TITLE=$2; STEP_T0=$NOW
  STEP_STATUS=ok; STEP_NOTE=""; STEP_INFO=""; STEP_INSTALLED=false; STEP_HEADED=false
  STEP_N=$((STEP_N + 1))
  ((RUN_T0 >= 0)) || RUN_T0=$NOW
  [[ -n $STEP_FILE ]] || return 0      # --verbose: the header above is the title
  : >"$STEP_FILE"; STEP_SHOWN=0
  exec 1>>"$STEP_FILE" 2>&1
  ui_line_start
}
# step_skip REASON - the step had nothing to do: [-] ... (skipped: REASON)
step_skip() { STEP_STATUS=skip; STEP_NOTE=$1; }
# step_info TEXT - a short result shown after the duration: [✓] ... (3s; TEXT)
step_info() { STEP_INFO=$1; }
_step_detach() {   # spinner off, fds 1/2 back to the terminal
  [[ -n $STEP_FILE ]] || return 0
  spin_stop
  exec 1>&7 2>&8
}
_step_flush() {    # the step's output -> the log
  [[ -n $STEP_FILE && -s $STEP_FILE ]] || return 0
  cat "$STEP_FILE" >>"$LOG_FILE"
  : >"$STEP_FILE"
}
readonly TS_RE='^\[[0-9-]+ [0-9:]+\] ?'
_step_warnings() { # WARNING lines and preflight WARN rows (with their fix line)
  local l keep=false
  while IFS= read -r l || [[ -n $l ]]; do
    [[ $l =~ $TS_RE ]] || { keep=false; continue; }
    l=${l#"${BASH_REMATCH[0]}"}
    if [[ $l == "      WARNING: "* || $l == "  WARN  "* ]]; then printf '%s\n' "$l"; keep=true
    elif [[ $keep == true && $l == "        fix: "* ]]; then printf '%s\n' "$l"
    else keep=false; fi
  done <"$STEP_FILE"
  return 0
}
_step_text() {     # _step_text errors|other - the step's lines, timestamps removed
  local l
  while IFS= read -r l || [[ -n $l ]]; do
    if [[ $l =~ $TS_RE ]]; then
      l=${l#"${BASH_REMATCH[0]}"}
      [[ -z $l ]] && continue
      if [[ $l == "ERROR: "* ]]; then [[ $1 == errors ]] && printf '%s\n' "$l"; continue; fi
    fi
    [[ $1 == other ]] && printf '%s\n' "$l"
  done <"$STEP_FILE"
  return 0
}
step_close() {     # end the current step: [✓] or [-], its warnings, the log
  [[ $STEP_ON == true ]] || return 0
  local dur line color word l
  _now; dur=$(_dur $((NOW - STEP_T0)))
  if [[ $STEP_STATUS == skip ]]; then
    line="$(_step_lead "$M_SKIP") (skipped: ${STEP_NOTE})"; color=$C_YELLOW; word=SKIP
  else
    line="$(_step_lead "$M_OK") (${dur}${STEP_INFO:+; ${STEP_INFO}})"; color=$C_GREEN; word=OK
  fi
  _step_detach
  printf '%s%s%s\n' "$color" "$line" "${color:+$C_OFF}" >&7
  if [[ -n $STEP_FILE ]]; then
    # warnings stay visible under the step line (--verbose showed them already)
    while IFS= read -r l; do printf '%s%s%s\n' "$C_YELLOW" "$l" "${C_YELLOW:+$C_OFF}" >&7; done < <(_step_warnings)
  fi
  STEP_ON=false
  _step_flush
  _record "[${word}] ${STEP_NUM} ${STEP_TITLE} (${dur}${STEP_NOTE:+, skipped: ${STEP_NOTE}})"
  STEP_LINES+=("${STEP_STATUS}${US}${line}")
}
step_fail() {      # step_fail EXIT_CODE - red [✗] line, output tail, errors, hint, log
  local rc=$1 note="" l hint=""
  case $rc in 129|130|143) note=" (interrupted)" ;; esac
  [[ -n $INTERRUPTED ]] && note=" (interrupted: ${INTERRUPTED})"
  _step_detach
  printf '%s%s%s\n' "$C_RED" "$(_step_lead "$M_FAIL")${note}" "${C_RED:+$C_OFF}" >&7
  if [[ -n $STEP_FILE ]]; then
    printf '    Last lines of output:\n' >&7
    while IFS= read -r l; do printf '      %s\n' "$l" >&7; done < <(_step_text other | tail -n 15)
    while IFS= read -r l; do printf '%s    %s%s\n' "$C_RED" "$l" "${C_RED:+$C_OFF}" >&7; done < <(_step_text errors)
  fi
  if [[ -n $FAIL_CMD ]]; then hint=$(fail_hint); fi
  if [[ -n $hint ]]; then printf '%s    Hint: %s%s\n' "$C_YELLOW" "$hint" "${C_YELLOW:+$C_OFF}" >&7; fi
  printf '    Full log: %s\n' "$LOG_FILE" >&7
  STEP_ON=false
  _step_flush
  _record "[FAIL] ${STEP_NUM} ${STEP_TITLE}${note}"
}
# A plain command failed (ERR trap): the guide's fix for an error it knows.
# Failures that stop through die() already print their own hint.
fail_hint() {
  local out
  if [[ -n $STEP_FILE ]]; then out=$(<"$STEP_FILE"); else out=$(tail -n 200 "$LOG_FILE" 2>/dev/null || true); fi
  case $out in
    *"ERROR 1410"*) printf '%s' "MySQL 8 needs CREATE USER before GRANT - re-run: the script does both, in that order." ;;
    *"ERROR 1050"*) printf '%s' "A partial schema is in the way: recreate the database with --reset on the DB node, then re-run." ;;
    *AH00526*)      printf '%s' "Apache proxy modules missing: sudo a2enmod ${APACHE_MODS[*]} && sudo systemctl restart apache2" ;;
    *"server.sql.gz: No such file"*) printf '%s' "Zabbix ${ZBX_VERSION} keeps the schema in ${SCHEMA_CANDIDATES[0]} (ls /usr/share/zabbix*/)." ;;
    *"mysql: command not found"*) printf '%s' "Install the client: sudo apt install mysql-client -y" ;;
    *"ERROR 1045"*|*"ERROR 1130"*|*"ERROR 1049"*|*"ERROR 2002"*|*"ERROR 2003"*|*"ERROR 2005"*|*"ERROR 2059"*|*"ERROR 2061"*)
                    explain_mysql_error "$out" ;;
    *"dpkg was interrupted"*) printf '%s' "An earlier apt run was interrupted: sudo dpkg --configure -a, then run the script again." ;;
    *"Could not get lock"*) printf '%s' "Another apt/dpkg process is running (unattended-upgrades?): wait for it to finish, then run the script again." ;;
    *"404"*"Not Found"*) printf '%s' "A 404 means a wrong repository path: it must include /release/ (zabbix/${ZBX_VERSION}/release/ubuntu/...)." ;;
  esac
  return 0
}
# ui_pause / ui_resume - around a question or a program that needs the
# terminal (netplan try, passwd) inside a step: the spinner stops, the step's
# output so far is shown as context, the terminal is handed over. Nested
# calls are fine (only the outermost pair acts).
ui_pause() {
  UI_PAUSE=$((UI_PAUSE + 1))
  [[ $UI_PAUSE == 1 && $STEP_ON == true && -n $STEP_FILE ]] || return 0
  local l size
  _step_detach
  if [[ $STEP_HEADED != true ]]; then printf '%s--- Step %s: %s%s\n' "$C_BOLD" "$STEP_NUM" "$STEP_TITLE" "${C_BOLD:+$C_OFF}"; STEP_HEADED=true; fi
  size=$(stat -c %s "$STEP_FILE" 2>/dev/null || echo 0)
  while IFS= read -r l || [[ -n $l ]]; do
    [[ $l =~ $TS_RE ]] && l=${l#"${BASH_REMATCH[0]}"}
    [[ -z $l || $l == "--- Step "* ]] && continue
    printf '%s\n' "$l"
  done < <(tail -c +$((STEP_SHOWN + 1)) "$STEP_FILE" | tail -n 40)
  STEP_SHOWN=$size
  return 0
}
ui_resume() {
  ((UI_PAUSE > 0)) && UI_PAUSE=$((UI_PAUSE - 1))
  [[ $UI_PAUSE == 0 && $STEP_ON == true && -n $STEP_FILE ]] || return 0
  STEP_SHOWN=$(stat -c %s "$STEP_FILE" 2>/dev/null || echo 0)
  exec 1>>"$STEP_FILE" 2>&1
  ui_line_start
}
steps_summary() {  # end of a real run: every step with its marker, total time
  [[ $UI != classic ]] || return 0
  step_close
  local row st line color
  part "Steps"
  for row in "${STEP_LINES[@]}"; do
    st=${row%%"$US"*}; line=${row#*"$US"}
    if [[ $st == skip ]]; then color=$C_YELLOW; else color=$C_GREEN; fi
    _emit "$color" "  ${line}"
  done
  _now
  if ((RUN_T0 >= 0)); then say "  Total: $(_dur $((NOW - RUN_T0)))"; fi
  return 0
}
# STEP_TOTAL - the steps this run will show, for the (n/total) counter
count_steps() {
  STEP_TOTAL=3                                    # 0.1 0.3 0.4
  if [[ -n $ADD_USER ]]; then STEP_TOTAL=4; fi    # + 0.2
  case $MODE in
    db)     STEP_TOTAL=$((STEP_TOTAL + 6)) ;;     # 1.1 - 1.6
    app)    STEP_TOTAL=$((STEP_TOTAL + 11)) ;;    # 2.1 - 2.9 with 2.5a, 2.7a
    single) STEP_TOTAL=$((STEP_TOTAL + 16)) ;;    # 1.1 - 1.5 + Part 2
  esac
}
# On exit: a step still open failed (or was interrupted). The spinner always
# stops and the cursor always comes back.
ui_exit() {
  [[ $UI != classic ]] || return 0
  if [[ $STEP_ON == true ]]; then
    if (($1 != 0)) || [[ -n $INTERRUPTED ]]; then step_fail "$1"; else step_close; fi
  fi
  spin_stop
  if [[ $UI_REDRAW == true ]]; then printf '\e[?25h' >&7 2>/dev/null || true; fi
  return 0
}

cleanup() {
  local rc=$? p
  ui_exit "$rc" || true
  for p in "${TMP_PATHS[@]}"; do [[ -n $p ]] && rm -rf -- "$p"; done
  return 0
}
trap cleanup EXIT

on_err() {
  local rc=$1 line=$2 cmd=$3
  if [[ $BASHPID != "$$" ]]; then exit "$rc"; fi   # subshell: parent reports
  trap - ERR
  FAIL_CMD=$cmd
  err "Step ${CUR_STEP} failed (exit ${rc}, line ${line}): ${cmd}"
  # (inside a step, the step's [✗] block prints the log path)
  if [[ $LOG_ON == true && $STEP_ON != true ]]; then err "Full output: ${LOG_FILE}"; fi
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
v_ssh_port() {   # 1-65535 (SSH may well run below 1024)
  if [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); then return 0; fi
  VERR="SSH port must be a number from 1 to 65535"; return 1
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
v_path()   { [[ -n $1 && $1 != *[[:cntrl:]]* ]] && return 0; VERR="not a usable path"; return 1; }
v_yesno()  { [[ ${1,,} == yes || ${1,,} == no ]] && return 0; VERR="must be yes or no"; return 1; }
v_verbose() { [[ -z $1 || ${1,,} =~ ^(0|1|yes|no|true|false)$ ]] && return 0; VERR="must be yes or no"; return 1; }
# Agent host name (Hostname= in zabbix_agent2.conf): no spaces, except the
# package default "Zabbix server" that matches the built-in host.
v_agent_host() {
  [[ $1 == "$ZBX_DEFAULT_AGENT_HOST" || $1 =~ ^[A-Za-z0-9._-]{1,128}$ ]] && return 0
  VERR="letters, digits, . _ - only (max 128, no spaces; only the default '${ZBX_DEFAULT_AGENT_HOST}' has one)"; return 1
}
normalize_mode() { case ${1,,} in 1) echo single ;; 2) echo db ;; 3) echo app ;; *) echo "${1,,}" ;; esac; }
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

# --- whiptail dialogs (used on a terminal; text prompts otherwise) ----------
# dialog_possible: whiptail installed, stdin/stdout are a terminal, TERM can
# draw, /dev/tty is usable. --no-dialog and --yes switch dialogs off.
dialog_possible() {
  command -v whiptail >/dev/null 2>&1 || return 1
  [[ -t 0 && -t 1 ]] || return 1
  [[ -n ${TERM:-} && $TERM != dumb ]] || return 1
  { : >/dev/tty; } 2>/dev/null
}
DLG_ERR=""       # error to show at the top of the next dialog (bad input)
# _dlg ARGS... - the dialog is drawn on /dev/tty, its answer comes back on
# stdout (whiptail writes it to stderr: fd 3 keeps the caller's stdout, the
# screen goes to /dev/tty, stderr goes to fd 3). Answers, passwords
# included, are never passed as arguments.
_dlg() { whiptail --backtitle "zabbix-setup.sh ${SCRIPT_VERSION} - Zabbix ${ZBX_VERSION} LTS" "$@" 3>&1 1>/dev/tty 2>&3 3>&-; }
_dlg_text() {    # _dlg_text "message" -> message with a pending error on top
  local t=$1
  if [[ -n $DLG_ERR ]]; then t="Invalid input: ${DLG_ERR}"$'\n\n'"${t}"; DLG_ERR=""; fi
  printf '%s' "$t"
}
end_dialogs() {  # back to the normal terminal for the progress output
  if [[ $USE_DIALOG == true ]]; then clear 2>/dev/null || printf '\n'; fi
  return 0
}

# ask VAR "Question" "default" validator
# Priority: flag > environment > env file > prompt. --yes takes the default.
# --dry-run --yes without a usable default uses a placeholder (<VAR>).
ask() {
  local var=$1 q=$2 def=$3 vfn=$4 cur=${!1:-} src=${SRC[$1]:-} ans hint rc
  if [[ -n $src ]]; then
    if "$vfn" "$cur"; then say "  ${q} ${cur}   (from ${src})"; return 0; fi
    warn "${var}='${cur}' from ${src} is invalid: ${VERR}"
    [[ $ASSUME_YES == true ]] && die "Fix the ${src} value for ${var} and re-run."
    if [[ $USE_DIALOG == true ]]; then DLG_ERR="${var} from ${src}: ${VERR}"; fi
  elif [[ $ASSUME_YES == true ]]; then
    if "$vfn" "$def"; then printf -v "$var" '%s' "$def"; say "  ${q} ${def:-<blank>}   (default, --yes)"; return 0; fi
    if [[ $DRY_RUN == true ]]; then
      printf -v "$var" '<%s>' "$var"; say "  ${q} <${var}>   (placeholder: no value given, --dry-run --yes)"; return 0
    fi
    die "${q} has no usable default (${VERR}). Pass it as a flag, a ZBX_${var} variable or in an env file (see --help)."
  fi
  if [[ -n $def ]]; then hint="[${def}]"; else hint="(Enter = leave blank)"; fi
  ui_pause                          # (only acts inside a step)
  while true; do
    if [[ $USE_DIALOG == true ]]; then
      rc=0
      ans=$(_dlg --title "Settings (${MODE:-setup})" --inputbox "$(_dlg_text "${q}")" 12 76 "$def") || rc=$?
      ((rc == 0)) || die "Cancelled at '${q}' - nothing was changed."
    else
      IFS= read -r -p "  ${q} ${hint}: " ans || die "Input ended while asking: ${q}"
    fi
    ans=${ans#"${ans%%[![:space:]]*}"}; ans=${ans%"${ans##*[![:space:]]}"}
    ans=${ans:-$def}
    if "$vfn" "$ans"; then printf -v "$var" '%s' "$ans"; _record "  ${q} ${ans}"; ui_resume; return 0; fi
    if [[ $USE_DIALOG == true ]]; then DLG_ERR=$VERR; else warn "${VERR} - try again."; fi
  done
}

# ask_yn "Question" y|n ["extra text for the dialog"] -> 0 for yes.
# --yes answers with the default.
ask_yn() {
  local q=$1 def=$2 extra=${3:-} ans hint="[y/N]" text
  local -a dopt=()
  [[ $def == y ]] && hint="[Y/n]"
  if [[ $ASSUME_YES == true ]]; then say "  ${q} ${hint} ${def}   (default, --yes)"; [[ $def == y ]]; return; fi
  ui_pause                          # (only acts inside a step)
  if [[ $USE_DIALOG == true ]]; then
    [[ $def == y ]] || dopt=(--defaultno)
    text=$q
    if [[ -n $extra ]]; then text="${extra}"$'\n\n'"${q}"; fi
    # height: 16, or more for a long text (e.g. the ufw rule list), at most 24
    local h=7 l
    while IFS= read -r l; do h=$((h + 1 + ${#l} / 72)); done <<<"$text"
    ((h < 16)) && h=16; ((h > 24)) && h=24
    if _dlg --title "Question" "${dopt[@]}" --yesno "$text" "$h" 76; then
      _record "  ${q} -> yes"; ui_resume; return 0
    fi
    _record "  ${q} -> no"; ui_resume; return 1
  fi
  while true; do
    read -r -p "  ${q} ${hint} " ans || die "Input ended while asking: ${q}"
    ans=${ans:-$def}
    case ${ans,,} in
      y|yes) _record "  ${q} -> yes"; ui_resume; return 0 ;;
      n|no)  _record "  ${q} -> no"; ui_resume; return 1 ;;
    esac
    warn "Please answer y or n."
  done
}

read_hidden() {   # read_hidden VAR "prompt" - no echo, never logged
  local __v __rc=0 __p=$2
  ui_pause                          # (only acts inside a step)
  if [[ $USE_DIALOG == true ]]; then
    __p=${__p#"${__p%%[![:space:]]*}"}
    # passwordbox: the typed text comes back through the fd swap in _dlg,
    # never as an argument, so it is not visible in ps or the log.
    __v=$(_dlg --title "Database password" --passwordbox "$(_dlg_text "$__p")" 12 76) || __rc=$?
    ((__rc == 0)) || die "Cancelled at the password - nothing was changed."
  else
    if [[ -n $DLG_ERR ]]; then DLG_ERR=""; fi
    IFS= read -r -s -p "$__p" __v || die "Input ended while reading a password."
    printf '\n' >&2
  fi
  printf -v "$1" '%s' "$__v"
  ui_resume
}

# =============================================================================
# 3. Config-file editing (pure bash: values never go through sed, so any
#    character in a password survives). Every edit is preceded by a backup.
# =============================================================================

# backup_file PATH - cp -a into /var/backups/zabbix-setup/<timestamp>/<PATH>
# Backups can hold the DB password (zabbix_server.conf), so the backup root
# is mode 700 and every copy is mode 600.
backup_file() {
  local f=$1 dest="${BACKUP_DIR}$1"
  if [[ $DRY_RUN != true ]]; then
    [[ -e $f ]] || return 0
    [[ -e $dest ]] && return 0        # already backed up during this run
  fi
  _action "\$ sudo install -d -m 700 ${BACKUP_ROOT} && sudo mkdir -p ${dest%/*} && sudo cp -a ${f} ${dest} && sudo chmod 600 ${dest}"
  if [[ $DRY_RUN == true ]]; then return 0; fi
  backup_root_private
  (umask 077 && mkdir -p "${dest%/*}")
  cp -a -- "$f" "$dest"
  chmod 600 "$dest"
  info "backup: ${dest}"
}
# /var/backups/zabbix-setup at 700. Also tightens what an older version left
# (755 folders, 644/640 copies): group/other lose every permission.
backup_root_private() {
  install -d -m 700 "$BACKUP_ROOT"
  chmod -R go-rwx "$BACKUP_ROOT"
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

ufw_state() {     # prints active | inactive | absent  (read only)
  if ! command -v ufw >/dev/null 2>&1; then echo absent; return 0; fi
  local out; out=$(ufw status 2>/dev/null || true)
  if [[ $out == *"Status: active"* ]]; then echo active; else echo inactive; fi
}

# SSH_PORTS - the port(s) sshd really listens on, so the ufw step can allow
# them before it enables the firewall. sshd -T first, then ss -ltnp (sshd, or
# systemd for the socket-activated ssh.socket), then sshd_config (Port lines,
# default 22). --ssh-port / ZBX_SSH_PORT adds one explicitly (the port you
# connect with, e.g. behind a NAT forward). None found and no --ssh-port:
# empty, and ufw is not enabled (--force does not change that).
_ssh_port_add() {
  local p
  [[ $1 =~ ^[0-9]+$ ]] || return 0
  for p in "${SSH_PORTS[@]}"; do [[ $p == "$1" ]] && return 0; done
  SSH_PORTS+=("$1")
}
detect_ssh_ports() {
  _detect_ssh_ports_auto
  if [[ -n $SSH_PORT ]] && v_ssh_port "$SSH_PORT"; then
    _ssh_port_add "$SSH_PORT"
    if [[ -n $SSH_PORT_SRC ]]; then SSH_PORT_SRC+=" + ${SRC[SSH_PORT]:-saved} (${SSH_PORT})"
    else SSH_PORT_SRC="${SRC[SSH_PORT]:-saved --ssh-port} (not detected)"; fi
  fi
  return 0
}
_detect_ssh_ports_auto() {
  SSH_PORTS=(); SSH_PORT_SRC=""
  local out k v line f
  local -a cols=()
  if command -v sshd >/dev/null 2>&1 && out=$(sshd -T 2>/dev/null); then
    while read -r k v _; do [[ $k == port ]] && _ssh_port_add "$v"; done <<<"$out"
    if ((${#SSH_PORTS[@]})); then SSH_PORT_SRC="sshd -T"; return 0; fi
  fi
  out=$(ss -ltnpH 2>/dev/null || true)
  while IFS= read -r line; do
    [[ $line == *'"sshd'* ]] || continue
    read -r -a cols <<<"$line"
    ((${#cols[@]} >= 4)) && _ssh_port_add "${cols[3]##*:}"
  done <<<"$out"
  if [[ -z ${SSH_PORTS[*]} ]] && systemctl is-active --quiet ssh.socket 2>/dev/null; then
    out=$(systemctl show -p Listen --value ssh.socket 2>/dev/null || true)
    for k in $out; do [[ $k == *:* ]] && _ssh_port_add "${k##*:}"; done
  fi
  if ((${#SSH_PORTS[@]})); then SSH_PORT_SRC="ss -ltnp"; return 0; fi
  if [[ -r /etc/ssh/sshd_config ]]; then
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
      [[ -r $f ]] || continue
      while read -r k v _; do [[ ${k,,} == port ]] && _ssh_port_add "$v"; done <"$f"
    done
    ((${#SSH_PORTS[@]})) || SSH_PORTS=(22)
    SSH_PORT_SRC="/etc/ssh/sshd_config"
    return 0
  fi
  return 0
}

# UFW_RULES - the rules the ufw step adds, as ufw arguments, SSH first.
#   db:         DB_PORT and (agent) 10050, only from APP_IP
#   app/single: 80/tcp (web UI), 10051/tcp (active checks; only from WIN_IP if given)
ufw_plan() {
  local p c="comment ${UFW_COMMENT}"
  UFW_RULES=()
  for p in "${SSH_PORTS[@]}"; do UFW_RULES+=("allow ${p}/tcp ${c}"); done
  case $MODE in
    db)
      UFW_RULES+=("allow from ${APP_IP} to any port ${DB_PORT} proto tcp ${c}")
      if [[ $INSTALL_AGENT == yes ]]; then UFW_RULES+=("allow from ${APP_IP} to any port ${ZBX_AGENT_PORT} proto tcp ${c}"); fi ;;
    app|single)
      UFW_RULES+=("allow ${HTTP_PORT}/tcp ${c}")
      if [[ -n $WIN_IP && $WIN_IP != "<"* ]]; then UFW_RULES+=("allow from ${WIN_IP} to any port ${ZBX_TRAPPER_PORT} proto tcp ${c}")
      else UFW_RULES+=("allow ${ZBX_TRAPPER_PORT}/tcp ${c}"); fi ;;
  esac
  return 0
}
_ufw_shown() {   # _ufw_shown RULE -> "sudo ufw RULE" with the comment quoted as typed by hand
  local r=${1% comment "$UFW_COMMENT"}
  [[ $r != "$1" ]] && r+=" comment '${UFW_COMMENT}'"
  printf 'sudo ufw %s' "$r"
}
ufw_plan_lines() {   # the commands of the ufw step, in order (for the question and --dry-run)
  local r
  if [[ $DRY_RUN == true ]] || ! command -v ufw >/dev/null 2>&1; then printf '%s\n' "sudo apt install ufw -y   (if missing)"; fi
  if ((${#SSH_PORTS[@]} == 0)); then printf '%s\n' "(no SSH port detected: ufw is not enabled)"; return 0; fi
  for r in "${UFW_RULES[@]}"; do printf '%s\n' "$(_ufw_shown "$r")"; done
  printf '%s\n' "sudo ufw default deny incoming     (if ufw is not active yet)" \
                "sudo ufw default allow outgoing" "sudo ufw --force enable"
}
# The rules ufw holds (also while inactive), as "allow ... comment zabbix-setup"
ufw_added_rules() {
  local line
  while IFS= read -r line; do
    [[ $line == "ufw "* ]] || continue
    line=${line#ufw }; printf '%s\n' "${line//\'/}"
  done < <(ufw show added 2>/dev/null || true)
  return 0
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
# Only validated values reach the bash -c string (a --dry-run placeholder such
# as <DB_IP> would otherwise be parsed as redirections).
tcp_open() {
  if ! v_ip "$1" || ! v_port "$2"; then return 1; fi
  timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null
}

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
# Where Zabbix reaches MySQL in single mode: the local socket by default, or
# TCP to 127.0.0.1 with a custom port ("localhost" would always mean the
# socket to the MySQL client library, and the port would be ignored).
single_db_host() { if [[ $SINGLE_CUSTOM_PORT == true ]]; then printf '127.0.0.1'; else printf 'localhost'; fi; }
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
  _xcmd "mysql --protocol=socket --default-character-set=utf8mb4 -uroot -N -B   <<< the SQL above (password masked)"
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
    *"ERROR 1130"*) printf '%s' "Host not allowed: the MySQL user is scoped to another IP. On the DB server re-run: sudo ${LAUNCH} --mode db --app-ip ${APP_IP:-<this IP>}" ;;
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
   or: sudo bash -c 'bash <(curl -fsSL ${SCRIPT_URL:-<URL>}) "\$@"' _ [options]

With no options a menu asks which role this machine has (whiptail dialogs on
a terminal, plain text prompts otherwise):
  1) single   Zabbix + MySQL on this VM
  2) db       two VMs - this machine is the DATABASE server  (run it first)
  3) app      two VMs - this machine is the APP/WEB server   (run it second)
Output files (hand-off, env file, next steps, manual steps) go to the
current directory.

Actions
  --mode single|db|app   skip the menu
  --dry-run              print every command and file edit (numbered like the guide),
                         change nothing, save the list to ./zabbix-manual-steps.txt
                         (no password is needed or asked)
  --verify               health check (PASS/WARN/FAIL table, exit 1 on any FAIL)
  --add-user NAME        create sudo user NAME and install an SSH public key
                         (alone: only that; with --mode: done as step 0.2)
  --reset                DROP and recreate the Zabbix database (db/single only, asks first)
  --apply-network        let step 0.3 apply the static IP (always with netplan try).
                         Without it, --yes only prints the netplan YAML.
  --env-file PATH        load ZBX_* values from PATH (default: ./zabbix-setup.env if present)
  --no-env-password      leave ZBX_DB_PASSWORD out of the ./zabbix-setup.env written at the end
  --no-dialog            plain text prompts instead of whiptail dialogs
  --agent | --no-agent   install Zabbix Agent 2 on this server, or not (default yes).
                         app/single: it monitors the server itself, not the Windows PC;
                         db: it lets the Zabbix server monitor the database server
  --verbose, -v          show every command (\$ ...) and its live output under each step
                         (default: one line per step - [✗] while running, [✓] done, [-] skipped;
                         without the flag the script asks "Show detailed output (verbose)?")
  --no-ufw               do not enable the ufw firewall (rules are then only added when
                         ufw is already active). Default: the firewall step (db 1.3,
                         app/single 2.7a) installs ufw, allows SSH FIRST, then the role's
                         ports (comment 'zabbix-setup'), sets deny incoming / allow
                         outgoing and enables it - after a yes to the rule list.
                         No SSH port detected: ufw is NOT enabled (not even with
                         --force) unless --ssh-port N names the port you connect with
  --force                continue on a non-${TARGET_UBUNTU} OS or a role mismatch
  --yes, -y              accept every default, never prompt
  --help, -h             this text

Values  (priority: flag > environment variable > env file > prompt)
  --app-ip IP            ZBX_APP_IP        db: app server allowed to connect
                                           app/single: this machine (detected)
  --db-ip IP             ZBX_DB_IP         app: the database server
  --db-port PORT         ZBX_DB_PORT       default ${DEFAULT_DB_PORT} (1024-65535); single mode:
                                           a custom port makes Zabbix use TCP to 127.0.0.1
  --db-name NAME         ZBX_DB_NAME       default ${DEFAULT_DB_NAME}
  --db-user NAME         ZBX_DB_USER       default ${DEFAULT_DB_USER}
  --db-password-file F   file holding the DB password: its first line, or a
                         ZBX_DB_PASSWORD= (or old DB_PASSWORD=) line - the hand-off works as is
                         ZBX_DB_PASSWORD   env var: sudo --preserve-env=ZBX_DB_PASSWORD ...
                                           (DB_PASSWORD still works but is deprecated)
  --timezone TZ          ZBX_TIMEZONE      default ${DEFAULT_TIMEZONE}
  --win-hostname NAME    ZBX_WIN_HOSTNAME  only used in the printed Windows steps
  --win-ip IP            ZBX_WIN_IP        the printed Windows steps; with ufw, 10051 is
                                           allowed from this IP only
  --iface IF  --static-ip IP  --prefix N  --gateway IP  --dns IP[,IP]
                         ZBX_IFACE ZBX_STATIC_IP ZBX_PREFIX ZBX_GATEWAY ZBX_DNS  (step 0.3)
                         --static-ip selects "configure" without asking; values not
                         given are detected. Applying still needs a yes or --apply-network.
  --mode                 ZBX_MODE
  --ssh-key-file F       ZBX_SSH_KEY_FILE  public key for --add-user
  --ssh-port N           ZBX_SSH_PORT      SSH port to allow in ufw (1-65535), added to the
                                           detected one; required when none is detected
  --agent / --no-agent   ZBX_INSTALL_AGENT yes|no
  --agent-hostname NAME  ZBX_AGENT_HOSTNAME Hostname= of that agent (= host name in the web UI);
                                           db default: hostname -s; app/single: Zabbix server
  --verbose / -v         ZBX_VERBOSE       yes = verbose output, no = one line per step (default)
  --no-ufw               ZBX_ENABLE_UFW    yes (default) | no

There is no --db-password flag on purpose: it would leak into shell history and ps.

Output
  A real run shows one line per step, numbered like the guide, redrawn in place:
      (7/9) [✗] 1.4 Create the database and user ...   <- running (spinner)
      (7/9) [✓] 1.4 Create the database and user ... (2s)
      (9/9) [-] 1.6 Install Zabbix Agent 2 ... (skipped: agent not requested)
  What the commands print goes to ${LOG_FILE} only (never the
  password). A failed step shows its last 15 lines, the error and a hint.
  --verbose prints every command and its output instead.
  Not a terminal (piped, cron): plain [..] / [OK] / [FAIL] lines.
  NO_COLOR=1 or TERM=dumb: no colours, no redraw. Non-UTF-8 locale: ASCII
  markers [ ] running, [v] done, [x] failed. --dry-run and --verify: as before.

Env file
  Lines of the form ZBX_NAME=value (optional 'export ', optional '...' or "..."
  around the value), # comment lines and blank lines. It is parsed line by
  line and never sourced: no \$variables, no \$(commands), no escapes. Unknown
  keys are ignored with a warning, a duplicated key stops the run. Every real
  run writes ./zabbix-setup.env with the settings it used (old copy: .bak).
  The db hand-off (zabbix-handoff.txt) is an env file too. Example:
      # zabbix-setup.env
      ZBX_MODE=app
      ZBX_APP_IP=<APP_IP>
      ZBX_DB_IP=<DB_IP>
      ZBX_DB_PORT=${DEFAULT_DB_PORT}
      ZBX_DB_PASSWORD='<password>'
  It can hold the password: keep it chmod 600 and out of git.

Examples
  sudo ./zabbix-setup.sh                                   # menu
  sudo ./zabbix-setup.sh --mode db --app-ip <APP_IP>
  sudo ./zabbix-setup.sh --mode app --env-file ./zabbix-handoff.txt
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
      --ssh-port)         _setv SSH_PORT "$@"; shift 2 ;;
      --db-password-file) _need "$@"; PW_FILE=$2; shift 2 ;;
      --add-user)         _need "$@"; ADD_USER=$2; shift 2 ;;
      --env-file)         _need "$@"; ENV_FILE=$2; shift 2 ;;
      --no-env-password)  NO_ENV_PASSWORD=true; shift ;;
      --apply-network)    APPLY_NETWORK=true; shift ;;
      --no-dialog)        NO_DIALOG=true; shift ;;
      --agent)            INSTALL_AGENT=yes; SRC[INSTALL_AGENT]="flag --agent"; shift ;;
      --no-agent)         INSTALL_AGENT=no; SRC[INSTALL_AGENT]="flag --no-agent"; shift ;;
      --agent-hostname)   _setv AGENT_HOSTNAME "$@"; shift 2 ;;
      --verbose|-v)       VERBOSE=yes; SRC[VERBOSE]="flag $1"; shift ;;
      --no-ufw)           ENABLE_UFW=no; SRC[ENABLE_UFW]="flag --no-ufw"; shift ;;
      --dry-run)          DRY_RUN=true; shift ;;
      --verify)           DO_VERIFY=true; shift ;;
      --reset)            RESET=true; shift ;;
      --force)            FORCE=true; shift ;;
      --yes|-y)           ASSUME_YES=true; shift ;;
      --help|-h)          SHOW_HELP=true; shift ;;
      --db-password|--password|--db-pass|--pw)
        die "There is deliberately no password flag (shell history, ps)." \
            "Use --db-password-file PATH, the ZBX_DB_PASSWORD environment variable, an env file, or the hidden prompt." ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
  MODE=$(normalize_mode "$MODE")
  return 0
}

# --- Env file (--env-file, or ./zabbix-setup.env): parsed, NEVER sourced ----
# Accepted: ZBX_NAME=value, optional "export ", optional '...' or "..." around
# the value (only that outer pair is removed - no escapes, no expansion), #
# comment lines, blank lines. Anything else stops the run with the line number.
declare -rA ENV_VALIDATORS=(
  [MODE]=v_mode [APP_IP]=v_ip [DB_IP]=v_ip [DB_PORT]=v_port [DB_NAME]=v_dbname
  [DB_USER]=v_dbuser [TIMEZONE]=v_tz [WIN_HOSTNAME]=v_winhost [WIN_IP]=v_ip_opt
  [IFACE]=v_iface [STATIC_IP]=v_ip [PREFIX]=v_prefix [GATEWAY]=v_ip [DNS]=v_dns
  [SSH_KEY_FILE]=v_path [SSH_PORT]=v_ssh_port [DB_PASSWORD]=v_password [INSTALL_AGENT]=v_yesno [AGENT_HOSTNAME]=v_agent_host
  [VERBOSE]=v_verbose [ENABLE_UFW]=v_yesno
)
_env_unquote() {   # _env_unquote RAW -> REPLY (outer quotes off, literal)
  local v=$1 q
  if ((${#v} >= 2)); then
    q=${v:0:1}
    if [[ ($q == '"' || $q == "'") && ${v: -1} == "$q" ]]; then REPLY=${v:1:${#v}-2}; return 0; fi
  fi
  v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
  REPLY=$v
}
_mode_warn() {     # _mode_warn FILE - warn when group/other can read it
  local mode
  mode=$(stat -c '%a' "$1" 2>/dev/null || echo 600)
  if [[ $mode =~ [1-7]$ || $mode =~ [1-7].$ ]]; then
    warn "$1 is readable by other users (mode ${mode}) and may hold the DB password - chmod 600 it."
  fi
  return 0
}
load_env_file() {  # load_env_file PATH - fills only values no flag/env var set
  local f=$1 line n=0 key name val
  local -A seen=()
  local re='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$' re_skip='^[[:space:]]*(#.*)?$'
  [[ -r $f ]] || die "Cannot read env file ${f}"
  _mode_warn "$f"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ $re_skip ]] && continue
    [[ $line =~ $re ]] || die "${f} line ${n}: not a ZBX_NAME=value line (only those, # comments and blank lines are allowed)."
    key=${BASH_REMATCH[2]}
    _env_unquote "${BASH_REMATCH[3]}"; val=$REPLY
    if [[ -n ${seen[$key]:-} ]]; then die "${f} line ${n}: duplicate key ${key} (already set on line ${seen[$key]}) - keep only one."; fi
    seen[$key]=$n
    name=${key#ZBX_}
    if [[ $key != ZBX_?* || -z ${ENV_VALIDATORS[$name]:-} ]]; then warn "${f} line ${n}: unknown key ${key} - ignored"; continue; fi
    [[ -n $val ]] || continue
    [[ $name == MODE ]] && val=$(normalize_mode "$val")
    "${ENV_VALIDATORS[$name]}" "$val" || die "${f} line ${n}: ${key} is invalid: ${VERR}"
    if [[ $name == DB_PASSWORD ]]; then
      # never printed or logged; a flag (--db-password-file) or env var wins
      if [[ -z $PW_ORIGIN && -z $PW_FILE ]]; then DB_PASSWORD=$val; PW_ORIGIN="env file ${f}"; fi
      continue
    fi
    if [[ -z ${SRC[$name]:-} ]]; then printf -v "$name" '%s' "$val"; SRC[$name]="env file ${f}"; fi
  done <"$f"
  return 0
}
pick_env_file() {  # --env-file, or ./zabbix-setup.env when it exists
  if [[ -n $ENV_FILE ]]; then
    say "Loading settings from env file ${ENV_FILE} (--env-file)"
  elif [[ -f $DEFAULT_ENV_FILE ]]; then
    ENV_FILE=$DEFAULT_ENV_FILE
    say "Loading settings from ${ENV_FILE} (found in the current directory; --env-file picks another)"
  else
    return 0
  fi
  load_env_file "$ENV_FILE"
  MODE=$(normalize_mode "$MODE")
}

# --- State file: non-secret settings of the last successful run -------------
load_state() {
  local line key val
  [[ -r $STATE_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^(MODE|APP_IP|DB_IP|DB_PORT|DB_NAME|DB_USER|TIMEZONE|INSTALL_AGENT|AGENT_HOSTNAME|ENABLE_UFW|SSH_PORT)=(.*)$ ]] || continue
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
    # the Agent 2 choice (all modes) and, when installed, its host name
    printf 'INSTALL_AGENT=%s\n' "$INSTALL_AGENT"
    printf 'ENABLE_UFW=%s\n' "$ENABLE_UFW"   # read by --verify (ufw checks)
    if [[ -n $SSH_PORT ]]; then printf 'SSH_PORT=%s\n' "$SSH_PORT"; fi
    if [[ $INSTALL_AGENT == yes ]]; then printf 'AGENT_HOSTNAME=%s\n' "$AGENT_HOSTNAME"; fi
  } >"${STATE_FILE}.tmp"
  chmod 600 "${STATE_FILE}.tmp"
  mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
  info "settings saved to ${STATE_FILE} (no password)"
}

choose_mode() {
  if [[ -n $MODE ]]; then v_mode "$MODE" || die "--mode: ${VERR}"; return 0; fi
  [[ $ASSUME_YES == true ]] && die "--yes needs --mode single|db|app (or ZBX_MODE)"
  local c rc=0
  if [[ $USE_DIALOG == true ]]; then
    c=$(_dlg --title "Scenario" --menu "Which scenario?" 14 76 3 \
          1 "Single VM (Zabbix + MySQL on the same machine)" \
          2 "Two VMs: this machine is the DATABASE server" \
          3 "Two VMs: this machine is the APP/WEB server") || rc=$?
    ((rc == 0)) || die "Cancelled - nothing was changed."
    MODE=$(normalize_mode "$c")
    _record "Scenario chosen: ${MODE}"
    return 0
  fi
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
  local def=n dyn netline dhcp_warn
  net_detect
  case $DET_DYNAMIC in yes) dyn="DHCP lease" ;; no) dyn="not from DHCP" ;; *) dyn="unknown" ;; esac
  netline="Network now: interface ${DET_IFACE:-?}, address ${DET_IP:-?}/${DET_PREFIX:-?}, gateway ${DET_GW:-?}, DNS ${DET_DNS:-?} (${dyn})"
  dhcp_warn="A DHCP address can change on reboot or lease renewal. That silently breaks the MySQL user (tied to the app IP) and the Windows agent (Server=/ServerActive=)."
  say ""
  say "  ${netline}"
  say "  (The Windows agent needs a stable address for the app server, and the MySQL user is tied to the app server's IP.)"
  # --static-ip / ZBX_STATIC_IP given: take the "configure" branch without
  # asking; values not given are detected. Applying is decided in step 0.3.
  if [[ -n ${SRC[STATIC_IP]:-} ]]; then
    _static_values auto
    return 0
  fi
  [[ $DET_DYNAMIC == no ]] && def=y
  if ask_yn "Does this server already have a static IP?" "$def" "$netline"; then
    if [[ -n $DET_IP ]] && ask_yn "Use ${DET_IP}/${DET_PREFIX} on ${DET_IFACE} (gateway ${DET_GW:-none}) as this server's address?" y; then
      NET_ACTION=keep; HOST_IP=$DET_IP
      IFACE=$DET_IFACE; STATIC_IP=$DET_IP; PREFIX=$DET_PREFIX; GATEWAY=$DET_GW; DNS=$DET_DNS
      return 0
    fi
  fi
  warn "$dhcp_warn"
  if ask_yn "Configure a static IP now with netplan? (n = skip and continue)" n "$dhcp_warn"; then
    _static_values prompt
  else
    NET_ACTION=skip; HOST_IP=$DET_IP
  fi
}
# _static_values prompt|auto - collect IFACE/STATIC_IP/PREFIX/GATEWAY/DNS.
# auto: a value with no flag/env/env-file source takes the detected one
# without a question (it is shown as "from detected").
_static_values() {
  local how=$1
  _static_one IFACE     "Interface:"                      "$DET_IFACE"           v_iface  "$how"
  _static_one STATIC_IP "Static IP:"                      "$DET_IP"              v_ip     "$how"
  _static_one PREFIX    "Prefix length:"                  "${DET_PREFIX:-24}"    v_prefix "$how"
  _static_one GATEWAY   "Gateway:"                        "$DET_GW"              v_ip     "$how"
  _static_one DNS       "DNS server(s), comma-separated:" "${DET_DNS:-$GATEWAY}" v_dns    "$how"
  DNS=${DNS// /,}
  NET_ACTION=configure; HOST_IP=$STATIC_IP
  # --yes never applies a network change without --apply-network, so the
  # address this server keeps is the current one.
  if [[ $ASSUME_YES == true && $APPLY_NETWORK != true && -n $DET_IP ]]; then HOST_IP=$DET_IP; fi
  return 0
}
_static_one() {   # _static_one VAR "Question" DEFAULT VALIDATOR prompt|auto
  if [[ $5 == auto && -z ${SRC[$1]:-} ]] && "$4" "$3"; then
    printf -v "$1" '%s' "$3"; SRC[$1]="detected"
  fi
  ask "$1" "$2" "$3" "$4"
}

probe_existing_user() {   # re-run detection (real runs only)
  USER_EXISTS=false
  [[ $DRY_RUN == true || $MODE == app ]] && return 0
  command -v mysql >/dev/null 2>&1 && svc_active mysql || return 0
  local host n other
  if [[ $MODE == single ]]; then host=localhost; else host=$APP_IP; fi
  other=${ST_APP_IP:-$host}
  [[ $MODE == single && $SINGLE_CUSTOM_PORT == true ]] && other=127.0.0.1
  n=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host IN ('${host}','${other}')" 2>/dev/null) || n=0
  [[ $n != 0 ]] && USER_EXISTS=true
  return 0
}

# _pw_from_file FILE -> REPLY = the password in a hand-off/env file: a
# ZBX_DB_PASSWORD= line (current format, quotes removed) or a DB_PASSWORD=
# line (hand-off files of version 1.0, raw). PW_MARKER=true for a hand-off.
PW_MARKER=false; PW_FIRST=""
_pw_from_file() {
  local line first="" re='^[[:space:]]*(export[[:space:]]+)?ZBX_DB_PASSWORD=(.*)$'
  REPLY=""; PW_MARKER=false; PW_FIRST=""
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line == *"zabbix-setup hand-off"* ]] && PW_MARKER=true
    if [[ $line =~ $re ]]; then _env_unquote "${BASH_REMATCH[2]}"; return 0; fi
    if [[ $line == DB_PASSWORD=* ]]; then REPLY=${line#DB_PASSWORD=}; return 0; fi
    if [[ -z $first && -n $line ]]; then first=$line; fi
  done <"$1"
  PW_FIRST=$first
  return 0
}

read_password_file() {
  local f=$1
  [[ -r $f ]] || die "Cannot read --db-password-file ${f}"
  _mode_warn "$f"
  _pw_from_file "$f"
  if [[ -z $REPLY ]]; then
    [[ $PW_MARKER == true ]] && die "${f} is a hand-off file without a ZBX_DB_PASSWORD= line (password was kept on a re-run). Use the earlier hand-off file or type the password."
    REPLY=$PW_FIRST
  fi
  DB_PASSWORD=$REPLY; REPLY=""; PW_FIRST=""
}

previous_handoff_password() {   # password line of an earlier hand-off file
  [[ -r $HANDOFF_FILE ]] || return 0
  _pw_from_file "$HANDOFF_FILE"
  printf '%s' "$REPLY"
}

collect_password() {
  local p1 p2 conf_pw="" keep_ok=false prompt
  # --dry-run never uses the password: nothing is asked, read or checked.
  if [[ $DRY_RUN == true ]]; then
    DB_PASSWORD=""; PW_ORIGIN="not needed for --dry-run"
    say "  DB password: ${MASK}   (--dry-run: not asked)"
    return 0
  fi
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
      [[ -n $conf_pw ]] || die "--yes in app mode needs the password: --env-file ./zabbix-handoff.txt, --db-password-file or ZBX_DB_PASSWORD (from the DB server's hand-off)."
      DB_PASSWORD=$conf_pw; PW_ORIGIN="existing zabbix_server.conf"; return 0
    fi
    prompt="  DB password (from the DB server's hand-off block): "
    [[ -n $conf_pw ]] && prompt="  DB password (press Enter to reuse the one in zabbix_server.conf): "
    while true; do
      read_hidden p1 "$prompt"
      if [[ -z $p1 && -n $conf_pw ]]; then DB_PASSWORD=$conf_pw; PW_ORIGIN="existing zabbix_server.conf"; return 0; fi
      if v_password "$p1"; then DB_PASSWORD=$p1; PW_ORIGIN="typed"; return 0; fi
      warn "${VERR} - try again."; DLG_ERR=$VERR
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
    if ! v_password "$p1"; then warn "${VERR} - try again."; DLG_ERR=$VERR; continue; fi
    read_hidden p2 "  Confirm DB password: "
    if [[ $p1 != "$p2" ]]; then warn "The two entries differ - try again."; DLG_ERR="the two entries differ"; continue; fi
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
  if [[ $ST_MODE != "$MODE" ]]; then ST_APP_IP=""; ST_DB_IP=""; ST_DB_PORT=""; ST_DB_NAME=""; ST_DB_USER=""; ST_INSTALL_AGENT=""; ST_AGENT_HOSTNAME=""; ST_ENABLE_UFW=""; fi
  ask_verbose
  static_ip_prompt
  case $MODE in
    db)
      ask APP_IP "App/web server IP (the only host allowed to connect to MySQL):" "${ST_APP_IP}" v_ip
      if [[ -z ${SRC[DB_IP]:-} ]]; then DB_IP=$HOST_IP; fi
      if ! v_ip "$DB_IP"; then
        [[ $DRY_RUN == true ]] || die "Could not detect this server's IP for the hand-off; pass --db-ip."
        DB_IP="<DB_IP>"
      fi
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
  ask_install_agent
  if [[ $MODE != db ]]; then
    ask WIN_HOSTNAME "Windows host name for the printed steps:" "" v_winhost
    ask WIN_IP "Windows IP for the printed steps (also limits ufw port ${ZBX_TRAPPER_PORT} to it; Enter = any):" "" v_ip_opt
  fi
  ask_enable_ufw
  confirm_reset
}

# VERBOSE: every command and its live output instead of one line per step.
# Priority flag > environment > env file > prompt; default no. Not asked in
# --dry-run (its output does not change).
ask_verbose() {
  local src=${SRC[VERBOSE]:-} q="Show detailed output (verbose)?"
  if [[ -n $src ]]; then
    v_verbose "$VERBOSE" || die "VERBOSE='${VERBOSE}' from ${src} is invalid: ${VERR}"
    case ${VERBOSE,,} in 1|yes|true) VERBOSE=yes ;; *) VERBOSE=no ;; esac
    say "  ${q} ${VERBOSE}   (from ${src})"
    return 0
  fi
  if [[ $DRY_RUN == true ]]; then VERBOSE=no; return 0; fi
  if ask_yn "$q" n "yes: every command and its output under each step.  no: one line per step (the full output still goes to ${LOG_FILE})."; then
    VERBOSE=yes
  else
    VERBOSE=no
  fi
  return 0
}

# ENABLE_UFW: the firewall step (db: 1.3, app/single: 2.7a) installs ufw,
# adds the rules below (SSH first) and enables it. no (--no-ufw,
# ZBX_ENABLE_UFW=no): rules are only added when ufw is already active, as
# before. The question shows the exact commands.
ask_enable_ufw() {
  local src=${SRC[ENABLE_UFW]:-} q="Enable the ufw firewall with these rules?" text l def=y
  if [[ -n $SSH_PORT ]] && ! v_ssh_port "$SSH_PORT"; then die "SSH_PORT='${SSH_PORT}' from ${SRC[SSH_PORT]:-?} is invalid: ${VERR}"; fi
  detect_ssh_ports
  ufw_plan
  if [[ -n $src ]]; then
    v_yesno "$ENABLE_UFW" || die "ENABLE_UFW='${ENABLE_UFW}' from ${src} is invalid: ${VERR}"
    ENABLE_UFW=${ENABLE_UFW,,}
    say "  ${q} ${ENABLE_UFW}   (from ${src})"
    return 0
  fi
  text="The firewall step would run, in this order:"
  say "  ${text}"
  while IFS= read -r l; do say "      ${l}"; text+=$'\n'"  ${l}"; done < <(ufw_plan_lines)
  if ((${#SSH_PORTS[@]} == 0)); then
    warn "No SSH port detected - ufw will NOT be enabled (it could lock you out). Pass --ssh-port N (the port you connect with) to enable it; --force does not."
  fi
  if ask_yn "$q" "$def" "$text"; then ENABLE_UFW=yes; else ENABLE_UFW=no; fi
  return 0
}

# INSTALL_AGENT: Zabbix Agent 2 on this server. app/single: it monitors the
# server itself (the built-in "Zabbix server" host), not the Windows PC.
# db: it lets the Zabbix server monitor the database server (step 1.6).
# Default yes. Priority flag > environment > env file > prompt; a re-run
# without any of them offers the previous choice from the state file.
ask_install_agent() {
  local def=y q="Install Zabbix Agent 2 on this server (it monitors this server itself, not the Windows PC)?"
  local src=${SRC[INSTALL_AGENT]:-}
  [[ $MODE == db ]] && q="Install Zabbix Agent 2 on this database server so the Zabbix server can monitor it?"
  if [[ -n $src ]]; then
    if v_yesno "$INSTALL_AGENT"; then
      INSTALL_AGENT=${INSTALL_AGENT,,}; say "  ${q} ${INSTALL_AGENT}   (from ${src})"
      ask_agent_hostname; return 0
    fi
    warn "INSTALL_AGENT='${INSTALL_AGENT}' from ${src} is invalid: ${VERR}"
    [[ $ASSUME_YES == true ]] && die "Fix the ${src} value for INSTALL_AGENT and re-run."
  fi
  [[ ${ST_INSTALL_AGENT,,} == no ]] && def=n
  if ask_yn "$q" "$def"; then INSTALL_AGENT=yes; else INSTALL_AGENT=no; fi
  ask_agent_hostname
  return 0
}

# AGENT_HOSTNAME: Hostname= in zabbix_agent2.conf, and the host name to use
# in the web UI. db: asked, default the short system hostname. app/single:
# not asked - the package default "Zabbix server" (the built-in host) stays,
# unless --agent-hostname / ZBX_AGENT_HOSTNAME / an env file sets another.
ask_agent_hostname() {
  [[ $INSTALL_AGENT == yes ]] || return 0
  local def
  if [[ $MODE == db ]]; then
    def=${ST_AGENT_HOSTNAME:-$(hostname -s 2>/dev/null || true)}
    ask AGENT_HOSTNAME "Agent host name (Hostname= in zabbix_agent2.conf, and the host name in the web UI):" "$def" v_agent_host
    if [[ $AGENT_HOSTNAME == "$ZBX_DEFAULT_AGENT_HOST" ]]; then
      warn "'${ZBX_DEFAULT_AGENT_HOST}' is the built-in host of the Zabbix server itself - this database server would clash with it. Pick another name (--agent-hostname)."
    fi
  elif [[ -n ${SRC[AGENT_HOSTNAME]:-} ]]; then
    ask AGENT_HOSTNAME "Agent host name (Hostname= in zabbix_agent2.conf):" "$ZBX_DEFAULT_AGENT_HOST" v_agent_host
  else
    AGENT_HOSTNAME=${ST_AGENT_HOSTNAME:-$ZBX_DEFAULT_AGENT_HOST}
  fi
  return 0
}

# --reset: the only destructive action. Asked here, before anything changes,
# always (even with --yes): a yes/no, then the database name must be typed.
confirm_reset() {
  [[ $RESET == true && $MODE != app && $DRY_RUN != true ]] || return 0
  local ans="" rc=0 msg="--reset will permanently DELETE the database '${DB_NAME}' and all Zabbix data in it."
  [[ $MODE == db ]] && msg+=" Stop zabbix-server on the app server first: sudo systemctl stop zabbix-server"
  warn "$msg"
  if [[ $USE_DIALOG == true ]]; then
    _dlg --title "--reset" --defaultno --yesno "${msg}"$'\n\n'"Really drop it?" 14 76 || die "Not confirmed - nothing was dropped."
    ans=$(_dlg --title "--reset" --inputbox "Type the database name (${DB_NAME}) to confirm the DROP:" 10 76 "") || rc=$?
    ((rc == 0)) || ans=""
  else
    IFS= read -r -p "  Type the database name (${DB_NAME}) to confirm the DROP: " ans || ans=""
  fi
  [[ $ans == "$DB_NAME" ]] || die "Not confirmed - nothing was dropped."
  RESET_CONFIRMED=true
  _record "  --reset confirmed for database ${DB_NAME}"
}

SUMMARY_LINES=()
build_summary() {   # SUMMARY_LINES - shown as text and in the dialog (password masked)
  local net=$NET_ACTION
  SUMMARY_LINES=("  Scenario      : ${MODE}")
  case $MODE in
    db)     SUMMARY_LINES+=("  This DB server: ${DB_IP}   (port ${DB_PORT})"
                            "  App server    : ${APP_IP}  (only host allowed to log in)") ;;
    app)    SUMMARY_LINES+=("  This server   : ${APP_IP}" "  DB server     : ${DB_IP}:${DB_PORT}") ;;
    single) SUMMARY_LINES+=("  This server   : ${APP_IP}")
            if [[ $SINGLE_CUSTOM_PORT == true ]]; then SUMMARY_LINES+=("  MySQL         : 127.0.0.1:${DB_PORT} over TCP (custom port)")
            else SUMMARY_LINES+=("  MySQL         : localhost via socket (wizard port 0)"); fi ;;
  esac
  if [[ $net == configure && $APPLY_NETWORK != true && $ASSUME_YES == true ]]; then net="configure (print only: no --apply-network)"; fi
  SUMMARY_LINES+=("  Database/user : ${DB_NAME} / ${DB_USER}"
                  "  DB password   : ${MASK}   (${PW_ORIGIN})"
                  "  Timezone      : ${TIMEZONE}"
                  "  Static IP     : ${net}${STATIC_IP:+ (${STATIC_IP}/${PREFIX} via ${GATEWAY:-?} on ${IFACE:-?})}")
  [[ -n $ADD_USER ]] && SUMMARY_LINES+=("  Admin user    : ${ADD_USER}")
  [[ $RESET == true ]] && SUMMARY_LINES+=("  RESET         : database ${DB_NAME} will be DROPPED and recreated")
  SUMMARY_LINES+=("  Agent 2 on this server: ${INSTALL_AGENT}")
  if [[ $INSTALL_AGENT == yes ]]; then SUMMARY_LINES+=("  Agent host name: ${AGENT_HOSTNAME}"); fi
  if [[ $ENABLE_UFW == yes ]]; then
    SUMMARY_LINES+=("  Firewall (ufw): enable it - SSH ${SSH_PORTS[*]:-<not detected: will NOT be enabled>} first, then the ports of this role")
  else
    SUMMARY_LINES+=("  Firewall (ufw): not enabled by choice (rules only if ufw is already active)")
  fi
  if [[ $MODE != db ]]; then
    SUMMARY_LINES+=("  Windows host  : ${WIN_HOSTNAME:-<WIN_HOSTNAME>} / ${WIN_IP:-<WIN_IP>}")
  fi
  [[ -n $ENV_FILE ]] && SUMMARY_LINES+=("  Env file      : ${ENV_FILE}")
  SUMMARY_LINES+=("  Output files  : ${OUT_DIR}")
  if [[ $DRY_RUN != true ]]; then SUMMARY_LINES+=("  Verbose output: ${VERBOSE:-no}" "  Full output   : ${LOG_FILE}"); fi
  return 0
}
show_summary() {
  local l
  part "Summary"
  for l in "${SUMMARY_LINES[@]}"; do say "$l"; done
  return 0
}
# confirm_summary: the last question before anything is changed. In dialog
# mode this is the summary screen (password masked); 1 = do not proceed.
confirm_summary() {
  local text l n=0 h rows=24 s
  if [[ $USE_DIALOG == true ]]; then
    # The question goes FIRST: if the list is taller than the terminal, only
    # its last lines are cut, never the question. "Full output" stays in the
    # text summary only. Height: the text + 7 (frame, buttons), at most the
    # terminal height.
    text="Proceed with these settings?"$'\n'
    for l in "${SUMMARY_LINES[@]}"; do
      [[ $l == "  Full output"* ]] && continue
      text+=$'\n'"${l}"; n=$((n + 1))
    done
    s=$(stty size </dev/tty 2>/dev/null || true)
    if [[ $s =~ ^([0-9]+)\ [0-9]+$ ]] && ((BASH_REMATCH[1] >= 16)); then rows=${BASH_REMATCH[1]}; fi
    h=$((n + 9)); ((h > rows)) && h=$rows; ((h < 16)) && h=16
    # no --scrolltext: it moves the focus to the text, and Enter stops working
    _dlg --title "Summary - nothing has been changed yet" --yesno "$text" "$h" 78 || return 1
    _record "  Proceed with these settings? -> yes (summary dialog)"
    return 0
  fi
  ask_yn "Proceed with these settings?" y
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
    case $st in PASS) color=$C_GREEN ;; WARN) color=$C_YELLOW ;; SKIP) color="" ;; *) color=$C_RED ;; esac
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
  else vrow FAIL "running as root" "uid ${EUID}" "sudo ${LAUNCH} ${ARGS_TEXT}"; fi

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

  # Zabbix repo (needed for app/single, and for db only when the agent is
  # requested) - catches the 404 from a wrong path
  if [[ $MODE != db || $INSTALL_AGENT == yes ]]; then
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
      if ! v_ip "$APP_IP"; then vrow WARN "app server ${APP_IP} answers ping" "placeholder - not checked (--dry-run)"
      elif command -v ping >/dev/null 2>&1 && ping -c1 -W2 "$APP_IP" >/dev/null 2>&1; then vrow PASS "app server ${APP_IP} answers ping" ""
      else vrow WARN "app server ${APP_IP} answers ping" "no reply (may just block ICMP)"; fi
      ;;
    app)
      if is_local_ip "$DB_IP"; then
        vrow FAIL "DB_IP is another machine" "${DB_IP} belongs to THIS server" "for one VM pick option 1 (single)"
      fi
      if [[ $DRY_RUN != true ]] && ! is_local_ip "$APP_IP"; then vrow WARN "APP_IP is this machine" "${APP_IP} is not on any local interface (OK only behind NAT)"; fi
      if pkg_installed mysql-server; then vrow WARN "role: APP server" "mysql-server is installed here - is this the DB machine (option 2)?"; fi
      _action "\$ timeout 3 bash -c '</dev/tcp/${DB_IP}/${DB_PORT}'   # is the DB server answering?"
      if [[ $DRY_RUN == true ]] && ! v_ip "$DB_IP"; then vrow WARN "DB server ${DB_IP}:${DB_PORT} answers" "placeholder - not checked (--dry-run)"
      elif tcp_open "$DB_IP" "$DB_PORT"; then vrow PASS "DB server ${DB_IP}:${DB_PORT} answers" "TCP connect OK"
      else
        vrow FAIL "DB server ${DB_IP}:${DB_PORT} answers" "no TCP answer within 3 s" "see the likely causes below"
        PF_HINTS+=("Likely causes, checked on the DB server ${DB_IP}:"
                   "  1. db mode not run yet          -> sudo ${LAUNCH} --mode db --app-ip ${APP_IP}"
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
  if [[ $MODE != db || $INSTALL_AGENT == yes ]] && pkg_installed zabbix-agent; then
    vrow WARN "classic zabbix-agent absent" "installed - it also uses port ${ZBX_AGENT_PORT}" "sudo apt remove zabbix-agent (this setup uses zabbix-agent2)"
  fi
  if [[ $RESET == true && $MODE == app ]]; then
    vrow FAIL "--reset on the right node" "app mode cannot drop the remote DB" "run --reset on the DB server: sudo ${LAUNCH} --mode db --reset"
  fi
  if [[ $ENABLE_UFW == yes ]]; then vrow PASS "ufw" "$(ufw_state) now - enabled in step $([[ $MODE == db ]] && echo 1.3 || echo 2.7a)"
  else vrow PASS "ufw" "$(ufw_state) (not enabled by choice: --no-ufw / ZBX_ENABLE_UFW=no)"; fi

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
  STEP_INSTALLED=true
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
    ui_pause
    IFS= read -r -p "  SSH public key for ${name} (path to a .pub file, or paste the key line; Enter = skip): " ans || ans=""
    ui_resume
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
    ui_pause                        # passwd talks to the terminal itself
    _xcmd "passwd ${name}"
    passwd "$name" || warn "passwd failed - run: sudo passwd ${name}"
    ui_resume
  else
    info "Remember: sudo passwd ${name}"
  fi
}

# Step 0.3 - static IP with netplan try (never a bare netplan apply)
apply_static_ip() {
  step 0.3 "Static IP for this server"
  case $NET_ACTION in
    keep) ok "static address ${HOST_IP} on ${IFACE} - nothing to change"; step_skip "${HOST_IP} is already static"; return 0 ;;
    skip)
      warn "Skipped. If this address (${HOST_IP:-unknown}) changes, the MySQL user / Windows agent config break. Re-run later to fix, or reserve the IP in DHCP."
      step_skip "not requested"
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
    _action "\$ sudo install -d -m 700 ${BACKUP_ROOT} && sudo mkdir -p ${BACKUP_DIR}${NETPLAN_DIR} && sudo cp -a ${NETPLAN_DIR}/*.yaml ${BACKUP_DIR}${NETPLAN_DIR}/ && sudo chmod 600 ${BACKUP_DIR}${NETPLAN_DIR}/*.yaml"
  else
    for f in "$NETPLAN_DIR"/*.yaml; do [[ -e $f ]] && backup_file "$f"; done
  fi
  local -a ylines; mapfile -t ylines <<<"$yaml"
  _action "write ${NETPLAN_FILE}:" "${ylines[@]}"
  _action "\$ sudo chmod 600 ${NETPLAN_FILE}"
  _action "\$ sudo netplan try --timeout ${NETPLAN_TRY_TIMEOUT}   # press ENTER to keep; no ENTER = automatic rollback"
  [[ $DRY_RUN == true ]] && return 0

  # Applying needs an explicit opt-in: --apply-network, or a yes typed now.
  # --yes alone never changes the network: the YAML above is all it does.
  if [[ $APPLY_NETWORK != true && $ASSUME_YES == true ]]; then
    warn "Not applied and nothing written: --yes never changes the network by itself. The YAML above is what would be written."
    warn "Reminder: re-run with --apply-network to apply it (netplan try), from the VM console if the address changes."
    step_skip "printed only - --yes needs --apply-network"
    return 0
  fi
  warn "Changing the IP over SSH can drop your session. netplan try rolls back after ${NETPLAN_TRY_TIMEOUT} s unless you press ENTER."
  if [[ $STATIC_IP != "$DET_IP" ]]; then
    warn "The address changes (${DET_IP:-?} -> ${STATIC_IP}). Over SSH you will lose this session and cannot confirm - use the VM console for this step."
  fi
  if [[ $APPLY_NETWORK != true ]] && ! ask_yn "Apply this static IP now?" n; then
    warn "Not applied. Reminder: a changing DHCP address will break the setup later."
    step_skip "not applied"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    warn "Not applied: netplan try needs a terminal to confirm with ENTER (stdin is not a terminal). Nothing was written."
    step_skip "netplan try needs a terminal"
    return 0
  fi
  printf '%s\n' "$yaml" >"$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"
  _xcmd "netplan generate"
  if ! netplan generate 2>&1 | _logpipe; then
    rm -f "$NETPLAN_FILE"; warn "netplan generate rejected the file - removed it, nothing applied."
    step_skip "netplan generate rejected the file"
    return 0
  fi
  # netplan try asks for ENTER on the terminal: no spinner over it
  ui_pause
  _xcmd "netplan try --timeout ${NETPLAN_TRY_TIMEOUT}"
  netplan try --timeout "$NETPLAN_TRY_TIMEOUT" || true
  ui_resume
  net_detect
  if [[ $DET_IP == "$STATIC_IP" && $DET_DYNAMIC != yes ]]; then
    ok "static IP ${STATIC_IP}/${PREFIX} active on ${IFACE}"
  else
    rm -f "$NETPLAN_FILE"
    warn "Static IP not confirmed (rolled back). Removed ${NETPLAN_FILE}; previous files are in ${BACKUP_DIR}${NETPLAN_DIR}."
    step_skip "not confirmed - rolled back"
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
# Every host the Zabbix account is created for. Single mode with a custom
# port connects over TCP to 127.0.0.1, which MySQL may match as 'localhost' or
# as '127.0.0.1' - so both accounts exist, same password, same grants.
db_user_hosts() {
  db_user_host; printf '\n'
  if [[ $MODE == single && $SINGLE_CUSTOM_PORT == true ]]; then printf '127.0.0.1\n'; fi
  return 0
}

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
  [[ $STEP_INSTALLED == true ]] || step_skip "mysql-server already installed"

  # ---- 1.2 bind-address and port ------------------------------------------
  local need_restart=0
  if [[ $MODE == db ]]; then
    step 1.2 "Allow remote connections and set port ${DB_PORT}"
    mysqld_config_current "$DB_PORT" 0.0.0.0 || need_restart=$?
    backup_file "$MYSQLD_CNF"
    edit_kv "$MYSQLD_CNF" mysqld bind-address 0.0.0.0 ini
    edit_kv "$MYSQLD_CNF" mysqld port "$DB_PORT" ini
    restart_mysql_if_needed "$DB_PORT" "$need_restart"
  elif [[ $SINGLE_CUSTOM_PORT == true ]]; then
    step 1.2 "Set MySQL port ${DB_PORT} (single VM: bind-address stays 127.0.0.1)"
    mysqld_config_current "$DB_PORT" || need_restart=$?
    backup_file "$MYSQLD_CNF"
    edit_kv "$MYSQLD_CNF" mysqld port "$DB_PORT" ini
    restart_mysql_if_needed "$DB_PORT" "$need_restart"
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
      step_skip "single VM uses the local socket"
    fi
  fi

  # ---- 1.3 Firewall ----------------------------------------------------------
  if [[ $MODE == db && $ENABLE_UFW == yes ]]; then
    step 1.3 "Firewall (ufw): allow the needed ports and enable it"
    setup_ufw open_db_firewall
  elif [[ $MODE == db ]]; then
    step 1.3 "Open the firewall for MySQL"
    open_db_firewall
  else
    step 1.3 "Open the firewall for MySQL"
    skip "single VM: MySQL is only used locally - nothing to open"
    step_skip "single VM: MySQL is only used locally"
  fi

  # ---- 1.4 Database and user ---------------------------------------------------
  step 1.4 "Create the database and user (CREATE USER before GRANT - MySQL 8)"
  if [[ $DRY_RUN != true ]]; then
    mysql_root -e "SELECT 1" >/dev/null 2>&1 || die "Cannot log in to MySQL as root through the socket (sudo mysql)." \
      "If root has a password, put it in /root/.my.cnf ([client] password=...) and re-run."
  fi
  [[ $RESET == true ]] && reset_database
  local host state trust grant_db sql_show sql_real pw_lit tail_sql=""
  local -a hosts=()
  mapfile -t hosts < <(db_user_hosts)
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
  for host in "${hosts[@]}"; do
    if [[ $PW_KEEP == true && $SINGLE_CUSTOM_PORT == true && -n $DB_PASSWORD ]]; then
      # single + custom port re-run: the kept password is known (from
      # zabbix_server.conf) - create only a missing account, change none.
      sql_show+=$'\n'"CREATE USER IF NOT EXISTS '${DB_USER}'@'${host}' IDENTIFIED BY '${MASK}';   -- password kept"
      sql_real+=$'\n'"CREATE USER IF NOT EXISTS '${DB_USER}'@'${host}' IDENTIFIED BY ${pw_lit};"
    elif [[ $PW_KEEP == true ]]; then
      sql_show+=$'\n'"-- '${DB_USER}'@'${host}' exists: password kept"
    else
      sql_show+=$'\n'"CREATE USER IF NOT EXISTS '${DB_USER}'@'${host}' IDENTIFIED BY '${MASK}';"
      sql_show+=$'\n'"ALTER USER '${DB_USER}'@'${host}' IDENTIFIED BY '${MASK}';   -- re-run safe"
      sql_real+=$'\n'"CREATE USER IF NOT EXISTS '${DB_USER}'@'${host}' IDENTIFIED BY ${pw_lit};"
      sql_real+=$'\n'"ALTER USER '${DB_USER}'@'${host}' IDENTIFIED BY ${pw_lit};"
    fi
    tail_sql+="GRANT ALL PRIVILEGES ON \`${grant_db}\`.* TO '${DB_USER}'@'${host}';"$'\n'
  done
  tail_sql+="SET GLOBAL log_bin_trust_function_creators = ${trust};"
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
    db_install_agent                                        # 1.6 (optional)
  elif [[ $SINGLE_CUSTOM_PORT == true ]]; then
    step 1.5 "Verify the zabbix user can log in over TCP (127.0.0.1:${DB_PORT})"
    _action "\$ mysql -h 127.0.0.1 -P ${DB_PORT} -u ${DB_USER} -p ${DB_NAME} -e 'SELECT 1;'"
    if [[ $DRY_RUN != true ]]; then
      make_cnf "$DB_USER" "$DB_PASSWORD"; set_db_target 127.0.0.1 "$DB_PORT"
      local out
      out=$(mysql_zbx "$DB_NAME" -e "SELECT 1" 2>&1) || die "TCP login as ${DB_USER} to 127.0.0.1:${DB_PORT} failed: $(explain_mysql_error "$out")"
      ok "${DB_USER} can log in over TCP to 127.0.0.1:${DB_PORT}"
    fi
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

# A re-run with the same settings must not restart MySQL: that would cut the
# app server's zabbix-server off for a moment. Called BEFORE the edits.
# Returns 0 = already current (no restart), 1 = differs or not listening.
mysqld_config_current() {   # mysqld_config_current PORT [BIND_ADDRESS]
  [[ $DRY_RUN == true ]] && return 1
  [[ $(kv_get "$MYSQLD_CNF" mysqld port || true) == "$1" ]] || return 1
  if [[ -n ${2:-} && $(kv_get "$MYSQLD_CNF" mysqld bind-address || true) != "$2" ]]; then return 1; fi
  [[ $(listen_addrs "$1") == *"${2:-}:$1"* ]] || return 1
  return 0
}
restart_mysql_if_needed() {  # restart_mysql_if_needed PORT 0|1
  if [[ $2 == 0 ]]; then
    _action "\$ sudo systemctl restart mysql"
    skip "bind-address/port already set and MySQL listens on $(listen_addrs "$1") - no restart needed"
    step_skip "already set - no restart needed"
    return 0
  fi
  restart_mysql_on_port "$1"
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
    step_skip "ufw is ${st}"
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

# ---- ufw step: db 1.3, app/single 2.7a (ENABLE_UFW=yes) --------------------
# Install ufw, drop 'zabbix-setup' rules that no longer match (DB port or an
# IP changed), add the SSH rule(s) FIRST, then the role's rules, then the
# default policies and enable. Never "ufw reset": other rules are kept. A
# re-run adds nothing twice (ufw show added is compared first). A rule that
# already exists WITHOUT the comment counts as present and is never touched:
# only rules carrying the comment are added or deleted. Without an SSH port
# ufw is not enabled: LEGACY_FN (the old "only if active") runs.
_in_list() { local x n=$1; shift; for x in "$@"; do [[ $x == "$n" ]] && return 0; done; return 1; }
setup_ufw() {   # setup_ufw LEGACY_FN
  local legacy=$1 st r l note n_add=0 n_del=0 n_unm=0
  local -a words=() have=()
  detect_ssh_ports
  ufw_plan
  if ((${#SSH_PORTS[@]} == 0)); then
    warn "No SSH port detected (sshd -T, ss -ltnp, /etc/ssh/sshd_config) - ufw is NOT enabled, so this server cannot lock you out. To enable it, re-run with --ssh-port N (the SSH port you connect with)."
    "$legacy"
    step_skip "ufw not enabled: no SSH port detected"
    return 0
  fi
  warn "A firewall change over SSH can cut the connection. The SSH rule (port ${SSH_PORTS[*]}; source: ${SSH_PORT_SRC}) is added first, before ufw is enabled."
  apt_install "sudo apt install ufw -y" ufw
  if [[ $DRY_RUN == true ]]; then
    _action "\$ sudo ufw show added   # rules '${UFW_COMMENT}' that no longer match (DB port / IP changed) are deleted first"
    for r in "${UFW_RULES[@]}"; do _action "\$ $(_ufw_shown "$r")"; done
    _action "\$ sudo ufw default deny incoming   # only if ufw is not active yet"
    _action "\$ sudo ufw default allow outgoing"
    _action "\$ sudo ufw --force enable"
    _action "\$ sudo ufw status numbered"
    return 0
  fi
  st=$(ufw_state)
  _action "\$ sudo ufw status   # -> ${st}"
  mapfile -t have < <(ufw_added_rules)
  for l in "${have[@]}"; do
    [[ $l == *" comment ${UFW_COMMENT}" ]] || continue
    _in_list "$l" "${UFW_RULES[@]}" && continue
    r=${l% comment "$UFW_COMMENT"}
    # only the kinds of rule this step creates - never an SSH rule; the agent
    # rule stays when the agent is not requested (a "no" never removes it)
    case $r in
      "allow from "*" to any port ${ZBX_AGENT_PORT} proto tcp") [[ $INSTALL_AGENT == yes ]] || continue ;;
      "allow from "*" to any port "*" proto tcp"|"allow ${HTTP_PORT}/tcp"|"allow ${ZBX_TRAPPER_PORT}/tcp") ;;
      *) continue ;;
    esac
    read -r -a words <<<"$r"
    run_show "sudo ufw delete ${r}   # old '${UFW_COMMENT}' rule" ufw delete "${words[@]}"
    n_del=$((n_del + 1))
  done
  for r in "${UFW_RULES[@]}"; do
    if _in_list "$r" "${have[@]}"; then _action "\$ $(_ufw_shown "$r")"; skip "rule already there"; continue; fi
    # the same rule without the comment (added by hand or by an older run):
    # it already does the job - left untouched, never adopted or deleted
    if _in_list "${r% comment "$UFW_COMMENT"}" "${have[@]}"; then
      _action "\$ $(_ufw_shown "$r")"
      skip "already present (not managed by the script): ufw ${r% comment "$UFW_COMMENT"}"
      n_unm=$((n_unm + 1)); continue
    fi
    read -r -a words <<<"$r"
    run_show "$(_ufw_shown "$r")" ufw "${words[@]}"
    n_add=$((n_add + 1))
  done
  if [[ $st == active ]]; then
    note="already active, ${n_add} rule(s) added"
  else
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw --force enable
    note="enabled, ${n_add} rule(s) added"
  fi
  ((n_del > 0)) && note+=", ${n_del} old rule(s) removed"
  ((n_unm > 0)) && note+=", ${n_unm} already present (not managed by the script)"
  _xcmd "ufw status numbered"
  ufw status numbered 2>&1 | _logpipe
  FW_CHANGED+=("ufw ${note}")
  say "      ufw: ${note}"
  step_info "ufw ${note}"
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

# --reset: the only destructive action. It was confirmed (typed database
# name) in confirm_reset, before anything changed - always, even with --yes.
reset_database() {
  _action "\$ sudo mysql -e \"DROP DATABASE IF EXISTS \\\`${DB_NAME}\\\`;\"   # --reset (guide troubleshooting: ERROR 1050)"
  [[ $DRY_RUN == true ]] && return 0
  [[ $RESET_CONFIRMED == true ]] || die "--reset was not confirmed - nothing was dropped."
  if [[ $MODE == single ]] && svc_active zabbix-server; then run systemctl stop zabbix-server; fi
  _xcmd "mysql --protocol=socket --default-character-set=utf8mb4 -uroot -N -B   <<< DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
  printf '%s\n' "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" | mysql_root 2>&1 | _logpipe
  ok "database ${DB_NAME} dropped - it is recreated empty below"
}

# Zabbix 8.0 repository (the /release/ URL) + apt update. Used by step 2.1,
# and by step 1.6 when the database server gets Agent 2.
add_zabbix_repo() {
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
}

# ---- 1.6 Agent 2 on the database server (optional, db mode) ---------------
# Only zabbix-agent2 - never a server or frontend package on this node.
# Server=/ServerActive= point at the app server; Hostname= is AGENT_HOSTNAME.
db_install_agent() {
  step 1.6 "Install Zabbix Agent 2 on the database server (monitored by ${APP_IP})"
  if [[ $INSTALL_AGENT != yes ]]; then
    say "      repository, zabbix-agent2 package, ${ZBX_AGENT_CONF}, service, ufw ${ZBX_AGENT_PORT}/tcp: (skipped: agent not requested)"
    step_skip "agent not requested"
    if [[ $DRY_RUN != true ]] && pkg_installed zabbix-agent2; then info "Agent 2 was already installed; leaving it as it is"; fi
    return 0
  fi
  add_zabbix_repo
  apt_install "sudo apt install zabbix-agent2 -y   # the agent only: no server or frontend packages here" zabbix-agent2
  if [[ $DRY_RUN != true && ! -f $ZBX_AGENT_CONF ]]; then die "${ZBX_AGENT_CONF} is missing - did zabbix-agent2 install?"; fi
  backup_file "$ZBX_AGENT_CONF"
  edit_kv "$ZBX_AGENT_CONF" "" Server "$APP_IP" plain
  edit_kv "$ZBX_AGENT_CONF" "" ServerActive "$APP_IP" plain
  edit_kv "$ZBX_AGENT_CONF" "" Hostname "$AGENT_HOSTNAME" plain
  run systemctl enable zabbix-agent2
  run systemctl restart zabbix-agent2
  _action "\$ systemctl is-active zabbix-agent2; sudo ss -ltn | grep :${ZBX_AGENT_PORT}   # expect active / listening"
  if [[ $DRY_RUN != true ]]; then
    svc_active zabbix-agent2 || die "zabbix-agent2 did not start. Check: sudo journalctl -u zabbix-agent2 -n 50"
    if wait_for_listen "$ZBX_AGENT_PORT" 15; then ok "zabbix-agent2 active, listening on $(listen_addrs "$ZBX_AGENT_PORT")"
    else warn "zabbix-agent2 is active but not listening on ${ZBX_AGENT_PORT} - check ListenPort in ${ZBX_AGENT_CONF}"; fi
  fi
  open_agent_firewall
}

# ufw for the passive checks from the Zabbix server: only from APP_IP, and
# only when ufw is already active (never enabled here).
open_agent_firewall() {
  local st
  # with ENABLE_UFW=yes the rule was added by the ufw step (1.3)
  if [[ $ENABLE_UFW == yes && ${#SSH_PORTS[@]} -gt 0 ]]; then
    _action "\$ sudo ufw allow from ${APP_IP} to any port ${ZBX_AGENT_PORT} proto tcp comment '${UFW_COMMENT}'   # done in step 1.3"
    return 0
  fi
  if [[ $DRY_RUN == true ]]; then
    _action "\$ sudo ufw allow from ${APP_IP} to any port ${ZBX_AGENT_PORT} proto tcp   # only if ufw is active"
    return 0
  fi
  st=$(ufw_state)
  _action "\$ sudo ufw status   # -> ${st}"
  if [[ $st != active ]]; then
    skip "ufw is ${st} - nothing to open (this script never enables ufw)"
    FW_SKIPPED+=("${ZBX_AGENT_PORT}/tcp (ufw ${st})")
  else
    # the app server's IP changed since the last agent run: drop the old rule
    if [[ $ST_MODE == db && $ST_INSTALL_AGENT == yes && -n $ST_APP_IP && $ST_APP_IP != "$APP_IP" ]]; then
      run ufw delete allow from "$ST_APP_IP" to any port "$ZBX_AGENT_PORT" proto tcp || true
    fi
    run ufw allow from "$APP_IP" to any port "$ZBX_AGENT_PORT" proto tcp
    FW_CHANGED+=("allow ${ZBX_AGENT_PORT}/tcp from ${APP_IP}")
  fi
  say "      firewall changed: ${FW_CHANGED[*]:-nothing}   skipped: ${FW_SKIPPED[*]:-nothing}"
}

# =============================================================================
# 8. Part 2 - App & Web server (app mode; single mode runs it locally)
# =============================================================================
part2_app() {
  part "Part 2 - App & Web server"
  local db_host=$DB_IP db_port=$DB_PORT
  # single: socket (DBHost=localhost, no DBPort) or, with a custom port, TCP
  # to 127.0.0.1 so the port is really used (DBHost=127.0.0.1, DBPort=port)
  if [[ $MODE == single ]]; then db_host=$(single_db_host); [[ $SINGLE_CUSTOM_PORT == true ]] || db_port=""; fi

  # ---- 2.1 Repository ----------------------------------------------------------
  step 2.1 "Add the Zabbix ${ZBX_VERSION} repository (Ubuntu ${OS_VER:-$TARGET_UBUNTU})"
  add_zabbix_repo

  # ---- 2.2 Packages --------------------------------------------------------------
  step 2.2 "Install Zabbix packages (agent 2, not the classic agent)"
  local -a pkgs=()
  local p
  for p in "${ZBX_PACKAGES[@]}"; do
    [[ $p == zabbix-agent2 && $INSTALL_AGENT == no ]] || pkgs+=("$p")
  done
  apt_install "sudo apt install ${pkgs[*]} -y" "${pkgs[@]}"
  if [[ $INSTALL_AGENT == no ]]; then
    say "      zabbix-agent2 package: (skipped: agent not requested)"
    if [[ $DRY_RUN != true ]] && pkg_installed zabbix-agent2; then info "Agent 2 was already installed; leaving it as it is"; fi
  fi
  if [[ $MODE == app ]]; then
    apt_install "sudo apt install mysql-client curl -y   # mysql CLI for step 2.3 (the guide assumes it)" mysql-client curl
  else
    apt_install "sudo apt install curl -y   # used by the final HTTP check" curl
  fi
  detect_php_fpm
  detect_schema_file
  [[ $STEP_INSTALLED == true ]] || step_skip "all packages already installed"

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
    _xcmd "apache2ctl configtest"
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
    step_skip "already generated"
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
  [[ $INSTALL_AGENT == no ]] || set_server_agent_hostname
  local -a svcs=()
  mapfile -t svcs < <(app_services)
  run systemctl restart "${svcs[@]}"
  run systemctl enable "${svcs[@]}"
  if [[ $INSTALL_AGENT == no ]]; then say "      zabbix-agent2 service: (skipped: agent not requested)"; fi
  if [[ $DRY_RUN != true ]]; then
    local s
    for s in "${svcs[@]}"; do
      if svc_active "$s"; then ok "${s} active"; else warn "${s} is not active - sudo journalctl -u ${s} -n 50"; fi
    done
    if wait_for_listen "$ZBX_TRAPPER_PORT" 30; then ok "zabbix-server listening on ${ZBX_TRAPPER_PORT}"
    else warn "zabbix-server is not listening on ${ZBX_TRAPPER_PORT} yet - see ${ZBX_SERVER_LOG}"; fi
  fi

  # ---- 2.7a Firewall -------------------------------------------------------------
  if [[ $ENABLE_UFW == yes ]]; then
    step 2.7a "Firewall (ufw): allow the needed ports and enable it"
    setup_ufw open_app_firewall
  else
    step 2.7a "Open the firewall for the web UI (${HTTP_PORT}) and active agent checks (${ZBX_TRAPPER_PORT})"
    open_app_firewall
  fi

  # ---- 2.8 / 2.9 Manual ----------------------------------------------------------
  step 2.8 "Complete the frontend web wizard - manual, values in NEXT STEPS"
  step_skip "manual step"
  step 2.9 "Log into the Zabbix website (Admin / zabbix) - manual, see NEXT STEPS"
  step_skip "manual step"
}

# app/single: zabbix_agent2.conf keeps the package's Hostname=Zabbix server
# (the built-in host). It is only edited when --agent-hostname /
# ZBX_AGENT_HOSTNAME asks for another name than the one already there.
set_server_agent_hostname() {
  local cur=$ZBX_DEFAULT_AGENT_HOST
  if [[ $DRY_RUN != true ]]; then cur=$(kv_get "$ZBX_AGENT_CONF" "" Hostname || true); fi
  [[ -n $AGENT_HOSTNAME && $AGENT_HOSTNAME != "$cur" ]] || return 0
  backup_file "$ZBX_AGENT_CONF"
  edit_kv "$ZBX_AGENT_CONF" "" Hostname "$AGENT_HOSTNAME" plain
  if [[ $AGENT_HOSTNAME != "$ZBX_DEFAULT_AGENT_HOST" ]]; then
    warn "Hostname=${AGENT_HOSTNAME}: rename the built-in '${ZBX_DEFAULT_AGENT_HOST}' host in the web UI to match, or its agent shows as unavailable."
  fi
}

# The services of steps 2.7 and --verify; zabbix-agent2 only when installed
# by choice (INSTALL_AGENT=yes). A "no" never stops or removes an agent.
app_services() {
  printf '%s\n' zabbix-server
  if [[ $INSTALL_AGENT != no ]]; then printf '%s\n' zabbix-agent2; fi
  printf '%s\n' apache2 "$PHP_FPM"
}

# On stop, zabbix-server first flushes its history cache to the database. If
# the database moved (new port/IP on a re-run) that never finishes, and the
# packaged unit has no stop timeout - so allow 60 s, then kill it.
stop_zabbix_server() {
  svc_active zabbix-server || return 0
  info "stopping the running zabbix-server first (it flushes its cache to the DB)"
  _xcmd "timeout 60 systemctl stop zabbix-server"
  if timeout 60 systemctl stop zabbix-server 2>&1 | _logpipe; then return 0; fi
  warn "zabbix-server did not stop within 60 s - its old database is unreachable. Killing it (unsent history is lost)."
  _xcmd "systemctl kill --signal=SIGKILL zabbix-server"
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
  if [[ -n $host && $host != localhost ]]; then
    shown_conn="mysql -h ${host} -P ${port} -u ${DB_USER} -p"
  else
    shown_conn="mysql -u ${DB_USER} -p"
  fi
  make_cnf "$DB_USER" "$DB_PASSWORD"
  set_db_target "$host" "$port"

  _action "\$ ${shown_conn} ${DB_NAME} -e 'SELECT VERSION();'   # test the connection first"
  if [[ $DRY_RUN != true ]]; then
    _xcmd "mysql --defaults-extra-file=${CNF} --default-character-set=utf8mb4 --connect-timeout=5 ${DBC_ARGS[*]} -N -B ${DB_NAME} -e 'SELECT VERSION()'"
    out=$(mysql_zbx "$DB_NAME" -e "SELECT VERSION()" 2>&1) || die "Cannot log in to ${DB_NAME} as ${DB_USER}: $(explain_mysql_error "$out")"
    ok "connected - MySQL ${out}"
    state=$(schema_state mysql_zbx)
  else
    state=none
  fi

  _action "\$ zcat ${SCHEMA_FILE} | ${shown_conn} --default-character-set=utf8mb4 ${DB_NAME}   # 1-2 minutes"
  case $state in
    full)
      skip "schema already imported (dbversion and users tables present)"
      step_skip "already imported" ;;
    partial)
      die "The database '${DB_NAME}' holds a PARTIAL schema - importing again would stop with ERROR 1050 (table already exists)." \
          "Recreate it on the DB node:  sudo ${LAUNCH} --mode $([[ $MODE == app ]] && echo db || echo single) --reset" ;;
    *)
      if [[ $DRY_RUN != true ]]; then
        flags=$(mysql_zbx -e "SELECT CONCAT(@@GLOBAL.log_bin, ' ', @@GLOBAL.log_bin_trust_function_creators)" 2>/dev/null || echo "")
        if [[ $flags == "1 0" ]]; then
          die "log_bin_trust_function_creators is 0 on the DB server - the import would fail (ERROR 1419)." \
              "On the DB node run:  sudo mysql -e 'SET GLOBAL log_bin_trust_function_creators = 1;'  (or re-run --mode db), then re-run this."
        fi
        info "importing ${SCHEMA_FILE} - this takes 1-2 minutes..."
        errf=$(mktemp); TMP_PATHS+=("$errf")
        _xcmd "zcat ${SCHEMA_FILE} | mysql --defaults-extra-file=${CNF} --default-character-set=utf8mb4 --connect-timeout=5 ${DBC_ARGS[*]} -N -B --default-character-set=utf8mb4 ${DB_NAME}"
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
      warn "  or re-run  sudo ${LAUNCH} --mode db --yes  (it sees the imported schema and sets 0)."
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
    step_skip "ufw is ${st}"
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
# The hand-off is a valid env file (ZBX_ names), so on the app server:
#   sudo ./zabbix-setup.sh --mode app --env-file ./zabbix-handoff.txt
# --db-password-file still accepts it as well.
render_handoff() {   # render_handoff PASSWORD_OR_MASK
  local pwline="ZBX_DB_PASSWORD='$1'"
  [[ -z $1 ]] && pwline="# ZBX_DB_PASSWORD unchanged (kept on a re-run) - use the value from the first run"
  # shown on screen masked: the real value is in the file and the REMEMBER block
  [[ $1 == "$MASK" ]] && pwline+=$'\n'"#   (masked here - the real password is in ${HANDOFF_FILE##*/} and in the REMEMBER block at the end)"
  cat <<EOF
# ###########################################################################
#  zabbix-setup hand-off - values for the APP server  ($(date '+%F %T'))
#  This file is an env file: load it with --env-file. Keep it chmod 600.
# ###########################################################################
ZBX_MODE='app'
ZBX_APP_IP='${APP_IP}'
ZBX_DB_IP='${DB_IP}'
ZBX_DB_PORT='${DB_PORT}'
ZBX_DB_NAME='${DB_NAME}'
ZBX_DB_USER='${DB_USER}'
${pwline}
ZBX_TIMEZONE='${TIMEZONE}'
#
# Next, on the APP server (${APP_IP}), with this same script:
#   1. copy this file over securely, e.g.  scp zabbix-handoff.txt <user>@${APP_IP}:
#   2. sudo ${LAUNCH} --mode app --env-file ./zabbix-handoff.txt
#   Without the file it prompts for the password:
#      sudo ${LAUNCH} --mode app --app-ip ${APP_IP} --db-ip ${DB_IP} --db-port ${DB_PORT}
#   Delete this file on both servers once the app server is done.
#
# When the app server has imported the schema, come back to THIS server and run:
#   sudo ${LAUNCH} --mode db --yes
#   (it detects the schema and sets log_bin_trust_function_creators back to 0)
EOF
  # Agent 2 on this database server: comment lines only, so loading this file
  # with --env-file on the app server never sets its own agent host name.
  if [[ $INSTALL_AGENT == yes ]]; then
    cat <<EOF
#
# ZBX_AGENT_HOSTNAME='${AGENT_HOSTNAME}'   (this DB server's agent - reference only)
#
# Add this server in the Zabbix web UI  (Data collection > Hosts > Create host):
#   Host name    ${AGENT_HOSTNAME}   (identical to Hostname= in ${ZBX_AGENT_CONF})
#   Host groups  Linux servers
#   Interfaces   Add > Agent: IP ${DB_IP}, port ${ZBX_AGENT_PORT}
#   Templates    Linux by Zabbix agent
EOF
  else
    printf '#\n# Agent 2 on this database server: not installed (by choice).\n'
  fi
  printf '# ###########################################################################\n'
}

# zabbix-setup.env: every setting of this run, as an env file (section E).
# The static IP keys are only written when this run configured one, so a
# re-run with the file never reconfigures the network by surprise; single
# mode on the socket has no ZBX_DB_PORT (a port would mean "custom port").
_env_kv() { if [[ -n $2 ]]; then printf "ZBX_%s='%s'\n" "$1" "$2"; fi; return 0; }
render_env() {   # render_env PASSWORD_OR_MASK
  local pw=$1
  printf '# zabbix-setup.sh %s - settings of the %s run on %s (%s)\n' "$SCRIPT_VERSION" "$MODE" "${APP_IP:-?}" "$(date '+%F %T')"
  printf '# Load with:  sudo %s --env-file ./zabbix-setup.env  (it is also read automatically\n' "$LAUNCH"
  printf '# from the current directory). Parsed, never sourced: values are literal.\n'
  printf '# It holds the database password: keep it chmod 600 and out of git.\n'
  _env_kv MODE "$MODE"
  _env_kv APP_IP "$APP_IP"
  [[ $MODE == app || $MODE == db ]] && _env_kv DB_IP "$DB_IP"
  if [[ $MODE == single && $SINGLE_CUSTOM_PORT != true ]]; then
    printf '# ZBX_DB_PORT not set: MySQL through the local socket (wizard port 0)\n'
  else
    _env_kv DB_PORT "$DB_PORT"
  fi
  _env_kv DB_NAME "$DB_NAME"
  _env_kv DB_USER "$DB_USER"
  _env_kv TIMEZONE "$TIMEZONE"
  _env_kv INSTALL_AGENT "$INSTALL_AGENT"
  _env_kv ENABLE_UFW "$ENABLE_UFW"
  _env_kv SSH_PORT "$SSH_PORT"
  _env_kv VERBOSE "$VERBOSE"
  [[ $INSTALL_AGENT == yes ]] && _env_kv AGENT_HOSTNAME "$AGENT_HOSTNAME"
  _env_kv WIN_HOSTNAME "$WIN_HOSTNAME"
  _env_kv WIN_IP "$WIN_IP"
  if [[ $NET_ACTION == configure ]]; then
    _env_kv IFACE "$IFACE"; _env_kv STATIC_IP "$STATIC_IP"; _env_kv PREFIX "$PREFIX"
    _env_kv GATEWAY "$GATEWAY"; _env_kv DNS "$DNS"
  else
    printf '# static IP: %s in this run - ZBX_STATIC_IP not set\n' "${NET_ACTION:-skip}"
  fi
  _env_kv SSH_KEY_FILE "$SSH_KEY_FILE"
  if [[ $NO_ENV_PASSWORD == true ]]; then
    printf '# ZBX_DB_PASSWORD left out (--no-env-password)\n'
  elif [[ -z $pw ]]; then
    printf '# ZBX_DB_PASSWORD unknown (kept on a re-run without an earlier hand-off)\n'
  else
    _env_kv DB_PASSWORD "$pw"
  fi
}
write_env_file() {
  if [[ -e $DEFAULT_ENV_FILE ]]; then write_private "${DEFAULT_ENV_FILE}.bak" <"$DEFAULT_ENV_FILE"; fi
  render_env "$DB_PASSWORD" | write_private "$DEFAULT_ENV_FILE"
  info "settings saved to ${DEFAULT_ENV_FILE} (chmod 600$([[ $NO_ENV_PASSWORD == true ]] && echo ', no password' || echo ', includes the DB password'))"
  [[ -e ${DEFAULT_ENV_FILE}.bak ]] && info "previous version kept as ${DEFAULT_ENV_FILE}.bak (chmod 600)"
  return 0
}

# If the output directory is inside a git repository, warn (never edit
# .gitignore): the generated files hold the DB password.
git_warning() {   # git_warning FILE...
  local d=$OUT_DIR top="" f
  local -a exposed=()
  while true; do
    if [[ -e ${d}/.git ]]; then top=$d; break; fi
    [[ $d == / || -z $d ]] && break
    d=${d%/*}; d=${d:-/}
  done
  [[ -n $top ]] || return 0
  for f in "$@"; do
    if command -v git >/dev/null 2>&1 && git -c safe.directory="$top" -C "$OUT_DIR" check-ignore -q -- "$f" 2>/dev/null; then continue; fi
    exposed+=("${f##*/}")
  done
  if ((${#exposed[@]} == 0)); then
    info "git: ${OUT_DIR} is inside the repository ${top}; the generated files are git-ignored."
  else
    warn "${OUT_DIR} is inside a git repository (${top}). ${exposed[*]} contain(s) the DB password and is/are NOT ignored."
    warn "Add them to .gitignore (e.g. zabbix-setup.env*, zabbix-handoff.txt, zabbix-next-steps.txt) - this script does not edit .gitignore."
  fi
  return 0
}

# (the password is no longer part of this block: it is printed once, in the
# REMEMBER block - render_wizard - which follows it in zabbix-next-steps.txt)
render_next_steps() {   # render_next_steps [PASSWORD_OR_MASK - not used]
  local host port wh=${WIN_HOSTNAME:-<WIN_HOSTNAME>} wi=${WIN_IP:-<WIN_IP>}
  wizard_db_target; host=$WZ_HOST; port=$WZ_PORT
  cat <<EOF
###########################################################################
#  NEXT STEPS (manual)  - ${MODE} setup on ${APP_IP}, $(date '+%F %T')
###########################################################################
EOF
  if [[ $TRUST_PENDING == true ]]; then
    cat <<EOF

0. FIRST, on the DB server ${DB_IP} (finishes guide Part 2 step 3):
     sudo mysql -e 'SET GLOBAL log_bin_trust_function_creators = 0;'
   or: sudo ${LAUNCH} --mode db --yes
EOF
  fi
  cat <<EOF

1. Web setup wizard  (guide Part 2, steps 8-9)
   Open      http://${APP_IP}/zabbix
   Database values (host ${host}, port ${port}), the password and the
   Admin login: see "REMEMBER: ZABBIX WEB WIZARD" at the end.
EOF
  if [[ $INSTALL_AGENT == no ]]; then
    cat <<EOF
   Note: the built-in 'Zabbix server' host will show its agent as unavailable, because no agent is installed on this server. Disable that host, or ignore it.
EOF
  fi
  cat <<EOF

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
   On this server, any time:  sudo ${LAUNCH} --verify

Settings of this run: ${DEFAULT_ENV_FILE}
   (ZBX_* env file, read again automatically from this directory; it holds
   the DB password unless --no-env-password: chmod 600, keep it out of git)
###########################################################################
EOF
}

# Show a block with the real password on the terminal only, save it (600),
# and record only the masked version in the log.
# What the Zabbix web wizard needs as "Database host" / "Database port" in
# this scenario -> WZ_HOST WZ_PORT WZ_PORT_NOTE
wizard_db_target() {
  case $MODE in
    db|app) WZ_HOST=$DB_IP; WZ_PORT=$DB_PORT; WZ_PORT_NOTE="type it explicitly - 0 means 3306 and the test would fail" ;;
    *)
      if [[ $SINGLE_CUSTOM_PORT == true ]]; then
        WZ_HOST=127.0.0.1; WZ_PORT=$DB_PORT; WZ_PORT_NOTE="custom port: TCP to 127.0.0.1, not localhost (= socket)"
      else
        WZ_HOST=localhost; WZ_PORT=0; WZ_PORT_NOTE="0 = default (local socket)"
      fi ;;
  esac
}

# render_wizard PASSWORD_OR_MASK - the last block of every real run, and the
# end of zabbix-next-steps.txt / zabbix-handoff.txt: the values the web
# wizard asks for. The DB password appears here and nowhere else on screen.
render_wizard() {
  local pw=$1 head name name_line bar="+=========================================================================+"
  [[ -z $pw ]] && pw="<unchanged - the password from the first run>"
  wizard_db_target
  head="DATABASE HOST = THE HOSTNAME/IP OF THE DATABASE SERVER. NOT LOCALHOST, NOT THE ZABBIX SERVER."
  case $MODE in
    db)
      name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
      name_line="(this database server's name is ${name:-?} - the name only works if the web server can resolve it (DNS or /etc/hosts), otherwise use the IP)" ;;
    app)
      # type the IP; the name is only a second line, and only when the
      # reverse lookup resolves forward to the same IP again
      name=$(getent hosts "$DB_IP" 2>/dev/null | awk '{print $2; exit}' || true)
      # (the FIRST address the name resolves to - the one a client would use)
      if [[ -n $name && $(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}' || true) == "$DB_IP" ]]; then
        name_line="name (works only if this web server can resolve it): ${name}"
      else
        name_line=""
      fi ;;
    *)
      head="DATABASE HOST: ON A SINGLE VM THE DATABASE IS ON THIS SERVER - TYPE ${WZ_HOST^^} EXACTLY, NOT THE HOST NAME OR THE IP."
      name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
      name_line="(this server is ${name:-?}, but do not type that name here: ${WZ_HOST} is what MySQL accepts in this setup)" ;;
  esac
  cat <<EOF
${bar}
|  REMEMBER: ZABBIX WEB WIZARD    http://${APP_IP}/zabbix
${bar}
|  ${head}
|
|  Database type   MySQL
|  Database host   ${WZ_HOST}
EOF
  if [[ -n $name_line ]]; then printf '|                  %s\n' "$name_line"; fi
  cat <<EOF
|  Database port   ${WZ_PORT}      (${WZ_PORT_NOTE})
|  Database name   ${DB_NAME}
|  User            ${DB_USER}
|  Password        ${pw}
|  Time zone       ${TIMEZONE}
|
|  After the wizard, log in to the Zabbix website with Admin / zabbix, and
|  change that password immediately (Users > Admin).
|  Admin / zabbix is the Zabbix web login - a DIFFERENT account from the
|  database user '${DB_USER}' above.
EOF
  if [[ $MODE == db ]]; then
    printf '|\n|  Next: run the script on the APP server, then open http://%s/zabbix\n' "$APP_IP"
  fi
  printf '%s\n' "$bar"
}

# emit_secret_block RENDER_FN FILE - the hand-off (db) or NEXT STEPS block on
# the terminal and in the log WITHOUT the password; the 600 file gets the
# real one plus the REMEMBER block (commented out in the hand-off, so it is
# still a valid env file). The password itself is printed once, at the very
# end, by emit_wizard.
emit_secret_block() {   # emit_secret_block RENDER_FN FILE
  local fn=$1 file=$2 pw=$DB_PASSWORD line pre=""
  if [[ $DRY_RUN == true ]]; then
    while IFS= read -r line; do say "$line"; done < <("$fn" "$MASK")
    return 0
  fi
  [[ $fn == render_handoff ]] && pre="# "
  say ""
  while IFS= read -r line; do say "$line"; done < <("$fn" "$MASK")
  {
    "$fn" "$pw"
    printf '%s\n' "${pre% }"
    while IFS= read -r line; do printf '%s%s\n' "$pre" "$line"; done < <(render_wizard "$pw")
  } | write_private "$file"
  say ""
  say "Saved to ${file} (chmod 600) - with the password and the wizard values; the password is printed once, at the very end."
}
# emit_wizard FILE - the very last thing a real run prints: the REMEMBER block
# with the real password (terminal only); the log gets the masked version.
emit_wizard() {
  local line
  if [[ $DRY_RUN == true ]]; then
    while IFS= read -r line; do say "$line"; done < <(render_wizard "$MASK")
    return 0
  fi
  printf '\n'
  render_wizard "$DB_PASSWORD"
  if [[ $LOG_ON == true ]]; then
    while IFS= read -r line; do _record "$line"; done < <(render_wizard "$MASK")
  fi
  printf '%s\n' "The password above is shown only here and in ${1} (chmod 600) - never in ${LOG_FILE}."
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
# vc_ufw PORT [FROM_IP] [LABEL] - is there an ALLOW rule for PORT (from FROM_IP)?
# ENABLE_UFW=yes: ufw must be on, so a missing rule is a FAIL even while
# ufw is off (the rules ufw holds are checked then); no: as before (nothing
# to check while ufw is off).
vc_ufw() {
  local port=$1 from=${2:-} label=${3:+ (${3})} st out line found="" broad="" re c="" name
  st=$(ufw_state)
  [[ $UFW_EXPECTED == yes ]] && c=" comment '${UFW_COMMENT}'"
  name="ufw allows ${port}/tcp${from:+ from ${from}}${label}"
  local fix="sudo ufw allow ${port}/tcp${c}"
  [[ -n $from ]] && fix="sudo ufw allow from ${from} to any port ${port} proto tcp${c}"
  if [[ $st != active ]]; then
    if [[ $UFW_EXPECTED != yes ]]; then vrow PASS "$name" "ufw ${st} - nothing to check"; return 0; fi
    while IFS= read -r line; do
      if [[ $line == "allow ${port}/tcp"* || ( $line == *" port ${port} proto tcp"* && ( -z $from || $line == *"from ${from} "* ) ) ]]; then found=$line; fi
    done < <(ufw_added_rules)
    if [[ -n $found ]]; then vrow PASS "$name" "rule added (applies once ufw is on)"
    else vrow FAIL "$name" "no rule" "$fix"; fi
    return 0
  fi
  out=$(ufw status 2>/dev/null || true)
  re="^${port}(/tcp)?[[:space:]]+ALLOW"
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    if [[ -z $from || $line == *"$from"* ]]; then found=$line; fi
    if [[ $line == *Anywhere* ]]; then broad=$line; fi
  done <<<"$out"
  if [[ -n $from && -z $found && -n $broad ]]; then vrow WARN "$name" "open to Anywhere" "scope it: ${fix}"
  elif [[ -n $found ]]; then vrow PASS "$name" "rule present"
  else vrow FAIL "$name" "no rule" "$fix"; fi
}
# ufw on, and the SSH rule - when the script enables ufw (ENABLE_UFW=yes)
UFW_EXPECTED=no   # vc_ufw: must ufw be on? (set by vc_ufw_base)
vc_ufw_base() {
  local st p
  UFW_EXPECTED=$ENABLE_UFW
  if [[ $ENABLE_UFW != yes ]]; then
    vrow SKIP "ufw enabled by the script" "skipped by choice (--no-ufw / ZBX_ENABLE_UFW=no)"
    return 0
  fi
  st=$(ufw_state)
  detect_ssh_ports
  if [[ $st != active ]] && ((${#SSH_PORTS[@]} == 0)); then
    # the ufw step refused to enable it (no SSH port): not a failure
    UFW_EXPECTED=no
    vrow WARN "ufw active" "${st} - not enabled: no SSH port detected" "to enable it: re-run with --ssh-port N (the SSH port you connect with)"
    return 0
  fi
  if [[ $st == active ]]; then vrow PASS "ufw active" "default: $(ufw status verbose 2>/dev/null | sed -n 's/^Default: //p')"
  else vrow FAIL "ufw active" "$st" "re-run the script (it adds the SSH rule first), or: sudo ufw --force enable once the SSH rule is there"; fi
  [[ $st == absent ]] && return 0
  if ((${#SSH_PORTS[@]} == 0)); then
    vrow WARN "ufw allows SSH" "no SSH port detected" "sudo ufw allow <your SSH port>/tcp comment '${UFW_COMMENT}'"
    return 0
  fi
  for p in "${SSH_PORTS[@]}"; do vc_ufw "$p" "" "SSH"; done
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
          else vrow FAIL "database ${DB_NAME} has the schema" "exists, empty" "re-run: sudo ${LAUNCH} --mode single"; fi ;;
    partial) vrow FAIL "database ${DB_NAME} has the schema" "partial import" "sudo ${LAUNCH} --mode ${MODE} --reset, then import again" ;;
    *) vrow FAIL "database ${DB_NAME} exists" "missing" "re-run: sudo ${LAUNCH} --mode ${MODE}" ;;
  esac
  n=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='${host}'" 2>/dev/null || echo 0)
  if [[ $n == 1 ]]; then vrow PASS "user '${DB_USER}'@'${host}' exists" ""
  else vrow FAIL "user '${DB_USER}'@'${host}' exists" "missing" "re-run: sudo ${LAUNCH} --mode ${MODE}"; fi
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
  vc_ufw_base
  vc_ufw "$DB_PORT" "$APP_IP"
  remote=$(mysql_root -e "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE host NOT IN ('localhost','127.0.0.1','::1') ORDER BY 1" 2>/dev/null || echo "?")
  local a
  for a in $remote; do [[ $a == "${DB_USER}@${APP_IP}" ]] || extra+="${a} "; done
  if [[ $remote == "${DB_USER}@${APP_IP}" ]]; then vrow PASS "only remote account is ${DB_USER}@${APP_IP}" ""
  elif [[ -n $extra ]]; then vrow FAIL "only remote account is ${DB_USER}@${APP_IP}" "also: ${extra% }" "remove unused ones: sudo mysql -e \"DROP USER 'name'@'host';\""
  else vrow FAIL "only remote account is ${DB_USER}@${APP_IP}" "none found" "re-run: sudo ${LAUNCH} --mode db"; fi
  vc_db_agent
  vc_chrony
}

# Agent 2 on the database server (step 1.6), only when it was requested
vc_db_agent() {
  local srv hn
  if [[ $INSTALL_AGENT != yes ]]; then
    vrow SKIP "Zabbix Agent 2 on this server" "skipped (not installed by choice)"
    return 0
  fi
  vc_service zabbix-agent2
  vc_listen "$ZBX_AGENT_PORT" "zabbix-agent2" "sudo systemctl restart zabbix-agent2; check ListenPort in ${ZBX_AGENT_CONF}"
  srv=$(kv_get "$ZBX_AGENT_CONF" "" Server || true)
  hn=$(kv_get "$ZBX_AGENT_CONF" "" Hostname || true)
  if [[ ",${srv// /}," == *",${APP_IP},"* ]]; then vrow PASS "zabbix_agent2.conf Server=${APP_IP}" "Server=${srv}"
  else vrow FAIL "zabbix_agent2.conf Server=${APP_IP}" "Server=${srv:-<not set>}" "set Server=${APP_IP} in ${ZBX_AGENT_CONF}; sudo systemctl restart zabbix-agent2"; fi
  if [[ -n $AGENT_HOSTNAME && $hn == "$AGENT_HOSTNAME" ]]; then vrow PASS "zabbix_agent2.conf Hostname=${AGENT_HOSTNAME}" ""
  else vrow FAIL "zabbix_agent2.conf Hostname=${AGENT_HOSTNAME:-?}" "Hostname=${hn:-<not set>}" "re-run: sudo ${LAUNCH} --mode db --agent-hostname <name>"; fi
  vc_ufw "$ZBX_AGENT_PORT" "$APP_IP"
}

verify_app() {
  local s h p n u pw out m code recent errs
  while IFS= read -r s; do vc_service "$s"; done < <(app_services)
  if [[ $INSTALL_AGENT == no ]]; then vrow SKIP "service zabbix-agent2 active" "skipped (not installed by choice)"; fi
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
    # an outage that zabbix-server already recovered from (e.g. MySQL was
    # restarted) is a WARN, not a FAIL: look after the last reconnect line
    local after_ok
    after_ok=$(awk '/database connection re-established/ {buf=""; seen=1; next} {buf = buf $0 ORS} END {if (seen) printf "%s", buf}' <<<"$recent") || after_ok=""
    if [[ -z $errs ]]; then vrow PASS "no DB errors in zabbix_server.log" "since last start"
    elif [[ $recent == *"database connection re-established"* ]] && ! grep -Eqi 'database is down|connection to database .* failed|\[Z300[0-9]\]' <<<"$after_ok"; then
      vrow WARN "no DB errors in zabbix_server.log" "a DB outage since last start, recovered (database connection re-established)"
    else vrow FAIL "no DB errors in zabbix_server.log" "${errs%%$'\n'*}" "fix the DB* settings / reachability, then sudo systemctl restart zabbix-server"; fi
  else
    vrow WARN "no DB errors in zabbix_server.log" "${ZBX_SERVER_LOG} not found"
  fi
  code=$(http_code "http://localhost/zabbix")
  if [[ $code == 200 || $code == 206 ]]; then vrow PASS "frontend http://localhost/zabbix" "HTTP ${code}"
  else vrow FAIL "frontend http://localhost/zabbix" "HTTP ${code}" "sudo apache2ctl configtest; sudo systemctl restart apache2 ${PHP_FPM}; tail /var/log/apache2/error.log"; fi
  vc_ufw_base
  vc_ufw "$HTTP_PORT"
  vc_ufw "$ZBX_TRAPPER_PORT"
}

# Custom port in single mode: zabbix-server must really talk TCP to
# 127.0.0.1:PORT (not the socket) - look for its established connections.
vc_zbx_tcp() {
  local port=$1 out line n=0
  out=$(ss -tnpH state established "dport = :${port}" 2>/dev/null || true)
  while IFS= read -r line; do
    [[ $line == *"127.0.0.1:${port}"* && $line == *zabbix_server* ]] && n=$((n + 1))
  done <<<"$out"
  if ((n > 0)); then vrow PASS "zabbix-server -> 127.0.0.1:${port} over TCP" "${n} established (ss -tnp)"
  else vrow FAIL "zabbix-server -> 127.0.0.1:${port} over TCP" "no established connection (ss -tnp)" "DBHost=127.0.0.1 and DBPort=${port} in ${ZBX_SERVER_CONF}, then sudo systemctl restart zabbix-server"; fi
}

verify_single() {
  local n
  vc_mysql_local localhost || true
  if [[ -n $DB_PORT && $DB_PORT != 0 ]]; then
    n=$(mysql_root -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='127.0.0.1'" 2>/dev/null || echo 0)
    if [[ $n == 1 ]]; then vrow PASS "user '${DB_USER}'@'127.0.0.1' exists" "custom port: TCP login"
    else vrow FAIL "user '${DB_USER}'@'127.0.0.1' exists" "missing" "re-run: sudo ${LAUNCH} --mode single --db-port ${DB_PORT}"; fi
    vc_listen "$DB_PORT" "MySQL" "set port = ${DB_PORT} in ${MYSQLD_CNF}; sudo systemctl restart mysql"
    vc_zbx_tcp "$DB_PORT"
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
      if [[ $MODE == single && ${DB_PORT:-0} == 0 ]]; then say "  (Zabbix connects through the local socket - wizard port 0)"
      elif [[ $MODE == single ]]; then say "  (Zabbix connects over TCP to 127.0.0.1:${DB_PORT})"; fi ;;
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
  # agent choice: flag/env/env file, else the state file; older state = yes
  if [[ -n $INSTALL_AGENT ]] && ! v_yesno "$INSTALL_AGENT"; then die "INSTALL_AGENT='${INSTALL_AGENT}' from ${SRC[INSTALL_AGENT]:-?}: ${VERR}"; fi
  # (db servers set up before 1.2.0 never had an agent: no recorded choice = no)
  if [[ $MODE == db ]]; then INSTALL_AGENT=${INSTALL_AGENT:-${ST_INSTALL_AGENT:-no}}
  else INSTALL_AGENT=${INSTALL_AGENT:-${ST_INSTALL_AGENT:-yes}}; fi
  INSTALL_AGENT=${INSTALL_AGENT,,}
  # ufw choice: flag/env/env file, else the state file; older state = no
  if [[ -n $ENABLE_UFW ]] && ! v_yesno "$ENABLE_UFW"; then die "ENABLE_UFW='${ENABLE_UFW}' from ${SRC[ENABLE_UFW]:-?}: ${VERR}"; fi
  ENABLE_UFW=${ENABLE_UFW:-${ST_ENABLE_UFW:-no}}; ENABLE_UFW=${ENABLE_UFW,,}
  [[ -n $SSH_PORT ]] || SSH_PORT=$ST_SSH_PORT   # --ssh-port of the last run (no SSH detected)
  if [[ -n $AGENT_HOSTNAME ]] && ! v_agent_host "$AGENT_HOSTNAME"; then die "AGENT_HOSTNAME='${AGENT_HOSTNAME}': ${VERR}"; fi
  [[ -n $AGENT_HOSTNAME ]] || AGENT_HOSTNAME=${ST_AGENT_HOSTNAME:-$(kv_get "$ZBX_AGENT_CONF" "" Hostname || true)}
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
  [[ $EUID -eq 0 ]] || die "Run as root:  sudo ${LAUNCH} ${ARGS_TEXT}" "(--dry-run works without root)"
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
  say "Output files (hand-off, env file, next steps, manual steps) go to: ${OUT_DIR}"
  if [[ $PW_ENV_DEPRECATED == true ]]; then warn "DB_PASSWORD is deprecated - use ZBX_DB_PASSWORD (same meaning)."; fi
  pick_env_file                               # flag > env var > env file > prompt

  # --verify ------------------------------------------------------------------
  if [[ $DO_VERIFY == true ]]; then
    [[ $DRY_RUN == true ]] && die "--verify and --dry-run do not combine."
    resolve_verify_settings
    local rc=0
    run_verify || rc=$?
    exit "$rc"
  fi

  # whiptail dialogs on a terminal; plain text prompts otherwise
  if [[ $NO_DIALOG != true && $ASSUME_YES != true ]] && dialog_possible; then USE_DIALOG=true; fi

  # --add-user on its own ---------------------------------------------------------
  if [[ -n $ADD_USER && -z $MODE ]]; then
    ui_init                                   # (no verbose question here: --verbose or ZBX_VERBOSE)
    part "Part 0 - Preparation"
    STEP_TOTAL=1
    add_admin_user
    steps_summary
    exit 0
  fi

  load_state
  choose_mode
  if [[ $DRY_RUN == true ]]; then
    say "Scenario: ${MODE}. Every command below is numbered with the guide's Part.Step."
    say "Saved to: ${MANUAL_FILE} (password masked)."
  fi
  collect_inputs
  ui_init                                     # one line per step / verbose / plain
  build_summary
  if [[ $DRY_RUN != true && $ASSUME_YES != true ]]; then
    if [[ $USE_DIALOG == true ]]; then
      confirm_summary || { end_dialogs; die "Stopped - nothing was changed."; }
      end_dialogs; show_summary
    else
      show_summary
      confirm_summary || die "Stopped - nothing was changed."
    fi
  else
    end_dialogs; show_summary
  fi

  count_steps                                 # for the (n/total) counter
  preflight                                   # 0.1
  [[ -n $ADD_USER ]] && add_admin_user        # 0.2
  apply_static_ip                             # 0.3
  setup_time                                  # 0.4

  case $MODE in
    db)     part1_database ;;
    app)    part2_app ;;
    single) part1_database; part2_app ;;
  esac
  steps_summary                               # real runs: every step + total time

  if [[ $MODE != db ]]; then part "Part 3 - Windows 11 agent (manual - see NEXT STEPS)"; fi

  if [[ $DRY_RUN == true ]]; then
    part "Final blocks this run would print (password masked)"
    if [[ $MODE == db ]]; then emit_secret_block render_handoff "$HANDOFF_FILE"
    else emit_secret_block render_next_steps "$NEXT_STEPS_FILE"; fi
    say ""
    say "A real run would also write ${DEFAULT_ENV_FILE} (chmod 600; not written now):"
    local line
    while IFS= read -r line; do say "    ${line}"; done < <(render_env "$MASK")
    git_warning "$DEFAULT_ENV_FILE"
    say ""
    if [[ $MODE == db ]]; then emit_wizard "$HANDOFF_FILE"; else emit_wizard "$NEXT_STEPS_FILE"; fi
    say ""
    say "DRY RUN complete - nothing was changed. Steps saved to ${MANUAL_FILE}"
    exit 0
  fi

  write_state
  write_env_file
  local vrc=0
  run_verify || vrc=$?
  say ""
  say "  Backups of edited files: ${BACKUP_DIR}$([[ -d $BACKUP_DIR ]] || echo ' (none needed)')"
  say "  Log: ${LOG_FILE}"
  if [[ $INSTALL_AGENT == yes ]]; then say "  Agent 2 on this server: yes (Hostname=${AGENT_HOSTNAME})"
  else say "  Agent 2 on this server: no"; fi
  if [[ $MODE == db ]]; then
    emit_secret_block render_handoff "$HANDOFF_FILE"
    git_warning "$DEFAULT_ENV_FILE" "$HANDOFF_FILE"
  else
    emit_secret_block render_next_steps "$NEXT_STEPS_FILE"
    git_warning "$DEFAULT_ENV_FILE" "$NEXT_STEPS_FILE"
  fi
  if ((vrc != 0)); then
    err "Setup finished but verification reported FAIL - see the fixes in the table above."
  fi
  # the very last block: what the web wizard needs (the password, once)
  if [[ $MODE == db ]]; then emit_wizard "$HANDOFF_FILE"; else emit_wizard "$NEXT_STEPS_FILE"; fi
  if ((vrc != 0)); then exit 1; fi
}

# Run main when executed as a file, as the one-liner  bash <(curl -fsSL URL)
# (BASH_SOURCE and $0 are the same /dev/fd/N), or as  bash -c "$(cat FILE)" _
# (no file: BASH_SOURCE is empty). When the file is sourced, define only.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
