.PHONY: hooks build test fmt run install uninstall clean prune-cache

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit

build:
	zig build

test:
	zig build test

fmt:
	zig build fmt

run:
	zig build run

PREFIX ?= $(HOME)/.local

install:
	zig build -Doptimize=safe --prefix $(PREFIX)
	install -Dm644 data/veneer.desktop $(PREFIX)/share/applications/veneer.desktop

uninstall:
	rm -f $(PREFIX)/bin/veneer $(PREFIX)/bin/veneer-inject.exe $(PREFIX)/share/applications/veneer.desktop

clean:
	rm -rf .zig-cache zig-out dist

CACHE_DAYS ?= 3

prune-cache:
	@test -d .zig-cache || { echo "make prune-cache: no .zig-cache"; exit 0; }
	@echo "before: $$(du -sh .zig-cache | cut -f1)"
	@for d in o h z c args tmp; do \
		test -d ".zig-cache/$$d" || continue; \
		find ".zig-cache/$$d" -maxdepth 1 -mindepth 1 -mtime +$(CACHE_DAYS) -exec rm -rf {} + ; \
	done
	@echo "after:  $$(du -sh .zig-cache | cut -f1)  (kept entries newer than $(CACHE_DAYS) days)"
