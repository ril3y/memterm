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

#endif
