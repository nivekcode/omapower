# Optional OmaPower Bash and Foot caret integration.
# It reports only cursor row/column and terminal rows/columns at each prompt.

[[ $- == *i* ]] || return 0
[[ ${OMAPOWER_BASH_INTEGRATION_LOADED:-0} == 1 ]] && return 0
export OMAPOWER_BASH_INTEGRATION_LOADED=1

_omapower_report_caret() {
  local response row column rows columns tty_fd rendered plain suffix newline_chars newline_count linear_column
  IFS=' ' read -r rows columns < <(stty size < /dev/tty 2>/dev/null) || return 0
  exec {tty_fd}<>/dev/tty || return 0
  printf '\e[6n' >&"$tty_fd"
  IFS=';' read -r -s -d R -t 0.12 row column <&"$tty_fd" || true
  exec {tty_fd}>&-
  row=${row##*$'\e['}
  [[ $row =~ ^[0-9]+$ && $column =~ ^[0-9]+$ && $rows =~ ^[0-9]+$ && $columns =~ ^[0-9]+$ ]] || return 0

  # PROMPT_COMMAND runs before Bash paints PS1. Starship has already generated
  # PS1 by the time this hook runs, so account for its visible rows and columns
  # without sending the prompt text anywhere.
  rendered=${PS1@P}
  plain=$(printf '%s' "$rendered" | sed -E $'s/\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g')
  suffix=${plain##*$'\n'}
  newline_chars=${plain//[^$'\n']/}
  newline_count=${#newline_chars}
  if (( newline_count > 0 )); then
    row=$((row + newline_count))
    column=1
  fi
  linear_column=$((column + ${#suffix} - 1))
  row=$((row + linear_column / columns))
  column=$((linear_column % columns + 1))

  omarchy-shell -q omapower caret "$row" "$column" "$rows" "$columns" >/dev/null 2>&1 &
}

if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
  PROMPT_COMMAND+=( _omapower_report_caret )
else
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_omapower_report_caret"
fi
