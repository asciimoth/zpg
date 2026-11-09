#include <fcntl.h>
#include <spawn.h>
#include <unistd.h>

/* Supply a raw progress pipe without the std.Progress collector. */
int zpg_spawn(pid_t *pid, char *const argv[], char *const env[],
              int out, int err, int progress_fd, int ignore_stdin) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result) return result;
    result = posix_spawnattr_init(&attributes);
    if (result) {
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }
#define CHECK(call) do { result = (call); if (result) goto done; } while (0)
    if (ignore_stdin)
        CHECK(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0));
    CHECK(posix_spawn_file_actions_adddup2(&actions, out, 1));
    CHECK(posix_spawn_file_actions_adddup2(&actions, err, 2));
#ifdef __APPLE__
    CHECK(posix_spawn_file_actions_addinherit_np(&actions, progress_fd));
#else
    CHECK(posix_spawn_file_actions_adddup2(&actions, progress_fd, progress_fd));
#endif
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP));
    result = posix_spawnp(pid, argv[0], &actions, &attributes, argv, env);
done:
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}
