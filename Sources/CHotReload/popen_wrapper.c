#include <stdio.h>
#include "include/CHotReload.h"

FILE *hot_reload_popen(const char *command, const char *mode) {
    return popen(command, mode);
}

int hot_reload_pclose(FILE *stream) {
    return pclose(stream);
}
