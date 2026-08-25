CC ?= cc
CPPFLAGS ?=
CFLAGS ?= -O2 -pipe
HARDENING_CFLAGS := -std=c17 -Wall -Wextra -Werror -Wformat=2 -Wconversion \
	-Wshadow -Wstrict-prototypes -fstack-protector-strong -fPIE \
	-D_FORTIFY_SOURCE=3
HARDENING_LDFLAGS := -pie -Wl,-z,relro,-z,now

.PHONY: all clean check

all: build/omarchy-admin-toggle-helper

build:
	mkdir -p $@

build/omarchy-admin-toggle-helper: src/omarchy-admin-toggle-helper.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $(HARDENING_CFLAGS) $< -o $@ $(LDFLAGS) $(HARDENING_LDFLAGS)

check: all
	./tests/run.sh

clean:
	rm -f build/omarchy-admin-toggle-helper build/omarchy-admin-toggle-helper-test

