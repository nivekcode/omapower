# OmaPower Bash and Foot caret integration.
# It reports only cursor row/column and terminal rows/columns. Command text and
# typed characters never leave Bash.

[[ $- == *i* ]] || return 0
[[ ${OMAPOWER_BASH_INTEGRATION_LOADED:-0} == 2 ]] && return 0
export OMAPOWER_BASH_INTEGRATION_LOADED=2

_OMAPOWER_SOCKET=${XDG_RUNTIME_DIR:-/run/user/$UID}/omapower.sock
_OMAPOWER_ROWS=${LINES:-1}
_OMAPOWER_COLUMNS=${COLUMNS:-1}
_OMAPOWER_FD=

exec {_OMAPOWER_TTY_FD}<>/dev/tty || return 0

_omapower_connect() {
  if [[ ${_OMAPOWER_FD:-} =~ ^[0-9]+$ ]]; then
    exec {_OMAPOWER_FD}>&-
  fi
  [[ -S $_OMAPOWER_SOCKET ]] || { _OMAPOWER_FD=; return 1; }
  exec {_OMAPOWER_FD}> >(exec socat -u - "UNIX-CONNECT:$_OMAPOWER_SOCKET" 2>/dev/null)
}

_omapower_send() {
  local message=$1
  if [[ ! ${_OMAPOWER_FD:-} =~ ^[0-9]+$ ]] || ! printf '%s\n' "$message" >&"$_OMAPOWER_FD" 2>/dev/null; then
    _omapower_connect || return 0
    printf '%s\n' "$message" >&"$_OMAPOWER_FD" 2>/dev/null || true
  fi
}

_omapower_report_caret() {
  IFS=' ' read -r _OMAPOWER_ROWS _OMAPOWER_COLUMNS < <(stty size < /dev/tty 2>/dev/null) || true
  [[ $_OMAPOWER_ROWS =~ ^[0-9]+$ && $_OMAPOWER_COLUMNS =~ ^[0-9]+$ ]] || {
    _OMAPOWER_ROWS=${LINES:-1}
    _OMAPOWER_COLUMNS=${COLUMNS:-1}
  }
}

_omapower_after_insert() {
  local row column
  printf '\e[6n' >&"$_OMAPOWER_TTY_FD"
  IFS=';' read -r -s -d R -t 0.04 row column <&"$_OMAPOWER_TTY_FD" || return 0
  row=${row##*$'\e['}
  [[ $row =~ ^[0-9]+$ && $column =~ ^[0-9]+$ ]] || return 0
  _omapower_send "type $row $column $_OMAPOWER_ROWS $_OMAPOWER_COLUMNS"
}

if [[ ";${PROMPT_COMMAND[*]};" != *';_omapower_report_caret;'* ]]; then
  if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
    PROMPT_COMMAND+=( _omapower_report_caret )
  else
    PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_omapower_report_caret"
  fi
fi

_omapower_connect || true

# A macro uses Readline's own quoted-insert, then runs our callback. This keeps
# normal editing and undo behavior while giving the callback the physical cell
# where Foot is about to draw the new character.
for ((_omapower_code = 32; _omapower_code <= 126; _omapower_code++)); do
  printf -v _omapower_binding '"\\x%02x":"\\C-v\\x%02x\\e[99~"' "$_omapower_code" "$_omapower_code"
  bind -m emacs-standard "$_omapower_binding"
  bind -m vi-insert "$_omapower_binding"
done
bind -m emacs-standard -x '"\e[99~":_omapower_after_insert'
bind -m vi-insert -x '"\e[99~":_omapower_after_insert'
unset _omapower_code _omapower_binding
