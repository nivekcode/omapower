# OmaPower Bash and Foot caret integration.
# It reports only cursor/grid geometry. Command text and typed characters never
# leave Bash.

[[ $- == *i* ]] || return 0
[[ ${OMAPOWER_BASH_INTEGRATION_LOADED:-0} == 10 ]] && return 0
# Keep the guard local to this Bash process. Child shells do not inherit the
# prompt hook or native Readline registration.
unset OMAPOWER_BASH_INTEGRATION_LOADED
OMAPOWER_BASH_INTEGRATION_LOADED=10

_OMAPOWER_SOCKET=${XDG_RUNTIME_DIR:-/run/user/$UID}/omapower.sock
_OMAPOWER_NATIVE=${XDG_CACHE_HOME:-$HOME/.cache}/omapower/omapower-readline.so
_OMAPOWER_ROWS=${LINES:-1}
_OMAPOWER_COLUMNS=${COLUMNS:-1}
_OMAPOWER_PROMPT_ROW=1
_OMAPOWER_PROMPT_COLUMN=1
_OMAPOWER_PROMPT_WIDTH=0

exec {_OMAPOWER_TTY_FD}<>/dev/tty || return 0
[[ -r $_OMAPOWER_NATIVE ]] || return 0
enable -f "$_OMAPOWER_NATIVE" omapower 2>/dev/null || return 0
omapower configure "$_OMAPOWER_SOCKET" || return 0

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
  # Foot answers this query immediately. Keeping it outside Readline avoids
  # touching the live input path while the user is typing.
  tty_state=$(stty -g <&"$_OMAPOWER_TTY_FD" 2>/dev/null) || tty_state=
  [[ -n $tty_state ]] && stty -echo -icanon min 0 time 1 <&"$_OMAPOWER_TTY_FD" 2>/dev/null
  printf '\e[6n' >&"$_OMAPOWER_TTY_FD"
  if IFS=';' read -r -d R -t 0.20 row column <&"$_OMAPOWER_TTY_FD"; then
    row=${row##*$'\e['}
    if [[ $row =~ ^[0-9]+$ && $column =~ ^[0-9]+$ ]]; then
      _OMAPOWER_PROMPT_ROW=$row
      _OMAPOWER_PROMPT_COLUMN=$column
    fi
  fi
  [[ -n $tty_state ]] && stty "$tty_state" <&"$_OMAPOWER_TTY_FD" 2>/dev/null

  rendered=${PS1@P}
  # ANSI byte ranges must use bytewise collation. Under locales such as
  # en_US.UTF-8, sed can otherwise count Starship's hidden color sequences as
  # visible prompt cells and move the particle origin far to the right.
  plain=$(printf '%s' "$rendered" | LC_ALL=C sed -E $'s/\x1B\\][^\x07]*(\x07|\x1B\\\\)//g; s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g; s/[\x01\x02]//g')
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
  omapower anchor "$_OMAPOWER_PROMPT_ROW" "$_OMAPOWER_PROMPT_COLUMN" \
    "$_OMAPOWER_ROWS" "$_OMAPOWER_COLUMNS"
}

if [[ ";${PROMPT_COMMAND[*]};" != *';_omapower_report_caret;'* ]]; then
  if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
    PROMPT_COMMAND+=( _omapower_report_caret )
  else
    PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_omapower_report_caret"
  fi
fi
