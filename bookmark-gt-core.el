;;; bookmark-gt-core.el --- Core primitives and extension hooks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Keywords: convenience, matching, hypermedia
;; URL: https://github.com/dmgerman/bookmark-gt
;; Version: 0.1.0

;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Core wrappers around `bookmark-store', `bookmark-save', and
;; `bookmark-load' with the extension-hook protocol used by the
;; rest of bookmark-gt (name-reader, tag-reader, after-set hooks;
;; same-name disambiguation via text properties on the stored
;; name string).
;;
;; See ai/design/bookmark-set-hooks.org and
;; ai/design/records-only-invariant.org in the source repository
;; for the design contracts this file implements.

;;; Code:

(require 'bookmark)
(require 'seq)

;;;; Field-access helpers with bookmark+ compat
;;
;; bookmark+ stores a placeholder string in the `filename' slot of
;; non-file records (URL, browser-tab, EWW).  bookmark-gt writes
;; non-file records with no `filename' at all — but we still need
;; to read the placeholder as \"absent\" so records created by
;; bookmark+ round-trip cleanly.  The URL prop has a similar
;; issue: our code writes it as `url'; bookmark+ writes it as
;; `location'.  These two helpers hide both differences from every
;; caller downstream (list column, jump annotator, URL handler).

(defconst bookmark-gt-non-file-placeholder "   - no file -"
  "String bookmark+ writes into the `filename' slot for non-file records.
Treated as if the field were absent when reading a record.")

(defun bookmark-gt-filename-of (record)
  "Return RECORD's `filename', or nil if it is the bookmark+ placeholder."
  (let ((f (bookmark-prop-get record 'filename)))
    (unless (and f (string= f bookmark-gt-non-file-placeholder))
      f)))

(defun bookmark-gt-url-of (record)
  "Return RECORD's URL from either the `url' or the `location' prop.
`url' is bookmark-gt's convention; `location' is bookmark+'s.
Returns nil when neither is present."
  (or (bookmark-prop-get record 'url)
      (bookmark-prop-get record 'location)))

;;;; Ephemeral-refresh hook
;;
;; Some bookmark sources produce transient records that should
;; only exist while their source is fresh — browser tabs are the
;; canonical example.  Rather than each source running its own
;; timer, we expose a shared hook fired by every UI entry that
;; benefits from up-to-date records: the jump reader before
;; reading, the list buffer on open, and the list buffer on
;; `revert-buffer' (`g').  Sources register their refresh
;; function into this hook when their mode turns on and remove it
;; when it turns off.
;;
;; The `--refreshing' guard prevents re-entrancy — a source that
;; registers a slow refresh should be careful not to trigger any
;; of the three UI entry points during its own refresh.

(defvar bookmark-gt-ephemeral-refresh-hook nil
  "Hook run before UI code reads or displays `bookmark-alist'.
Each function is called with no arguments.  Ephemeral bookmark
sources (browser tabs, etc.) register their refresh function
here when active.  Fired from `bookmark-gt-jump' (before the
reader), `bookmark-gt-list' (before the initial render), and
the list buffer's `revert-buffer-function' (`g').")

(defvar bookmark-gt--refreshing-ephemeral nil
  "Non-nil while `bookmark-gt-refresh-ephemeral' is running.
Prevents re-entrancy if a registered refresher triggers a UI
entry point that would refire the hook.")

(defun bookmark-gt-refresh-ephemeral ()
  "Run `bookmark-gt-ephemeral-refresh-hook' once, guarded.
No-op when already refreshing."
  (unless bookmark-gt--refreshing-ephemeral
    (let ((bookmark-gt--refreshing-ephemeral t))
      (run-hooks 'bookmark-gt-ephemeral-refresh-hook))))

;;;; Extension hooks
;;
;; All three hooks are top-level defvars per Emacs hook convention;
;; they contain callbacks, not state, and are listed in
;; ai/design/records-only-allowlist.el as category 4 (hook variable).

(defvar bookmark-gt-set-name-reader-hook nil
  "Abnormal hook that refines the default bookmark name.
Each function is called with two arguments: DEFAULT-NAME (string)
and CONTEXT (the record's alist).  The first function to return a
non-nil string wins; if every function returns nil, DEFAULT-NAME
is used unchanged.

The interactive prompt in `bookmark-gt-set' happens *after* this
hook, so hooks refine what the user sees prefilled, they do not
replace the prompt.")

(defvar bookmark-gt-set-tag-reader-hook nil
  "Abnormal chained hook that reads tags for a bookmark being set.
Each function is called with two arguments: RECORD (the record's
alist) and SEED-TAGS (list of strings).  The return value is a
new list of strings that becomes the SEED-TAGS for the next
function.  The final result is stored on the record under the
`tags' alist key.

Hook order matters: default-tags style hooks that compute
context-based seeds should be added earlier; interactive readers
that use the seeds as prefill should be added later.")

(defvar bookmark-gt-set-after-hook nil
  "Hook run after `bookmark-gt-set' stores a record.
Each function is called with one argument: the (NAME . DATA) pair
of the stored bookmark.  Return values are ignored.

Observers (list-buffer refresh, cache invalidation, notification)
register here.")

;;;; Same-name disambiguation
;;
;; Vanilla `bookmark-store' strips text properties from names and
;; vanilla `bookmark-load' runs `bookmark-maybe-rename' which
;; already appends "<N>" suffixes to colliding names on load.
;; Rather than fight both, we adopt the same convention on store:
;; a bookmark whose name collides with an existing one gets stored
;; as NAME<2>, NAME<3>, and so on.  Users see the suffix in the
;; list buffer; it is the accepted convention across vanilla,
;; bookmark+, and every third-party bookmark front-end.

(defun bookmark-gt-display-name (name)
  "Return the display form of NAME.
Currently the identity function; retained as an API surface so
future changes (e.g. hiding auto-generated \"<N>\" suffixes in the
list buffer) have a single place to hook."
  name)

(defun bookmark-gt-disambiguate-name (name)
  "Return NAME, or NAME<N> where N is the smallest available integer.
NAME is returned unchanged when no bookmark with that name exists
in `bookmark-alist'.  Otherwise N starts at 2 and increases until
the composed name is free."
  (if (null (bookmark-get-bookmark name 'noerror))
      name
    (named-let iter ((n 2))
      (let ((candidate (format "%s<%d>" name n)))
        (if (bookmark-get-bookmark candidate 'noerror)
            (iter (1+ n))
          candidate)))))

;;;; Hook runners (internal)

(defun bookmark-gt--refine-name (default-name context)
  "Run `bookmark-gt-set-name-reader-hook' and return the refined name.
Returns the first non-nil string returned by a hook, or
DEFAULT-NAME if every hook returns nil.  CONTEXT is passed to
each hook as its second argument."
  (or (run-hook-with-args-until-success
       'bookmark-gt-set-name-reader-hook default-name context)
      default-name))

(defun bookmark-gt--fold-tag-hooks (record seed-tags)
  "Fold `bookmark-gt-set-tag-reader-hook' over SEED-TAGS.
Each hook receives RECORD and the accumulator, and returns a
new accumulator.  Returns the final list."
  (seq-reduce (lambda (acc fn) (funcall fn record acc))
              bookmark-gt-set-tag-reader-hook
              seed-tags))

(defun bookmark-gt--with-tags (record tags)
  "Return RECORD's alist with TAGS attached under the `tags' key.
When TAGS is empty, RECORD is returned unchanged (no empty
`(tags)' entry is emitted, per the invariant in
ai/design/tag-storage.org)."
  (if (null tags)
      record
    (cons (cons 'tags tags) record)))

;;;; Internal: fast push
;;
;; We deliberately bypass `bookmark-store' because bookmark+ (which
;; some users still have loaded during the migration) has REDEFINED
;; `bookmark-store' — every call runs the bookmark+ bookkeeping
;; including a `*Bookmark List*' rebuild.  That's 27ms/call in
;; measured cases, which turns a browser-tab refresh of ~100 tabs
;; into a multi-second stall.
;;
;; The essential vanilla `bookmark-store' contract is: push the
;; record onto `bookmark-alist' (with text-properties stripped
;; from the name), update `bookmark-current-bookmark', and bump
;; `bookmark-alist-modification-count'.  The bmenu rebuild is
;; skipped — bookmark-gt owns its own list buffer and refreshes it
;; via `bookmark-gt-set-after-hook'.
;;
;; Auto-save is honored: if `bookmark-save-flag' is a number and
;; the modification count has crossed it, we call `bookmark-save'.
;; Callers that batch many stores should let-bind
;; `bookmark-save-flag' to nil to prevent mid-batch saves.

(defun bookmark-gt--push-record (name alist)
  "Push (NAME . ALIST) onto `bookmark-alist' with vanilla-compat bookkeeping.
NAME's text properties are stripped, matching what vanilla
`bookmark-store' does.  Returns the stripped name."
  (let ((stripped (copy-sequence name)))
    (set-text-properties 0 (length stripped) nil stripped)
    (push (cons stripped alist) bookmark-alist)
    (setq bookmark-current-bookmark stripped)
    (setq bookmark-alist-modification-count
          (1+ bookmark-alist-modification-count))
    (when (bookmark-time-to-save-p)
      (bookmark-save))
    stripped))

;;;; Public: elisp API

(defun bookmark-gt-set-non-file (name handler props)
  "Store a non-file bookmark called NAME using HANDLER.

PROPS is an alist of additional record entries (URL, page title,
etc.).  Non-file bookmarks omit the `filename' key entirely so
vanilla `bookmark-jump' dispatches on HANDLER, which must be a
function suitable for `bookmark-handler-function'.

Runs `bookmark-gt-set-name-reader-hook',
`bookmark-gt-set-tag-reader-hook', and
`bookmark-gt-set-after-hook' in that order.

Returns the stored (NAME . DATA) pair."
  (let* ((initial-data (cons (cons 'handler handler) props))
         (refined-name (bookmark-gt--refine-name name initial-data))
         (unique-name (bookmark-gt-disambiguate-name refined-name))
         (tags (bookmark-gt--fold-tag-hooks initial-data nil))
         (final-data (bookmark-gt--with-tags initial-data tags))
         (final-name (bookmark-gt--push-record unique-name final-data))
         (stored (cons final-name final-data)))
    (run-hook-with-args 'bookmark-gt-set-after-hook stored)
    stored))

;;;; Temporary bookmarks
;;
;; A record carrying the `bmkp-temp' alist key is a temp bookmark:
;; visible in `bookmark-alist' for the life of the Emacs session,
;; excluded from `bookmark-save' output.  Same key name as
;; bookmark+'s `bmkp-temp' so bookmark files round-trip either way
;; (per the data-compat design principle in ai/reimplement.org).
;;
;; The save filter is installed via advice on `bookmark-save' —
;; vanilla has no extension hook there.  Install / uninstall is
;; controlled by `bookmark-gt-mode' so a user who never enables it
;; sees plain vanilla behavior.

(defconst bookmark-gt-temp-key 'bmkp-temp
  "Alist key used to mark a bookmark as temporary.
Chosen to match bookmark+'s `bmkp-temp' so bookmark files
round-trip between the two packages without data loss.")

(defun bookmark-gt-temp-p (record)
  "Return non-nil when RECORD is marked as a temporary bookmark."
  (bookmark-prop-get record bookmark-gt-temp-key))

(defun bookmark-gt-toggle-temp (name)
  "Toggle the temp property on the bookmark called NAME.
Fires `bookmark-gt-set-after-hook' so the list buffer and any
other observers refresh."
  (interactive
   (list (bookmark-completing-read "Toggle temporary"
                                   (or bookmark-current-bookmark ""))))
  (let ((record (bookmark-get-bookmark name)))
    (unless record
      (user-error "No bookmark called %S" name))
    (let ((current (bookmark-gt-temp-p record)))
      (if current
          (setcdr record (assq-delete-all bookmark-gt-temp-key
                                          (cdr record)))
        (setcdr record (cons (cons bookmark-gt-temp-key t)
                             (cdr record))))
      (run-hook-with-args 'bookmark-gt-set-after-hook record)
      (message "%s temp on %S"
               (if current "Cleared" "Set") name))))

;;;; jump-via catch tag
;;
;; Vanilla `bookmark--jump-via' calls the handler, then unconditionally
;; runs `bookmark-after-jump-hook' and (if
;; `bookmark-automatically-show-annotations' is non-nil) pops up the
;; annotation buffer.  For handlers whose target is external — a
;; web browser opened via `browse-url', a browser tab focused via
;; browsel — the annotation buffer steals focus back from the
;; browser, which is not what the user wants.
;;
;; The handler cannot let-bind
;; `bookmark-automatically-show-annotations' to nil because the
;; check happens after the handler returns and the let has unwound.
;;
;; Bookmark+ solves this by redefining `bookmark--jump-via' with a
;; `(catch 'bookmark--jump-via ...)' around the body; handlers
;; then throw to skip everything after step 2.  We do the same
;; less intrusively via `:around' advice that wraps the vanilla
;; body in our own catch tag; handlers throw
;; `bookmark-gt-skip-post-handler' to opt out.
;;
;; The install/uninstall pair is wired to `bookmark-gt-mode' so
;; a user who never enables the package sees plain vanilla
;; behavior.  Handlers wrap their throw in a `condition-case' /
;; `no-catch' shim so a throw when the advice is not installed
;; silently degrades to a no-op.

(defun bookmark-gt--jump-via-catch-advice (orig-fn &rest args)
  "Wrap ORIG-FN (called with ARGS) in a `bookmark-gt-skip-post-handler' catch.
Handlers throw that tag to bail out of the post-handler steps
that vanilla `bookmark--jump-via' runs (annotation buffer,
`bookmark-after-jump-hook', fringe mark)."
  (catch 'bookmark-gt-skip-post-handler
    (apply orig-fn args)))

(defun bookmark-gt-install-jump-via-catch ()
  "Install the `bookmark--jump-via' catch advice.  Idempotent."
  (advice-add 'bookmark--jump-via :around
              #'bookmark-gt--jump-via-catch-advice))

(defun bookmark-gt-uninstall-jump-via-catch ()
  "Remove the `bookmark--jump-via' catch advice."
  (advice-remove 'bookmark--jump-via
                 #'bookmark-gt--jump-via-catch-advice))

(defmacro bookmark-gt-skip-post-handler (value)
  "Throw VALUE to the catch tag `bookmark-gt-skip-post-handler'.
Handlers use this at their tail to abort the vanilla post-
handler steps (annotation buffer, hooks, fringe mark) for the
current jump.  Safe to call even when the catch is not
installed: a `no-catch' error is silently swallowed by the
surrounding `condition-case'."
  `(condition-case nil
       (throw 'bookmark-gt-skip-post-handler ,value)
     (no-catch nil)))

;;;; File-rename tracker
;;
;; When a file is renamed on disk, any bookmark whose `filename'
;; matched the old path becomes stale.  This advice on
;; `rename-file' rewrites the alist entry to the new path.
;;
;; Two guards:
;;   - `bookmark-gt-track-renames' — user opt-out (default on).
;;   - `backup-file-name-p' — the rename that Emacs performs to
;;     create a backup file (default `backup-by-copying' nil path:
;;     rename ORIG → ORIG~, then write new ORIG) is a spurious
;;     match that would move the bookmark to the backup.
;;     Bookmark+'s tracker has this bug; ours does not.
;;
;; Directory renames update only bookmarks whose `filename'
;; matches the directory exactly — children are not rewritten.
;; Documented in the defcustom.

(defcustom bookmark-gt-track-renames t
  "Non-nil: `bookmark-gt-mode' updates bookmark `filename' on rename.
An `:around' advice on `rename-file' rewrites any bookmark
whose `filename' matches the source path to the destination
path.

Guards:
- Backup destinations (`backup-file-name-p') are always
  ignored regardless of this flag — Emacs's default save mode
  renames ORIG → ORIG~ to create backups, and chasing that
  rename would leave the bookmark pointing at the backup.
- Directory renames only update bookmarks whose `filename'
  equals the directory exactly.  Children are NOT rewritten.

Toggle takes effect immediately (the advice reads this
variable at call time)."
  :type 'boolean
  :group 'bookmark-gt)

(defun bookmark-gt--rename-file-advice (orig-fn from to &rest args)
  "Around advice for `rename-file' that follows the rename in `bookmark-alist'.
FROM and TO are the source/destination paths; ORIG-FN is
`rename-file'; ARGS carries `ok-if-already-exists' and any
further vanilla arguments.  Rewrites bookmarks whose
`filename' exactly equals FROM to point at TO.  Gated by
`bookmark-gt-track-renames' and skipped for backup destinations."
  (apply orig-fn from to args)
  (when (and bookmark-gt-track-renames
             (not (backup-file-name-p to)))
    (let ((from-abs (expand-file-name from))
          (to-abs   (expand-file-name to)))
      (dolist (rec bookmark-alist)
        (when (equal (bookmark-gt-filename-of rec) from-abs)
          (bookmark-prop-set (car rec) 'filename to-abs))))))

(defun bookmark-gt-install-rename-tracker ()
  "Install the `rename-file' tracker advice.  Idempotent."
  (advice-add 'rename-file :around #'bookmark-gt--rename-file-advice))

(defun bookmark-gt-uninstall-rename-tracker ()
  "Remove the `rename-file' tracker advice."
  (advice-remove 'rename-file #'bookmark-gt--rename-file-advice))

(defun bookmark-gt--save-filter-advice (orig-fn &rest args)
  "Around advice for `bookmark-save' that excludes temp records.
Every call binds `bookmark-alist' to a filtered copy without
records carrying `bookmark-gt-temp-key' before delegating to
ORIG-FN with ARGS.  The user's live alist is untouched — the
filter is only applied to what gets written to disk."
  (let ((bookmark-alist
         (seq-remove #'bookmark-gt-temp-p bookmark-alist)))
    (apply orig-fn args)))

(defun bookmark-gt-install-temp-save-filter ()
  "Install the temp-bookmark save filter on `bookmark-save'.
Idempotent."
  (advice-add 'bookmark-save :around #'bookmark-gt--save-filter-advice))

(defun bookmark-gt-uninstall-temp-save-filter ()
  "Remove the temp-bookmark save filter."
  (advice-remove 'bookmark-save #'bookmark-gt--save-filter-advice))

;;;; Public: interactive entry point

(defun bookmark-gt-set (&optional name no-overwrite)
  "Set a bookmark like `bookmark-set', with bookmark-gt extensions.

NAME is the bookmark name.  When called interactively with NAME
nil, prompt for it using the current buffer's default.  When
called from Lisp with NAME non-nil, no prompt is shown.

NO-OVERWRITE is accepted for signature compatibility with vanilla
`bookmark-set' and IGNORED — bookmark-gt's same-name policy is
disambiguation via text properties on the stored name (see
`bookmark-gt-disambiguate-name'), not overwrite.

Runs `bookmark-gt-set-name-reader-hook',
`bookmark-gt-set-tag-reader-hook', and
`bookmark-gt-set-after-hook' in that order.

Returns the stored (NAME . DATA) pair."
  (interactive)
  (ignore no-overwrite)
  (bookmark-maybe-load-default-file)
  (let* ((raw-record (bookmark-make-record))
         (record-data (if (stringp (car raw-record))
                          (cdr raw-record)
                        raw-record))
         (suggested-name
          (or (and (stringp (car raw-record)) (car raw-record))
              (car (bookmark-prop-get raw-record 'defaults))
              (buffer-name)))
         (refined-suggested (bookmark-gt--refine-name suggested-name
                                                     record-data))
         (chosen-name
          (cond
           (name name)
           ((called-interactively-p 'any)
            (read-from-minibuffer
             (format-prompt "Set bookmark" refined-suggested)
             nil nil nil 'bookmark-history refined-suggested))
           (t refined-suggested)))
         (unique-name (bookmark-gt-disambiguate-name chosen-name))
         (tags (bookmark-gt--fold-tag-hooks record-data nil))
         (final-data (bookmark-gt--with-tags record-data tags))
         (final-name (bookmark-gt--push-record unique-name final-data))
         (stored (cons final-name final-data)))
    (run-hook-with-args 'bookmark-gt-set-after-hook stored)
    stored))

(provide 'bookmark-gt-core)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-core.el ends here
