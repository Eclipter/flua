#include <errno.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <unistd.h>

static volatile sig_atomic_t agent;

static void release_agent(int signal_number) {
    if (agent > 1) kill(agent, SIGCONT);
    _exit(signal_number ? 1 : 0);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    long parsed = strtol(argv[1], &end, 10);
    if (!end || *end || parsed <= 1 || parsed > INT32_MAX) return 2;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    struct proc_bsdinfo info;
    if (proc_pidpath((pid_t)parsed, path, sizeof(path)) <= 0 ||
        strcmp(path, "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent") ||
        proc_pidinfo((pid_t)parsed, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info) ||
        info.pbi_uid != getuid()) return 2;
    agent = (sig_atomic_t)parsed;
    signal(SIGTERM, release_agent);
    signal(SIGINT, release_agent);
    signal(SIGHUP, release_agent);
    signal(SIGPIPE, release_agent);
    if (kill(agent, SIGSTOP)) return 3;
    for (int attempt = 0; attempt < 100; attempt++) {
        if (proc_pidinfo(agent, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) release_agent(1);
        if (info.pbi_status == SSTOP) break;
        if (attempt == 99) release_agent(1);
        usleep(10000);
    }
    if (write(STDOUT_FILENO, "ready\n", 6) != 6) release_agent(1);
    // EOF also resumes the service if Flua crashes while its store transaction is open.
    struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
    int result;
    do { result = poll(&input, 1, 10000); } while (result < 0 && errno == EINTR);
    char command = 0;
    if (result > 0 && read(STDIN_FILENO, &command, 1) == 1 && command == 'k') {
        if (!kill(agent, SIGKILL)) return 0;
        release_agent(1);
    }
    release_agent(0);
}
