# Top-level Makefile for bookmark-gt.
#
# Drives compile, lint, checkdoc, check-declare, and tests for the
# elisp package.  Follows the melpa-submit skill's multi-version
# pattern: named EMACS_30 / EMACS_31 binaries and per-version target
# families so `make check-all' is the pre-push guard.
#
# Targets:
#   make               — compile (default)
#   make lint          — package-lint every bookmark-gt*.el file
#   make checkdoc      — checkdoc every bookmark-gt*.el file (errors on any warning)
#   make check-declare — verify declare-function file arguments (errors on any mismatch)
#   make compile       — byte-compile every bookmark-gt*.el file (errors on warning)
#   make test          — run ERT tests under test/
#   make clean         — remove every *.elc file
#   make check         — compile + lint + checkdoc + check-declare
#   make check-ci      — alias for check-30 (matches the CI matrix floor)
#   make check-all     — check-30 + check-31 (run before pushing)
#   make help          — this help text
#
# Per-version targets (drop-in for check / checkdoc / lint / compile / test):
#   make check-30      — run `make check' under $(EMACS_30)
#   make check-31      — run `make check' under $(EMACS_31)
#   make checkdoc-30 / -31 — same shape for checkdoc alone
#
# Override the Emacs binary by passing EMACS=path/to/emacs.

EMACS ?= emacs

# Per-version binaries.  Adjust to match your local install layout.
EMACS_30 ?= /opt/homebrew/opt/emacs-plus@30/bin/emacs
EMACS_31 ?= /opt/homebrew/opt/emacs-plus@31/bin/emacs

# CI matches the Package-Requires floor (30.1).  Kept as an alias so
# `.github/workflows/package-lint.yml' can call `make check-ci' without
# hardcoding the version.
CI_EMACS ?= $(EMACS_30)

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
#   9. bookmark-gt-browsel-tabs.el — browser tabs as temp bookmarks
EL_FILES = bookmark-gt.el \
           bookmark-gt-core.el \
           bookmark-gt-handlers.el \
           bookmark-gt-tags.el \
           bookmark-gt-list.el \
           bookmark-gt-jump.el \
           bookmark-gt-auto-update.el \
           bookmark-gt-default-tags.el \
           bookmark-gt-browsel-tabs.el

# Project-local ELPA so the user's personal package directory is not
# touched and CI starts from a clean slate every run.
ELPA_DIR = .elpa

# Dependencies installed into the project-local ELPA before lint/compile.
# bookmark-gt has NO hard runtime dependencies beyond Emacs itself
# (per Package-Requires); marginalia, consult, orderless, and browsel
# are all optional soft-deps loaded with `(require 'foo nil t)'.
# Install them here so byte-compile / package-lint can resolve the
# feature symbols without warnings.  `package-lint' is the lint tool
# itself.
DEPS = package-lint marginalia consult orderless

# Common Emacs invocation header: project-local package-user-dir, MELPA
# and NonGNU ELPA in package-archives, package-initialize so installed
# packages are on load-path.
EMACS_BATCH = $(EMACS) -Q --batch \
  --eval "(setq package-user-dir (expand-file-name \"$(ELPA_DIR)\"))" \
  --eval "(require 'package)" \
  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
  --eval "(add-to-list 'package-archives '(\"nongnu\" . \"https://elpa.nongnu.org/nongnu/\"))" \
  --eval "(package-initialize)"

.PHONY: default lint checkdoc check-declare compile test clean check help \
        check-ci check-all check-30 check-31 \
        checkdoc-30 checkdoc-31 checkdoc-all \
        lint-30 lint-31 lint-all \
        compile-30 compile-31 compile-all \
        test-30 test-31 test-all \
        version set-version check-version \
        info pdf docs clean-docs

# Default target: byte-compile.  Lint is not included here so the
# common edit-then-`make' loop stays fast; run `make check' or
# `make check-all' before committing.
default: compile

help:
	@echo "bookmark-gt Makefile targets:"
	@echo "  make               compile (default)"
	@echo "  make lint          package-lint every .el file"
	@echo "  make checkdoc      checkdoc every .el file"
	@echo "  make check-declare verify declare-function references"
	@echo "  make compile       byte-compile with -Werror"
	@echo "  make test          run ERT tests"
	@echo "  make check         compile + lint + checkdoc + check-declare + check-version"
	@echo "  make check-ci      alias for check-30 (matches CI matrix floor)"
	@echo "  make check-all     check-30 + check-31 (pre-push guard)"
	@echo "  make clean         remove *.elc"
	@echo "  make version       print the current package version"
	@echo "  make set-version VERSION=X.Y.Z"
	@echo "                     update every source's version to X.Y.Z"
	@echo "  make check-version verify every source agrees on the version"
	@echo "  make info          build bookmark-gt.info from readme.org"
	@echo "  make pdf           build bookmark-gt.pdf  from readme.org (needs TeX)"
	@echo "  make docs          build both bookmark-gt.info and bookmark-gt.pdf"
	@echo "  make clean-docs    remove generated .info / .pdf / .texi / .tex artifacts"

# assert-emacs: verify a named Emacs binary exists before delegating.
define assert-emacs
	@if [ ! -x "$($(1))" ]; then \
	  echo "$(1) not executable: $($(1))"; \
	  echo "Install with: brew install emacs-plus@$$(echo $(1) | sed -E 's/[^0-9]//g')"; \
	  echo "Or override: make <target> $(1)=/path/to/emacs"; \
	  exit 1; \
	fi
endef

$(ELPA_DIR):
	@mkdir -p $@

$(ELPA_DIR)/.installed: | $(ELPA_DIR)
	$(EMACS_BATCH) \
	  --eval "(unless package-archive-contents (package-refresh-contents))" \
	  $(foreach pkg,$(DEPS),--eval "(unless (package-installed-p '$(pkg)) (package-install '$(pkg)))")
	@touch $@

lint: $(ELPA_DIR)/.installed
	$(EMACS_BATCH) \
	  --eval "(require 'package-lint)" \
	  -f package-lint-batch-and-exit $(EL_FILES)

# checkdoc runs in batch via `checkdoc-file', which writes warnings to
# stderr (via `display-warning') but never exits non-zero on its own.
# After each file, peek at the `*Warnings*' buffer to detect whether
# any warning was emitted and exit 1 on the first one so CI fails on
# regressions.  Stderr already carries the human-readable diagnostic;
# no need to re-print it.  `-L .' lets each file `require' its
# siblings during checkdoc's own load.
checkdoc:
	@$(EMACS_BATCH) \
	  -L . \
	  --eval "(require 'checkdoc)" \
	  --eval "(let ((had-issue nil)) \
	            (dolist (f command-line-args-left) \
	              (with-current-buffer (get-buffer-create \"*Warnings*\") (erase-buffer)) \
	              (checkdoc-file f) \
	              (when (> (buffer-size (get-buffer-create \"*Warnings*\")) 0) \
	                (setq had-issue t))) \
	            (when had-issue (kill-emacs 1)))" \
	  $(EL_FILES)

# check-declare verifies the file argument of every `declare-function'
# form by loading the named file and checking that the function is
# defined there.
check-declare:
	@$(EMACS_BATCH) \
	  -L . \
	  --eval "(require 'check-declare)" \
	  --eval "(let ((had-issue nil)) \
	            (dolist (f command-line-args-left) \
	              (when (check-declare-file f) \
	                (setq had-issue t))) \
	            (when had-issue \
	              (with-current-buffer (get-buffer-create check-declare-warning-buffer) \
	                (princ (buffer-string))) \
	              (kill-emacs 1)))" \
	  $(EL_FILES)

# Compile each file in a fresh subprocess so a definition leaked by
# one file cannot mask a missing `require' in another.  Treats every
# byte-compile warning as a hard error so CI catches them before
# commit.
compile: $(ELPA_DIR)/.installed
	@set -e; \
	for f in $(EL_FILES); do \
	  echo "==> compiling $$f"; \
	  $(EMACS_BATCH) \
	    --eval "(setq byte-compile-error-on-warn t)" \
	    -L . \
	    -f batch-byte-compile $$f; \
	done

# ERT test runner.  Loads every test/*.el file and runs all tests
# batch-mode with a non-zero exit on any failure.
test: $(ELPA_DIR)/.installed
	@if [ -d test ]; then \
	  $(EMACS_BATCH) \
	    -L . -L test \
	    $(foreach f,$(wildcard test/*.el),-l $(f)) \
	    -f ert-run-tests-batch-and-exit; \
	else \
	  echo "no test/ directory; skipping"; \
	fi

clean:
	rm -f *.elc test/*.elc

# ---------------------------------------------------------------------------
# Documentation targets
#
# readme.org is the single source of truth.  Info output requires
# `makeinfo' (bundled with Emacs / Homebrew).  PDF output requires
# a TeX distribution — BasicTeX (~100 MB) is enough.  Both
# artifacts land under docs/ (see `#+EXPORT_FILE_NAME' in
# readme.org).

info: docs/bookmark-gt.info

docs/bookmark-gt.info: readme.org
	@mkdir -p docs
	$(CI_EMACS) -Q --batch $< \
	  --eval "(require 'ox-texinfo)" \
	  -f org-texinfo-export-to-info
	@rm -f docs/bookmark-gt.texi

pdf: docs/bookmark-gt.pdf

docs/bookmark-gt.pdf: readme.org
	@mkdir -p docs
	$(CI_EMACS) -Q --batch $< \
	  --eval "(require 'ox-latex)" \
	  -f org-latex-export-to-pdf
	@rm -f docs/bookmark-gt.tex docs/bookmark-gt.aux \
	       docs/bookmark-gt.log docs/bookmark-gt.out \
	       docs/bookmark-gt.toc

docs: info pdf

clean-docs:
	rm -f docs/bookmark-gt.info docs/bookmark-gt.texi \
	      docs/bookmark-gt.pdf docs/bookmark-gt.tex \
	      docs/bookmark-gt.aux docs/bookmark-gt.log \
	      docs/bookmark-gt.out docs/bookmark-gt.toc

check: compile lint checkdoc check-declare check-version

# Version management.  Single source of truth is bookmark-gt.el's
# `;; Version:' header, which is also mirrored into the
# `bookmark-gt-version' defconst inside that file.  Every other
# bookmark-gt*.el mirrors the same `;; Version:' header so
# package-lint is happy.  `scripts/update-version.sh' rewrites all
# three surfaces atomically; `check-version' fails if any drift
# and is wired into `make check' so CI catches drift on every PR.
version:
	@sed -n 's/^;; Version: //p' bookmark-gt.el

set-version:
	@if [ -z "$(VERSION)" ]; then \
	  echo "usage: make set-version VERSION=X.Y.Z"; \
	  exit 2; \
	fi
	@scripts/update-version.sh "$(VERSION)"

# Extract the version from every source (header + defconst) and
# fail loudly on any mismatch.  Each `sort -u' over the collected
# versions should yield exactly one line.
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

# Per-version target families.  Each delegates back into $(MAKE) with
# EMACS pinned so the sub-invocation's EMACS_BATCH picks up the right
# binary.  `check-30' and `check-31' are the primary use; the finer-
# grained `lint-30' / `checkdoc-31' variants are handy when tracking
# down a version-specific failure.
check-30:      ; $(call assert-emacs,EMACS_30) ; $(MAKE) EMACS=$(EMACS_30) check
check-31:      ; $(call assert-emacs,EMACS_31) ; $(MAKE) EMACS=$(EMACS_31) check
check-all:     check-30 check-31
check-ci:      check-30

checkdoc-30:   ; $(call assert-emacs,EMACS_30) ; $(MAKE) EMACS=$(EMACS_30) checkdoc
checkdoc-31:   ; $(call assert-emacs,EMACS_31) ; $(MAKE) EMACS=$(EMACS_31) checkdoc
checkdoc-all:  checkdoc-30 checkdoc-31

lint-30:       ; $(call assert-emacs,EMACS_30) ; $(MAKE) EMACS=$(EMACS_30) lint
lint-31:       ; $(call assert-emacs,EMACS_31) ; $(MAKE) EMACS=$(EMACS_31) lint
lint-all:      lint-30 lint-31

compile-30:    ; $(call assert-emacs,EMACS_30) ; $(MAKE) EMACS=$(EMACS_30) compile
compile-31:    ; $(call assert-emacs,EMACS_31) ; $(MAKE) EMACS=$(EMACS_31) compile
compile-all:   compile-30 compile-31

test-30:       ; $(call assert-emacs,EMACS_30) ; $(MAKE) EMACS=$(EMACS_30) test
test-31:       ; $(call assert-emacs,EMACS_31) ; $(MAKE) EMACS=$(EMACS_31) test
test-all:      test-30 test-31
