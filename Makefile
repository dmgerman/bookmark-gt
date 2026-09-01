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

# The version lives in exactly one place, so there is nothing to keep
# in sync; `check-version' only confirms that the one place is
# readable and that no second one has appeared.
CHECK_EXTRA = check-version

HELP_EXTRA = "  make version        print the current package version" \
             "  make check-version  verify the version has one source"

include Makefile.common

# Version management.  Editing the `;; Version:' header of
# bookmark-gt.el releases a new version — that header is the only
# place the number is written.  The `bookmark-gt-version' defconst
# reads it from the header at compile (or load) time, and the other
# bookmark-gt*.el files carry no version header at all: package-lint
# treats them as secondary files of a multi-file package because each
# sets `package-lint-main-file' in its file-local variables.
.PHONY: version check-version

version:
	@sed -n 's/^;; Version: //p' bookmark-gt.el

# Two failure modes are possible now that there is a single source:
# the header goes missing (the defconst would silently become
# "unknown"), or a second version header reappears in another file
# and starts to drift.
check-version:
	@primary=$$(sed -n 's/^;; Version: //p' bookmark-gt.el); \
	if [ -z "$$primary" ]; then \
	  echo "check-version: bookmark-gt.el has no Version header"; \
	  exit 1; \
	fi; \
	extra=0; \
	for f in $(filter-out bookmark-gt.el,$(EL_FILES)); do \
	  if sed -n 's/^;; Version: //p' $$f | grep -q .; then \
	    echo "check-version: $$f has a Version header; only bookmark-gt.el may"; \
	    extra=1; \
	  fi; \
	done; \
	if [ $$extra -ne 0 ]; then exit 1; fi; \
	echo "version $$primary, single source (bookmark-gt.el header)"
