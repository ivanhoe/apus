#ifndef CHotReload_h
#define CHotReload_h

#include <stdint.h>

/// Interpose all exported function symbols from a loaded dylib
/// into all other loaded images in the process.
///
/// This requires the main binary to be linked with `-Xlinker -interposable`
/// so that internal function calls go through rebindable stubs.
///
/// @param dylib_path Absolute path to the dylib that was loaded via dlopen
/// @return Number of symbols rebound, or -1 on error
int hot_reload_interpose(const char *dylib_path);

#endif /* CHotReload_h */
