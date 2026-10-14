# livefiles_hfs als statische Lib (arm64, macOS) ausserhalb von Apples Build + lifs_cli.
# Plan: docs/PLAN_FSKIT_HFS_2026-10-14.md, Phase 1.   make [-j] ; make clean
SDK  := $(shell xcrun --sdk macosx --show-sdk-path)
VEN  := vendor/hfs-715.100.10/livefiles_hfs_plugin
B    := build
CFLAGS ?= -O2 -g -arch arm64 -isysroot $(SDK) -I livefiles_shim $(EXTRA)
# Apples Quellen: pwrite/ioctl laufen ueber livefiles_shim/lifs_devio.c (Kappung 524288)
VFLAGS = $(CFLAGS) -I $(VEN) -DFS_BUNDLE_BIN_PATH='"/sbin"' -Dpwrite=lifs_dev_pwrite -Dioctl=lifs_dev_ioctl -w
VSRC := $(filter-out $(VEN)/livefiles_hfs_tester.c,$(wildcard $(VEN)/*.c))
OBJ  := $(patsubst %.c,$(B)/%.o,$(VSRC)) $(B)/livefiles_shim/lifs_devio.o

all: $(B)/liblivefiles_hfs.a $(B)/lifs_cli
$(B)/$(VEN)/%.o: $(VEN)/%.c
	@mkdir -p $(dir $@)
	@clang $(VFLAGS) -MMD -c $< -o $@
$(B)/livefiles_shim/%.o: livefiles_shim/%.c
	@mkdir -p $(dir $@)
	@clang $(CFLAGS) -Wall -MMD -c $< -o $@
$(B)/liblivefiles_hfs.a: $(OBJ)
	@rm -f $@ && libtool -static -o $@ $(OBJ)
$(B)/lifs_cli: lifs_cli/lifs_cli.c $(B)/liblivefiles_hfs.a
	clang $(CFLAGS) -Wall $< $(B)/liblivefiles_hfs.a -framework CoreFoundation -o $@
clean:
	rm -rf $(B)
-include $(OBJ:.o=.d)

# I/O-Invariante: kein Objekt ausser lifs_devio.o ruft eine libc-Schreibfunktion; Apples Quellen nur ueber lifs_dev_pwrite.
check-io: all
	@bad=0; for f in $$(find $(B) -name '*.o'); do case $$f in */lifs_devio.o) continue;; esac; \
	  if nm -u $$f | grep -E '^_(pwrite|write|pwritev|writev|aio_write|fwrite|ioctl)$$'; then echo "LECK in $$f"; bad=1; fi; done; \
	echo "Objekte mit _lifs_dev_pwrite:"; for f in $$(find $(B) -name '*.o'); do nm -u $$f | grep -q '^_lifs_dev_pwrite$$' && echo "  $$f"; done; \
	echo "pwrite-Aufrufstellen in Apples Quellen (werden per -D umgeleitet):"; grep -n '\bpwrite *(' $(VEN)/*.c | grep -v tester | sed 's/^/  /'; \
	[ $$bad = 0 ] && echo "check-io: OK, kein anderer Schreibweg" || { echo "check-io: FEHLER"; exit 1; }
