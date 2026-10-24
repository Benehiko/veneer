.PHONY: hooks build test fmt run icon install uninstall tag release release-host publish clean prune-cache site serve

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

RSVG ?= rsvg-convert

icon:
	$(RSVG) --width 256 --height 256 data/veneer.svg --output data/veneer.png

PREFIX ?= $(HOME)/.local

install:
	zig build -Doptimize=safe -Ddesktop-exec=$(PREFIX)/bin/veneer --prefix $(PREFIX)
	@if [ -f $(PREFIX)/share/icons/hicolor/icon-theme.cache ] && command -v gtk-update-icon-cache >/dev/null; then \
		gtk-update-icon-cache -f -t -q $(PREFIX)/share/icons/hicolor; \
	fi

uninstall:
	rm -f $(PREFIX)/bin/veneer $(PREFIX)/bin/veneer-inject.exe \
		$(PREFIX)/share/applications/veneer.desktop \
		$(PREFIX)/share/icons/hicolor/scalable/apps/veneer.svg
	rm -rf $(PREFIX)/share/licenses/veneer $(PREFIX)/lib/veneer

VERSION ?=
DIST ?= dist
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct)

RELEASE_HOSTS ?= linux-x86_64

ZIG_TARGET_linux-x86_64 := x86_64-linux-gnu
ZIG_TARGET_linux-aarch64 := aarch64-linux-gnu

host_dir = veneer-$(VERSION)-$(1)
host_archive = $(call host_dir,$(1)).tar.gz
NATIVE_HOST := linux-$(patsubst arm64,aarch64,$(shell uname -m))
REPRO_TAR = tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@$(SOURCE_DATE_EPOCH)

CONTAINER ?= $(firstword $(foreach c,nerdctl podman docker,$(shell command -v $(c) 2>/dev/null)))
COSIGN ?= $(if $(shell command -v cosign 2>/dev/null),cosign,$(if $(CONTAINER),$(CONTAINER) run --rm -it --network host \
	--user 0:0 \
	-e HOME=/tmp -v "$(CURDIR)/$(DIST)":/work -w /work \
	ghcr.io/sigstore/cosign/cosign:latest))

COSIGN_IDENTITY ?= 18033717+Benehiko@users.noreply.github.com
COSIGN_ISSUER ?= https://github.com/login/oauth

RELEASE_REPO ?= Benehiko/veneer
NOTES_FOOTER ?= tools/release-notes-footer.md

tag:
	@test -n "$(VERSION)" || { echo "make tag: set VERSION, e.g. make tag VERSION=v0.1.0" >&2; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "make tag: the tree is dirty -- commit or stash first" >&2; exit 1; }
	@! git rev-parse -q --verify "refs/tags/$(VERSION)" >/dev/null || { \
		echo "make tag: $(VERSION) already exists -- delete it first, or pick another version" >&2; exit 1; }
	git tag -a "$(VERSION)" -m "veneer $(VERSION)"
	@echo
	@echo "tagged $(VERSION), locally. Nothing is pushed."
	@echo "next: make release VERSION=$(VERSION)"

release:
	@test -n "$(VERSION)" || { echo "make release: set VERSION, e.g. make release VERSION=v0.1.0" >&2; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "make release: the tree is dirty -- commit or stash first" >&2; exit 1; }
	@described=$$(git describe --tags --exact-match 2>/dev/null); \
		test "$$described" = "$(VERSION)" || { \
			echo "make release: HEAD is not tagged $(VERSION) (git describe says '$$described')" >&2; \
			echo "  run: make tag VERSION=$(VERSION)" >&2; \
			exit 1; }
	@command -v llvm-objcopy >/dev/null || { \
		echo "make release: no llvm-objcopy on PATH -- run it from nix develop" >&2; exit 1; }
	@test -n "$(COSIGN)" || { \
		echo "make release: no cosign and no container runtime (nerdctl, podman or docker)" >&2; \
		echo "  install one, or set COSIGN=<command>" >&2; \
		exit 1; }
	@echo "make release: $(VERSION)"
	rm -rf $(DIST)
	mkdir -p $(DIST)/symbols
	zig build test -Doptimize=safe -Dversion=$(VERSION)
	@for host in $(RELEASE_HOSTS); do \
		$(MAKE) --no-print-directory release-host VERSION=$(VERSION) HOST=$$host || exit 1; \
	done
	cp LICENSE $(DIST)/symbols/
	$(REPRO_TAR) -C $(DIST) -cf - symbols | gzip -n > $(DIST)/veneer-$(VERSION)-symbols.tar.gz
	rm -rf $(DIST)/symbols
	cd $(DIST) && sha256sum *.tar.gz > SHA256SUMS
	@echo
	@echo "signing SHA256SUMS with cosign (a browser will open once)..."
	cd $(DIST) && $(COSIGN) sign-blob --yes SHA256SUMS \
		--bundle SHA256SUMS.sigstore.json
	@test -r $(DIST)/SHA256SUMS.sigstore.json || { \
		echo "make release: the signature bundle is not readable by this account" >&2; \
		echo "  the container wrote it as another user -- check $(DIST)/SHA256SUMS.sigstore.json" >&2; \
		exit 1; }
	@echo
	@ls -la $(DIST)
	@echo
	@cat $(DIST)/SHA256SUMS
	@echo
	@echo "built and signed. Nothing is published yet."
	@echo "next: make publish VERSION=$(VERSION)"

release-host:
	@test -n "$(HOST)" || { echo "release-host: set HOST" >&2; exit 1; }
	@test -n "$(ZIG_TARGET_$(HOST))" || { echo "release-host: no ZIG_TARGET_$(HOST) in the Makefile" >&2; exit 1; }
	@echo
	@echo "--- $(HOST) ---"
	zig build -Doptimize=safe -Dversion=$(VERSION) -Dtarget=$(ZIG_TARGET_$(HOST)) \
		--prefix $(DIST)/$(call host_dir,$(HOST))
	cp README.md CHANGELOG.md $(DIST)/$(call host_dir,$(HOST))/
	install -m 755 tools/install.sh $(DIST)/$(call host_dir,$(HOST))/install.sh
	llvm-objcopy --only-keep-debug $(DIST)/$(call host_dir,$(HOST))/bin/veneer \
		$(DIST)/symbols/veneer-$(HOST).debug
	llvm-objcopy --strip-debug $(DIST)/$(call host_dir,$(HOST))/bin/veneer
	llvm-objcopy --add-gnu-debuglink=$(DIST)/symbols/veneer-$(HOST).debug \
		$(DIST)/$(call host_dir,$(HOST))/bin/veneer
	@for pdb in $(DIST)/$(call host_dir,$(HOST))/bin/*.pdb; do \
		test -f "$$pdb" || continue; \
		test -f "$(DIST)/symbols/$$(basename $$pdb)" || cp "$$pdb" $(DIST)/symbols/; \
		rm "$$pdb"; \
	done
	@if [ "$(HOST)" = "$(NATIVE_HOST)" ]; then \
		reported=$$($(DIST)/$(call host_dir,$(HOST))/bin/veneer --version | head -1); \
		test "$$reported" = "veneer $(VERSION)" || { \
			echo "release: the built binary reports '$$reported', not 'veneer $(VERSION)'" >&2; exit 1; }; \
		echo "version check: $$reported"; \
	fi
	$(REPRO_TAR) -C $(DIST) -cf - $(call host_dir,$(HOST)) | gzip -n > $(DIST)/$(call host_archive,$(HOST))
	rm -rf $(DIST)/$(call host_dir,$(HOST))

publish:
	@test -n "$(VERSION)" || { echo "make publish: set VERSION, e.g. make publish VERSION=v0.1.0" >&2; exit 1; }
	@git rev-parse -q --verify "refs/tags/$(VERSION)" >/dev/null || { \
		echo "make publish: no tag $(VERSION) -- run make tag VERSION=$(VERSION) first" >&2; exit 1; }
	@test -f $(DIST)/SHA256SUMS || { \
		echo "make publish: no $(DIST)/SHA256SUMS -- run make release VERSION=$(VERSION) first" >&2; exit 1; }
	@test -f $(DIST)/SHA256SUMS.sigstore.json || { \
		echo "make publish: SHA256SUMS is not signed -- run make release VERSION=$(VERSION)" >&2; exit 1; }
	@for archive in $(foreach h,$(RELEASE_HOSTS),$(call host_archive,$(h))) veneer-$(VERSION)-symbols.tar.gz; do \
		test -f $(DIST)/$$archive || { \
			echo "make publish: missing $(DIST)/$$archive" >&2; exit 1; }; \
	done
	@command -v gh >/dev/null || { echo "make publish: gh is not on PATH" >&2; exit 1; }
	cd $(DIST) && sha256sum --check SHA256SUMS
	@awk '/^## /{ if (p) exit } /^## \[?$(VERSION)\]?/ || /^## Unreleased/{ p=1; next } p' \
		CHANGELOG.md > $(DIST)/NOTES.md
	@grep -q '[^[:space:]]' $(DIST)/NOTES.md || { \
		echo "make publish: no notes for $(VERSION) in CHANGELOG.md (no '## $(VERSION)' or '## Unreleased' section)" >&2; \
		exit 1; }
	@sed -e 's|@VERSION@|$(VERSION)|g' \
		-e 's|@COSIGN_IDENTITY@|$(COSIGN_IDENTITY)|g' \
		-e 's|@COSIGN_ISSUER@|$(COSIGN_ISSUER)|g' \
		$(NOTES_FOOTER) >> $(DIST)/NOTES.md
	@! grep -n '@[A-Z_]*@' $(DIST)/NOTES.md || { \
		echo "make publish: $(NOTES_FOOTER) has a placeholder this Makefile does not fill (above)" >&2; \
		exit 1; }
	@echo
	@echo "about to publish $(VERSION):"
	@echo "  tag     -> origin, pushed"
	@echo "  release -> github.com/$(RELEASE_REPO), with:"
	@ls -1 $(DIST)/*.tar.gz $(DIST)/SHA256SUMS* | sed 's/^/    /'
	@echo
	git push origin "$(VERSION)"
	gh release create "$(VERSION)" \
		--repo $(RELEASE_REPO) \
		--verify-tag \
		--title "veneer $(VERSION)" \
		--notes-file $(DIST)/NOTES.md \
		$(DIST)/*.tar.gz $(DIST)/SHA256SUMS $(DIST)/SHA256SUMS.sigstore.json
	@echo
	@echo "published: https://github.com/$(RELEASE_REPO)/releases/tag/$(VERSION)"

PANDOC ?= pandoc
PAGEFIND ?= pagefind
SITE ?= _site
SITE_SRC := docs/guides
SITE_URL := https://benehiko.github.io/veneer
REPO_BLOB := https://github.com/Benehiko/veneer/blob/main
DEFAULT_DESCRIPTION := Veneer, a Linux-native game launcher: Steam and your own games through Proton, Wine or natively, with gamescope and OptiScaler, and game files never touched.
GUIDES := $(filter-out $(SITE_SRC)/README.md,$(wildcard $(SITE_SRC)/*.md))

site:
	@rm -rf $(SITE) && mkdir -p $(SITE)
	@cp $(SITE_SRC)/index.html $(SITE_SRC)/search.html $(SITE_SRC)/style.css $(SITE_SRC)/theme.js $(SITE)/
	@cp data/veneer.svg $(SITE)/
	@for md in $(GUIDES) $(SITE_SRC)/README.md; do \
		name=$$(basename "$$md" .md); \
		[ "$$name" = README ] && name=guides; \
		title=$$(sed -n '1s/^# //p' "$$md"); \
		[ -n "$$title" ] || { echo "site: $$md must start with a '# Title' line" >&2; exit 1; }; \
		desc=$$(sed -n 's/^<!-- description: \(.*\) -->$$/\1/p' "$$md" | head -n 1); \
		[ -n "$$desc" ] || desc='$(DEFAULT_DESCRIPTION)'; \
		sed -e 1d -e '/^<!-- description: /d' "$$md" | $(PANDOC) --from gfm --to html5 \
			--template $(SITE_SRC)/guide.template.html \
			--toc --toc-depth=2 --wrap=none \
			--metadata pagetitle="$$title" --metadata source="$$md" \
			--metadata description="$$desc" --metadata url="$(SITE_URL)/$$name.html" \
			--output "$(SITE)/$$name.html" || exit 1; \
	done
	@for f in $(SITE)/*.html; do \
		sed -E \
			-e 's#href="README\.md#href="guides.md#g' \
			-e 's#href="([A-Za-z0-9_-]+)\.md#href="\1.html#g' \
			-e 's#href="\.\./\.\./#href="$(REPO_BLOB)/#g' \
			-e 's#href="\.\./#href="$(REPO_BLOB)/docs/#g' \
			"$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f" || exit 1; \
	done
	@{ echo '<?xml version="1.0" encoding="UTF-8"?>'; \
		echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'; \
		echo '  <url><loc>$(SITE_URL)/</loc></url>'; \
		for f in $(SITE)/*.html; do \
			name=$$(basename "$$f"); \
			case "$$name" in index.html|search.html) continue;; esac; \
			echo "  <url><loc>$(SITE_URL)/$$name</loc></url>"; \
		done; \
		echo '</urlset>'; } > $(SITE)/sitemap.xml
	@$(PAGEFIND) --site $(SITE) --output-subdir pagefind --quiet
	@echo "site: built $(SITE)/ ($$(ls $(SITE)/*.html | wc -l | tr -d ' ') pages)"

serve: site
	@$(PAGEFIND) --site $(SITE) --output-subdir pagefind --quiet --serve

clean:
	rm -rf .zig-cache zig-out $(DIST) $(SITE)

CACHE_DAYS ?= 3

prune-cache:
	@test -d .zig-cache || { echo "make prune-cache: no .zig-cache"; exit 0; }
	@echo "before: $$(du -sh .zig-cache | cut -f1)"
	@for d in o h z c args tmp; do \
		test -d ".zig-cache/$$d" || continue; \
		find ".zig-cache/$$d" -maxdepth 1 -mindepth 1 -mtime +$(CACHE_DAYS) -exec rm -rf {} + ; \
	done
	@echo "after:  $$(du -sh .zig-cache | cut -f1)  (kept entries newer than $(CACHE_DAYS) days)"
