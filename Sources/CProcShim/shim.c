#include "cprocshim.h"

#include <libproc.h>
#include <string.h>
#include <sys/proc_info.h>

int memterm_pid_cwd(pid_t pid, char *buf, size_t bufsize) {
    struct proc_vnodepathinfo vpi;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (n <= 0) {
        return -1;
    }
    strlcpy(buf, vpi.pvi_cdir.vip_path, bufsize);
    return 0;
}

int memterm_child_pids(pid_t pid, pid_t *buf, int bufsize) {
    return proc_listchildpids(pid, buf, bufsize);
}
