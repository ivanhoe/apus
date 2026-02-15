// Hot Reload Symbol Interposition via fishhook
//
// Uses Facebook's fishhook to rebind symbols in the indirect symbol table.
// With `-Xlinker -interposable`, all function calls (including those from
// protocol witness thunks to body getters) go through __la_symbol_ptr stubs.
// fishhook directly overwrites these pointers, so even already-resolved
// symbols get rebound — unlike dyld_dynamic_interpose which only affects
// future lazy bindings.
//
// Flow:
// 1. Read all defined symbols from the new dylib (nlist → names + addresses)
// 2. Build fishhook rebinding array (symbol name → new address)
// 3. Call rebind_symbols() to patch all loaded images

#include "include/CHotReload.h"
#include "fishhook.h"

#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 hr_mach_header_t;
typedef struct segment_command_64 hr_segment_command_t;
typedef struct nlist_64 hr_nlist_t;
#define HR_LC_SEGMENT LC_SEGMENT_64
#else
typedef struct mach_header hr_mach_header_t;
typedef struct segment_command hr_segment_command_t;
typedef struct nlist hr_nlist_t;
#define HR_LC_SEGMENT LC_SEGMENT
#endif

/// Find the mach_header for a loaded image by matching its path.
/// Uses realpath to resolve symlinks (e.g. /tmp -> /private/tmp).
static const hr_mach_header_t *find_image_header(const char *path,
                                                  uint32_t *out_index) {
    char resolved_path[PATH_MAX];
    char resolved_name[PATH_MAX];

    if (!realpath(path, resolved_path)) {
        strncpy(resolved_path, path, PATH_MAX - 1);
        resolved_path[PATH_MAX - 1] = '\0';
    }

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;

        const char *cmp_name = name;
        if (realpath(name, resolved_name)) {
            cmp_name = resolved_name;
        }

        if (strcmp(cmp_name, resolved_path) == 0) {
            if (out_index) *out_index = i;
            return (const hr_mach_header_t *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

/// Symbol entry: mangled name + runtime address.
typedef struct {
    const char *name;   // Full mangled name from strtab (including leading _)
    void *address;      // Runtime address (n_value + slide)
} symbol_entry;

/// Read all defined-in-section symbols from a Mach-O image.
static symbol_entry *read_symbols(const hr_mach_header_t *header,
                                  intptr_t slide,
                                  int *out_count) {
    *out_count = 0;

    hr_segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(hr_mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        hr_segment_command_t *seg = (hr_segment_command_t *)cur;
        if (seg->cmd == HR_LC_SEGMENT) {
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = seg;
            }
        } else if (seg->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)seg;
        }
        cur += seg->cmdsize;
    }

    if (!symtab_cmd || !linkedit_segment) return NULL;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    hr_nlist_t *symtab = (hr_nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);

    // Count defined symbols
    int count = 0;
    for (uint32_t i = 0; i < symtab_cmd->nsyms; i++) {
        if ((symtab[i].n_type & N_TYPE) == N_SECT && symtab[i].n_value != 0) {
            const char *name = strtab + symtab[i].n_un.n_strx;
            if (name[0] != '\0') count++;
        }
    }
    if (count == 0) return NULL;

    symbol_entry *entries = (symbol_entry *)malloc(sizeof(symbol_entry) * count);
    if (!entries) return NULL;

    int idx = 0;
    for (uint32_t i = 0; i < symtab_cmd->nsyms && idx < count; i++) {
        if ((symtab[i].n_type & N_TYPE) == N_SECT && symtab[i].n_value != 0) {
            const char *name = strtab + symtab[i].n_un.n_strx;
            if (name[0] == '\0') continue;
            entries[idx].name = name;
            entries[idx].address = (void *)((uintptr_t)symtab[i].n_value + slide);
            idx++;
        }
    }

    *out_count = idx;
    return entries;
}

int hot_reload_interpose(const char *dylib_path) {
    if (!dylib_path) return -1;

    // 1. Find the new dylib image
    uint32_t new_index = 0;
    const hr_mach_header_t *new_header = find_image_header(dylib_path, &new_index);
    if (!new_header) return -1;
    intptr_t new_slide = _dyld_get_image_vmaddr_slide(new_index);

    // 2. Read symbols from the new dylib
    int new_count = 0;
    symbol_entry *new_symbols = read_symbols(new_header, new_slide, &new_count);
    if (!new_symbols || new_count == 0) return 0;

    // 3. Build fishhook rebinding array with 'replaced' pointers for verification
    // fishhook expects symbol names WITHOUT the leading underscore
    struct rebinding *rebindings = (struct rebinding *)calloc(
        new_count, sizeof(struct rebinding));
    void **replaced_ptrs = (void **)calloc(new_count, sizeof(void *));
    if (!rebindings || !replaced_ptrs) {
        free(new_symbols);
        free(rebindings);
        free(replaced_ptrs);
        return -1;
    }

    int rebind_count = 0;
    for (int i = 0; i < new_count; i++) {
        const char *name = new_symbols[i].name;
        // Strip leading underscore (Mach-O convention)
        if (name[0] == '_') name++;
        // Only rebind Swift symbols (start with $s after stripping _)
        if (name[0] != '$') continue;

        rebindings[rebind_count].name = name;
        rebindings[rebind_count].replacement = new_symbols[i].address;
        rebindings[rebind_count].replaced = &replaced_ptrs[rebind_count];
        rebind_count++;
    }

    // 4. Call fishhook to rebind across ALL loaded images
    int result = 0;
    if (rebind_count > 0) {
        int err = rebind_symbols(rebindings, rebind_count);
        if (err == 0) {
            // Count how many were actually rebound (replaced_ptr is non-NULL)
            int actually_rebound = 0;
            for (int i = 0; i < rebind_count; i++) {
                if (replaced_ptrs[i] != NULL) {
                    actually_rebound++;
                }
            }
            result = actually_rebound;
        } else {
            result = -1;
        }
    }

    free(replaced_ptrs);
    free(rebindings);
    free(new_symbols);

    return result;
}
