#define _XOPEN_SOURCE 700

#include <errno.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wchar.h>

#include "builtins.h"
#include "shell.h"
#include <readline/readline.h>

static char omapower_socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static int omapower_socket_fd = -1;
static int omapower_prompt_row = 1;
static int omapower_prompt_column = 1;
static int omapower_rows = 1;
static int omapower_columns = 1;

static void omapower_disconnect(void) {
  if (omapower_socket_fd >= 0) close(omapower_socket_fd);
  omapower_socket_fd = -1;
}

static int omapower_connect(void) {
  struct sockaddr_un address;

  if (omapower_socket_fd >= 0) return 0;
  if (omapower_socket_path[0] == '\0') return -1;

  omapower_socket_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (omapower_socket_fd < 0) return -1;

  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, omapower_socket_path, strlen(omapower_socket_path) + 1);
  if (connect(omapower_socket_fd, (struct sockaddr *)&address, sizeof(address)) == 0)
    return 0;

  omapower_disconnect();
  return -1;
}

static void omapower_send(const char *message) {
  size_t length = strlen(message);

  if (omapower_connect() != 0) return;
  if (send(omapower_socket_fd, message, length, MSG_NOSIGNAL) == (ssize_t)length)
    return;

  omapower_disconnect();
  if (omapower_connect() == 0)
    (void)send(omapower_socket_fd, message, length, MSG_NOSIGNAL);
}

static void omapower_cursor_position(const char *text, size_t length,
                                     int *cursor_row, int *cursor_column) {
  mbstate_t state;
  size_t offset = 0;
  int row = omapower_prompt_row;
  int column = omapower_prompt_column;

  memset(&state, 0, sizeof(state));
  while (offset < length) {
    wchar_t value;
    size_t consumed;
    int width;

    if (text[offset] == '\n') {
      row += 1;
      column = 1;
      offset += 1;
      memset(&state, 0, sizeof(state));
      continue;
    }
    if (text[offset] == '\t') {
      width = 8 - ((column - 1) % 8);
      offset += 1;
      memset(&state, 0, sizeof(state));
    } else {
      consumed = mbrtowc(&value, text + offset, length - offset, &state);
      if (consumed == (size_t)-1 || consumed == (size_t)-2) {
        consumed = 1;
        width = 1;
        memset(&state, 0, sizeof(state));
      } else if (consumed == 0) {
        break;
      } else {
        width = wcwidth(value);
        if (width < 0) width = 1;
      }
      offset += consumed;
    }

    column += width;
    while (column > omapower_columns) {
      row += 1;
      column -= omapower_columns;
    }
  }

  if (row > omapower_rows) row = omapower_rows;
  *cursor_row = row;
  *cursor_column = column;
}

static void omapower_report_cursor(void) {
  struct winsize terminal_size = {0};
  int row;
  int column;
  char message[128];

  if (ioctl(STDIN_FILENO, TIOCGWINSZ, &terminal_size) == 0) {
    if (terminal_size.ws_row > 0) omapower_rows = terminal_size.ws_row;
    if (terminal_size.ws_col > 0) omapower_columns = terminal_size.ws_col;
  }

  omapower_cursor_position(rl_line_buffer, (size_t)rl_point, &row, &column);

  if (terminal_size.ws_xpixel > 0 && terminal_size.ws_ypixel > 0) {
    double cell_height = (double)terminal_size.ws_ypixel / omapower_rows;
    double cell_width = (double)terminal_size.ws_xpixel / omapower_columns;
    snprintf(message, sizeof(message), "type %d %d %d %d %.6f %.6f\n",
             row, column, omapower_rows, omapower_columns,
             cell_height, cell_width);
  } else {
    snprintf(message, sizeof(message), "type %d %d %d %d\n",
             row, column, omapower_rows, omapower_columns);
  }
  omapower_send(message);
}

static int omapower_self_insert(int count, int key) {
  int result = rl_insert(count, key);
  if (result == 0) omapower_report_cursor();
  return result;
}

static void omapower_bind_keymap(const char *name) {
  Keymap keymap = rl_get_keymap_by_name(name);
  int key;

  if (keymap == NULL) return;
  for (key = 32; key <= 126; key++)
    rl_bind_key_in_map(key, omapower_self_insert, keymap);
}

static void omapower_bind_keys(void) {
  rl_add_defun("omapower-self-insert", omapower_self_insert, -1);
  omapower_bind_keymap("emacs-standard");
  omapower_bind_keymap("vi-insertion");
}

static void omapower_restore_keymap(const char *name) {
  Keymap keymap = rl_get_keymap_by_name(name);
  int key;

  if (keymap == NULL) return;
  for (key = 32; key <= 126; key++)
    rl_bind_key_in_map(key, rl_insert, keymap);
}

static int omapower_parse_positive(const char *text, int *value) {
  char *end = NULL;
  long parsed;

  errno = 0;
  parsed = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || parsed < 1 || parsed > 100000)
    return -1;
  *value = (int)parsed;
  return 0;
}

int omapower_builtin(WORD_LIST *list) {
  const char *command;

  if (list == NULL || list->word == NULL) return EXECUTION_FAILURE;
  command = list->word->word;
  list = list->next;

  if (strcmp(command, "configure") == 0) {
    const char *path;
    size_t length;

    if (list == NULL || list->word == NULL) return EXECUTION_FAILURE;
    path = list->word->word;
    length = strlen(path);
    if (length == 0 || length >= sizeof(omapower_socket_path)) return EXECUTION_FAILURE;
    memcpy(omapower_socket_path, path, length + 1);
    omapower_disconnect();
    omapower_bind_keys();
    (void)omapower_connect();
    return EXECUTION_SUCCESS;
  }

  if (strcmp(command, "anchor") == 0) {
    int *values[] = {
      &omapower_prompt_row,
      &omapower_prompt_column,
      &omapower_rows,
      &omapower_columns
    };
    char message[128];
    int index;

    for (index = 0; index < 4; index++) {
      if (list == NULL || list->word == NULL
          || omapower_parse_positive(list->word->word, values[index]) != 0)
        return EXECUTION_FAILURE;
      list = list->next;
    }
    snprintf(message, sizeof(message), "caret %d %d %d %d\n",
             omapower_prompt_row, omapower_prompt_column,
             omapower_rows, omapower_columns);
    omapower_send(message);
    return EXECUTION_SUCCESS;
  }

  return EXECUTION_FAILURE;
}

int omapower_builtin_load(char *name) {
  (void)name;
  setlocale(LC_CTYPE, "");
  omapower_bind_keys();
  return 1;
}

void omapower_builtin_unload(char *name) {
  (void)name;
  omapower_restore_keymap("emacs-standard");
  omapower_restore_keymap("vi-insertion");
  omapower_disconnect();
}

static char *omapower_doc[] = {
  "Configure OmaPower's native Readline hook or update its prompt anchor.",
  NULL
};

struct builtin omapower_struct = {
  "omapower",
  omapower_builtin,
  BUILTIN_ENABLED,
  omapower_doc,
  "omapower configure SOCKET | omapower anchor ROW COLUMN ROWS COLUMNS",
  0
};
