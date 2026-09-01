# Optional OmaPower Zsh integration.
# It sends only the word "burst". No key value or command text leaves Zsh.

if [[ -o interactive && -n ${XDG_RUNTIME_DIR:-} ]] && zmodload zsh/net/socket 2>/dev/null; then
  typeset -g OMAPOWER_SOCKET="$XDG_RUNTIME_DIR/omapower.sock"
  typeset -g OMAPOWER_FD=""

  _omapower_connect() {
    [[ -S $OMAPOWER_SOCKET ]] || return 1
    zsocket "$OMAPOWER_SOCKET" 2>/dev/null || return 1
    OMAPOWER_FD=$REPLY
  }

  _omapower_signal() {
    if [[ -z $OMAPOWER_FD ]] || ! print -ru "$OMAPOWER_FD" -- burst 2>/dev/null; then
      [[ -n $OMAPOWER_FD ]] && zsocket -d "$OMAPOWER_FD" 2>/dev/null
      OMAPOWER_FD=""
      _omapower_connect && print -ru "$OMAPOWER_FD" -- burst 2>/dev/null
    fi
  }

  _omapower_self_insert() {
    zle .self-insert
    _omapower_signal
  }

  zle -N self-insert _omapower_self_insert
fi
