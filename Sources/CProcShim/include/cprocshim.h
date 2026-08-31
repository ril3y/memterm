#ifndef CPROCSHIM_H
#define CPROCSHIM_H

#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>

// libproc wrappers (libproc.h has no Swift module; App Sandbox would deny
// these calls, which is why memterm ships non-sandboxed — REQUIREMENTS FR-46).

// Kernel-truth cwd of `pid` via PROC_PIDVNODEPATHINFO. 0 on success.
int memterm_pid_cwd(pid_t pid, char *buf, size_t bufsize);

// Direct children of `pid`; returns the number of pids written.
// `bufsize` is in BYTES (proc_listchildpids convention).
int memterm_child_pids(pid_t pid, pid_t *buf, int bufsize);

// Process start timestamp in microseconds since the epoch, via
// PROC_PIDTBSDINFO (FR-14 PID-reuse guard). -1 on failure.
int64_t memterm_pid_start_time(pid_t pid);

// Arbitrary (non-standard) baud via ioctl(IOSSIOSPEED). The _IOW('T',2,speed_t)
// function-like macro cannot be imported into Swift ("structure not supported"),
// so this is the one serial ioctl needing the shim. Must be issued AFTER the
// final tcsetattr — any later tcsetattr reverts the driver to the termios rate.
// Returns 0 on success, -1 with errno set (ENOTTY on ptys — expected).
int memterm_set_arbitrary_baud(int fd, unsigned long speed);

#endif
