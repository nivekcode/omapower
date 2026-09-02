# OmaPower Bash and Foot caret integration.
# It reports only cursor/grid geometry. Command text and typed characters never
# leave Bash.

[[ $- == *i* ]] || return 0
[[ ${OMAPOWER_BASH_INTEGRATION_LOADED:-0} == 6 ]] && return 0
export OMAPOWER_BASH_INTEGRATION_LOADED=6

_OMAPOWER_SOCKET=${XDG_RUNTIME_DIR:-/run/user/$UID}/omapower.sock
_OMAPOWER_ROWS=${LINES:-1}
_OMAPOWER_COLUMNS=${COLUMNS:-1}
_OMAPOWER_PROMPT_ROW=1
_OMAPOWER_PROMPT_COLUMN=1
_OMAPOWER_PROMPT_WIDTH=0
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
  local rendered plain suffix row column linear tty_state prompt_newlines=0
  IFS=' ' read -r _OMAPOWER_ROWS _OMAPOWER_COLUMNS < <(stty size < /dev/tty 2>/dev/null) || true
  [[ $_OMAPOWER_ROWS =~ ^[0-9]+$ && $_OMAPOWER_COLUMNS =~ ^[0-9]+$ ]] \
    && (( _OMAPOWER_ROWS > 0 && _OMAPOWER_COLUMNS > 0 )) || {
    _OMAPOWER_ROWS=${LINES:-1}
    _OMAPOWER_COLUMNS=${COLUMNS:-1}
  }
  (( _OMAPOWER_ROWS > 0 )) || _OMAPOWER_ROWS=1
  (( _OMAPOWER_COLUMNS > 0 )) || _OMAPOWER_COLUMNS=1

  # Capture the terminal position once, before Bash draws the next prompt.
  # Per-key terminal queries race Readline's input parser and can leak reply
  # bytes into the command line. Every keystroke below is therefore pure
  # arithmetic from this stable prompt anchor.
  tty_state=$(stty -g <&"$_OMAPOWER_TTY_FD" 2>/dev/null) || tty_state=
  [[ -n $tty_state ]] && stty -echo -icanon min 0 time 1 <&"$_OMAPOWER_TTY_FD" 2>/dev/null
  printf '\e[6n' >&"$_OMAPOWER_TTY_FD"
  if IFS=';' read -r -d R -t 0.12 row column <&"$_OMAPOWER_TTY_FD"; then
    row=${row##*$'\e['}
    if [[ $row =~ ^[0-9]+$ && $column =~ ^[0-9]+$ ]]; then
      _OMAPOWER_PROMPT_ROW=$row
      _OMAPOWER_PROMPT_COLUMN=$column
    fi
  fi
  [[ -n $tty_state ]] && stty "$tty_state" <&"$_OMAPOWER_TTY_FD" 2>/dev/null

  rendered=${PS1@P}
  plain=$(printf '%s' "$rendered" | sed -E $'s/\x1B\\][^\x07]*(\x07|\x1B\\\\)//g; s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g; s/[\x01\x02]//g')
  suffix=$plain
  while [[ $suffix == *$'\n'* ]]; do
    suffix=${suffix#*$'\n'}
    ((prompt_newlines += 1))
  done
  _OMAPOWER_PROMPT_WIDTH=$(printf '%s' "$suffix" | LC_ALL=C.UTF-8 wc -L)
  _OMAPOWER_PROMPT_WIDTH=${_OMAPOWER_PROMPT_WIDTH//[[:space:]]/}
  [[ $_OMAPOWER_PROMPT_WIDTH =~ ^[0-9]+$ ]] || _OMAPOWER_PROMPT_WIDTH=${#suffix}

  if (( prompt_newlines > 0 )); then
    _OMAPOWER_PROMPT_ROW=$((_OMAPOWER_PROMPT_ROW + prompt_newlines))
    (( _OMAPOWER_PROMPT_ROW > _OMAPOWER_ROWS )) && _OMAPOWER_PROMPT_ROW=$_OMAPOWER_ROWS
    _OMAPOWER_PROMPT_COLUMN=$((_OMAPOWER_PROMPT_WIDTH % _OMAPOWER_COLUMNS + 1))
    _OMAPOWER_PROMPT_ROW=$((_OMAPOWER_PROMPT_ROW + _OMAPOWER_PROMPT_WIDTH / _OMAPOWER_COLUMNS))
  else
    linear=$((_OMAPOWER_PROMPT_COLUMN - 1 + _OMAPOWER_PROMPT_WIDTH))
    _OMAPOWER_PROMPT_ROW=$((_OMAPOWER_PROMPT_ROW + linear / _OMAPOWER_COLUMNS))
    _OMAPOWER_PROMPT_COLUMN=$((linear % _OMAPOWER_COLUMNS + 1))
  fi
  (( _OMAPOWER_PROMPT_ROW > _OMAPOWER_ROWS )) && _OMAPOWER_PROMPT_ROW=$_OMAPOWER_ROWS
}

_omapower_after_insert() {
  local row column linear point current_rows current_columns
  current_rows=${LINES:-$_OMAPOWER_ROWS}
  current_columns=${COLUMNS:-$_OMAPOWER_COLUMNS}
  if [[ $current_rows =~ ^[0-9]+$ && $current_columns =~ ^[0-9]+$ ]] \
      && (( current_rows > 0 && current_columns > 0 )) \
      && (( current_rows != _OMAPOWER_ROWS || current_columns != _OMAPOWER_COLUMNS )); then
    _OMAPOWER_ROWS=$current_rows
    _OMAPOWER_COLUMNS=$current_columns
  fi
  point=${READLINE_POINT:-0}
  linear=$((_OMAPOWER_PROMPT_COLUMN - 1 + point))
  row=$((_OMAPOWER_PROMPT_ROW + linear / _OMAPOWER_COLUMNS))
  (( row > _OMAPOWER_ROWS )) && row=$_OMAPOWER_ROWS
  column=$((linear % _OMAPOWER_COLUMNS + 1))
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
# normal editing and undo behavior. The callback combines the prompt anchor with
# Readline's post-insert cursor index to recover the visible cursor cell without
# sending a terminal query while Readline is processing input.
for ((_omapower_code = 32; _omapower_code <= 126; _omapower_code++)); do
  printf -v _omapower_binding '"\\x%02x":"\\C-v\\x%02x\\e[99~"' "$_omapower_code" "$_omapower_code"
  bind -m emacs-standard "$_omapower_binding"
  bind -m vi-insert "$_omapower_binding"
done
bind -m emacs-standard -x '"\e[99~":_omapower_after_insert'
bind -m vi-insert -x '"\e[99~":_omapower_after_insert'
unset _omapower_code _omapower_binding
