# Makefile for bookmark-gt.
#
# Package-specific settings only; every shared rule lives in
# Makefile.common, which is an identical copy across the dmg packages.
# Run `make help' for the target list, and see the header of
# Makefile.common for what each variable below controls.

PACKAGE = bookmark-gt

# Foundational files first so follow-on files can (require 'bookmark-gt)
# without erroring when compiled in isolation.  Order:
#   1. bookmark-gt.el          — entry, shared utils, autoloads, master switch
#   2. bookmark-gt-core.el     — bookmark-gt-set, extension hooks, same-name disambig
#   3. bookmark-gt-handlers.el — handler registry + non-file handlers
#   4. bookmark-gt-tags.el     — tag storage, reader, hook registration
#   5. bookmark-gt-list.el     — *Bookmarks-gt List* buffer (tabulated-list-mode)
#   6. bookmark-gt-jump.el     — consult reader, marginalia annotator, orderless
#   7. bookmark-gt-auto-update.el — idle timer, per-record state, refresh triggers
#   8. bookmark-gt-default-tags.el — default-tags DSL, tag-reader hook
#   9. bookmark-gt-browser-tabs.el — browser tabs as temp bookmarks
EL_FILES = bookmark-gt.el \
           bookmark-gt-core.el \
           bookmark-gt-handlers.el \
           bookmark-gt-tags.el \
           bookmark-gt-list.el \
           bookmark-gt-jump.el \
           bookmark-gt-auto-update.el \
           bookmark-gt-default-tags.el \
           bookmark-gt-browser-tabs.el \
           bookmark-gt-migrate.el

# bookmark-gt has NO hard runtime dependencies beyond Emacs itself (per
# Package-Requires); marginalia, consult, and orderless are optional
# soft-deps loaded with `(require 'foo nil t)'.  They are installed here
# so byte-compile and package-lint can resolve the feature symbols
# without warnings.  `package-lint' is the lint tool itself.
DEPS = package-lint marginalia consult orderless

INFO_SRC = readme.org

# Version drift across the sources is a release-blocking error, so the
# check runs as part of `make check'.
CHECK_EXTRA = check-version

HELP_EXTRA = "  make version        print the current package version" \
             "  make set-version VERSION=X.Y.Z   set it everywhere" \
             "  make check-version  verify every source agrees on it"

include Makefile.common

# Version management.  The single source of truth is bookmark-gt.el's
# `;; Version:' header, mirrored into the `bookmark-gt-version'
# defconst in that same file.  Every other bookmark-gt*.el repeats the
# header so package-lint is satisfied.  `scripts/update-version.sh'
# rewrites all three surfaces atomically; `check-version' fails on any
# drift and is wired into `check' so CI catches it on every PR.
.PHONY: version set-version check-version

version:
	@sed -n 's/^;; Version: //p' bookmark-gt.el

set-version:
	@if [ -z "$(VERSION)" ]; then \
	  echo "usage: make set-version VERSION=X.Y.Z"; \
	  exit 2; \
	fi
	@scripts/update-version.sh "$(VERSION)"

# Extract the version from every source (header + defconst) and fail
# loudly on any mismatch.
check-version:
	@primary=$$(sed -n 's/^;; Version: //p' bookmark-gt.el); \
	if [ -z "$$primary" ]; then \
	  echo "check-version: bookmark-gt.el has no Version header"; \
	  exit 1; \
	fi; \
	drift=0; \
	for f in $(EL_FILES); do \
	  v=$$(sed -n 's/^;; Version: //p' $$f); \
	  if [ "$$v" != "$$primary" ]; then \
	    echo "check-version: $$f has Version '$$v', expected '$$primary'"; \
	    drift=1; \
	  fi; \
	done; \
	dc=$$(sed -nE 's/^\(defconst bookmark-gt-version "([^"]+)".*/\1/p' bookmark-gt.el); \
	if [ "$$dc" != "$$primary" ]; then \
	  echo "check-version: bookmark-gt-version defconst is '$$dc', expected '$$primary'"; \
	  drift=1; \
	fi; \
	if [ $$drift -ne 0 ]; then exit 1; fi; \
	echo "version $$primary consistent across $(words $(EL_FILES)) files + defconst"
