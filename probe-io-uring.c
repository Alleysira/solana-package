#include <errno.h>
#include <linux/io_uring.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(void) {
    struct io_uring_params params = {0};
    int fd = syscall(SYS_io_uring_setup, 1, &params);
    if (fd < 0) {
        fprintf(stderr, "io_uring_setup: %s (errno=%d)\n", strerror(errno), errno);
        return 1;
    }
    close(fd);
    printf("io_uring features: 0x%x\n", params.features);
    unsigned required = IORING_FEAT_NODROP | IORING_FEAT_SQPOLL_NONFIXED;
    return (params.features & required) == required ? 0 : 2;
}
