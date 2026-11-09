#define _XOPEN_SOURCE 700
#include <locale.h>
#include <pthread.h>
#include <wchar.h>
#include <sys/stat.h>

static pthread_once_t width_once = PTHREAD_ONCE_INIT;
static locale_t width_locale;

static void init_width_locale(void) {
    width_locale = newlocale(LC_CTYPE_MASK, "C.UTF-8", (locale_t)0);
    if (!width_locale)
        width_locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", (locale_t)0);
}

/* Use the system's Unicode width table without changing other threads' locale. */
int zpg_terminal_width(unsigned int codepoint) {
    pthread_once(&width_once, init_width_locale);
    if (!width_locale) return 1;
    locale_t previous = uselocale(width_locale);
    int width = wcwidth((wchar_t)codepoint);
    uselocale(previous);
    return width < 0 ? 1 : width;
}

/* Inode numbers alone can collide on separate device filesystems. */
int zpg_same_terminal(int first, int second) {
    struct stat a, b;
    return fstat(first, &a) == 0 && fstat(second, &b) == 0 &&
           S_ISCHR(a.st_mode) && S_ISCHR(b.st_mode) && a.st_rdev == b.st_rdev;
}
