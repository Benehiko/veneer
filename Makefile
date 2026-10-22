.PHONY: hooks build test fmt run install uninstall release clean prune-cache

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

uninstall:
	rm -f $(PREFIX)/bin/veneer $(PREFIX)/bin/veneer-inject.exe \
		$(PREFIX)/share/applications/veneer.desktop \
		$(PREFIX)/share/icons/hicolor/scalable/apps/veneer.svg
	rm -rf $(PREFIX)/share/licenses/veneer

VERSION ?= $(shell git describe --tags --always --dirty)
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct)
RELEASE_TARGETS ?= x86_64-linux-gnu
GPG ?= gpg
GPG_KEY ?=

release:
	@test -z "$$(git status --porcelain)" || { echo "make release: commit or stash your changes first"; exit 1; }
	rm -rf dist
	mkdir -p dist
	@for t in $(RELEASE_TARGETS); do \
		name=veneer-$(VERSION)-$${t%%-linux*}-linux; \
		zig build -Doptimize=safe -Dtarget=$$t -Dversion=$(VERSION) --prefix dist/$$name || exit 1; \
		cp README.md dist/$$name/ || exit 1; \
		tar -C dist --sort=name --owner=0 --group=0 --numeric-owner --mtime=@$(SOURCE_DATE_EPOCH) \
			-czf dist/$$name.tar.gz $$name || exit 1; \
		rm -rf dist/$$name; \
	done
	cd dist && sha256sum *.tar.gz > SHA256SUMS
	cd dist && for f in *.tar.gz SHA256SUMS; do \
		$(GPG) --batch --yes --armor --detach-sign $(if $(GPG_KEY),--local-user $(GPG_KEY)) $$f || exit 1; \
	done
	@echo "release $(VERSION) in dist/: tarballs, SHA256SUMS, and an .asc signature for each"

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
