#include "cprocshim.h"

#include <IOKit/serial/ioss.h>
#include <libproc.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <termios.h>

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

int64_t memterm_pid_start_time(pid_t pid) {
    struct proc_bsdinfo info;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (n <= 0) {
        return -1;
    }
    return (int64_t)info.pbi_start_tvsec * 1000000 + (int64_t)info.pbi_start_tvusec;
}

int memterm_set_arbitrary_baud(int fd, unsigned long speed) {
    speed_t s = (speed_t)speed;
    return ioctl(fd, IOSSIOSPEED, &s);
}
