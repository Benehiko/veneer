.PHONY: hooks build test fmt run install uninstall release clean prune-cache site serve

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
	rm -rf .zig-cache zig-out dist $(SITE)

CACHE_DAYS ?= 3

prune-cache:
	@test -d .zig-cache || { echo "make prune-cache: no .zig-cache"; exit 0; }
	@echo "before: $$(du -sh .zig-cache | cut -f1)"
	@for d in o h z c args tmp; do \
		test -d ".zig-cache/$$d" || continue; \
		find ".zig-cache/$$d" -maxdepth 1 -mindepth 1 -mtime +$(CACHE_DAYS) -exec rm -rf {} + ; \
	done
	@echo "after:  $$(du -sh .zig-cache | cut -f1)  (kept entries newer than $(CACHE_DAYS) days)"
