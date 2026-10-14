// Liest DKIOCGETMAXBYTECOUNTWRITE/-BLOCKCOUNTWRITE am Rohgeraet (nur lesen).
// cc -o /tmp/maxwrite tools/maxwrite.c ; /tmp/maxwrite /dev/rdisk14   (evtl. sudo noetig)
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/disk.h>
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s /dev/rdiskN\n", argv[0]); return 2; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    uint64_t b = 0, w = 0;
    if (ioctl(fd, DKIOCGETMAXBYTECOUNTWRITE, &b) != 0) perror("DKIOCGETMAXBYTECOUNTWRITE");
    if (ioctl(fd, DKIOCGETMAXBLOCKCOUNTWRITE, &w) != 0) perror("DKIOCGETMAXBLOCKCOUNTWRITE");
    printf("%s maxbytecountwrite=%llu maxblockcountwrite=%llu\n", argv[1], (unsigned long long)b, (unsigned long long)w);
    return 0;
}
