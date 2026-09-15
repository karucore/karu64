// SPDX-License-Identifier: Apache-2.0
// PID 1: run actual upstream KVM guests and report only completed test results.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysinfo.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void timeout_handler(int signum)
{
    static const char message[] = "\n[KVM-KARU] FAIL timeout\n";
    (void)signum;
    (void)write(STDOUT_FILENO, message, sizeof(message) - 1);
    for (;;)
        pause();
}

static void fail(const char *operation)
{
    printf("[KVM-KARU] FAIL %s: %s\n", operation, strerror(errno));
    for (;;)
        pause();
}

static void mount_fs(const char *type, const char *target)
{
    if (mount(type, target, type, 0, NULL) && errno != EBUSY)
        fail(target);
}

static void run_test(const char *name, char *const arguments[])
{
    int status;
    pid_t child;
    printf("[KVM-KARU] RUN %s\n", name);
    alarm(30);
    child = fork();
    if (child < 0)
        fail("fork");
    if (child == 0) {
        execv(arguments[0], arguments);
        perror("execv");
        _exit(127);
    }
    if (waitpid(child, &status, 0) != child)
        fail("waitpid");
    alarm(0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        printf("[KVM-KARU] FAIL %s wait_status=%d (SKIP is not a pass)\n", name, status);
        for (;;)
            pause();
    }
    printf("[KVM-KARU] PASS %s exit=0\n", name);
}

int main(void)
{
    struct sigaction action = { .sa_handler = timeout_handler };
    struct sysinfo memory;
    int console;
    char *const ebreak[] = { "/tests/ebreak_test", NULL };
    char *const timer[] = {
        "/tests/arch_timer", "-n", "1", "-i", "2", "-p", "1", "-m", "0", "-e", "1000", NULL
    };

    if (getpid() != 1) {
        fputs("This program is the KVM initramfs PID 1, not a host test runner.\n", stderr);
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    mount_fs("proc", "/proc");
    mount_fs("sysfs", "/sys");
    mount_fs("devtmpfs", "/dev");
    console = open("/dev/console", O_RDWR);
    if (console < 0)
        fail("console");
    for (int fd = 0; fd < 3; fd++)
        if (dup2(console, fd) < 0)
            fail("dup2");
    if (console > 2)
        close(console);
    if (sigaction(SIGALRM, &action, NULL))
        fail("sigaction");
    if (sysinfo(&memory))
        fail("sysinfo");
    printf("[KVM-KARU] INIT totalram=%lu freeram=%lu\n",
           memory.totalram * memory.mem_unit, memory.freeram * memory.mem_unit);
    if (access("/dev/kvm", R_OK | W_OK))
        fail("/dev/kvm");
    run_test("ebreak_test", ebreak);
    run_test("arch_timer", timer);
    puts("[KVM-KARU] COMPLETE tests=2 failed=0 skipped=0");
    for (;;)
        pause();
}
