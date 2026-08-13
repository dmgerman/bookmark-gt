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

;; Byte-compile visibility for symbols provided by sibling modules
;; that this file calls at runtime.  `bookmark-gt.el' requires all
;; of them before use.
(declare-function bookmark-gt-list-refresh "bookmark-gt-list")
(declare-function bookmark-gt-tags-read "bookmark-gt-tags")
(declare-function bookmark-gt-default-tags--hook
                  "bookmark-gt-default-tags")
(defvar bookmark-gt-prompt-for-tags-flag)
(defvar bookmark-gt-default-tags-mode)

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
Called with one argument: the stored (NAME . DATA) pair.
Return values are ignored.")

;;;; Same-name disambiguation
;;
;; The built-in `bookmark-store' strips text properties from names and
;; built-in `bookmark-load' runs `bookmark-maybe-rename' which
;; already appends "<N>" suffixes to colliding names on load.
;; Rather than fight both, we adopt the same convention on store:
;; a bookmark whose name collides with an existing one gets stored
;; as NAME<2>, NAME<3>, and so on.  Users see the suffix in the
;; list buffer; it is the accepted convention across built-in,
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

(defcustom bookmark-gt-allow-duplicate-names t
  "Non-nil means two records may share the same literal name.
When set (which is the default), storing a bookmark whose name
already exists in `bookmark-alist' does not force a `<N>' suffix
as long as the collision is not a same-handler+same-filename
full collision (that case is still resolved by
`bookmark-gt-same-name-overwrite').

Rationale: users often want the same short name for a bookmark
in each of several files (e.g. `todo' in every project).  A
`<N>' suffix in that case is noise.  Set to nil to restore the
old behavior of always disambiguating on any name collision.

The `C-u' prefix (NO-OVERWRITE) still forces disambiguation
regardless of this flag."
  :type 'boolean
  :group 'bookmark-gt)

(defcustom bookmark-gt-same-name-overwrite t
  "Non-nil means `bookmark-gt-set' overwrites in place on a name collision.
A collision here means: an existing bookmark shares the target's
name AND handler AND filename (nil equals nil).  When this flag
is on and a collision is detected, the existing record is
replaced — the common \"update this bookmark's location\" case.
Records that share only the name (different handler or
different file) are still disambiguated with a `<N>' suffix,
so cross-source name reuse does not silently overwrite an existing record.

An explicit prefix argument to `bookmark-gt-set' (NO-OVERWRITE
non-nil) always disambiguates, ignoring this flag."
  :type 'boolean
  :group 'bookmark-gt)

(defun bookmark-gt--collision-record (name new-record)
  "Return the existing bookmark called NAME that collides with NEW-RECORD.
Two records collide when they share handler and filename (nil
equals nil; non-nil filenames compare via `file-equal-p' when
both exist, otherwise `string=').  Returns nil when no
collision."
  (when-let ((existing (bookmark-get-bookmark name 'noerror)))
    (let ((h-old (bookmark-prop-get existing 'handler))
          (h-new (alist-get 'handler new-record))
          (f-old (bookmark-prop-get existing 'filename))
          (f-new (alist-get 'filename new-record)))
      (when (and (eq h-old h-new)
                 (cond
                  ((and f-old f-new)
                   (or (string= f-old f-new)
                       (and (file-exists-p f-old)
                            (file-exists-p f-new)
                            (file-equal-p f-old f-new))))
                  ((and (null f-old) (null f-new)) t)
                  (t nil)))
        existing))))

(defun bookmark-gt--resolve-collision (name record no-overwrite)
  "Return the actual name to store RECORD under given the target NAME.
Consults `bookmark-gt-same-name-overwrite' and
`bookmark-gt-allow-duplicate-names'.  NO-OVERWRITE non-nil
forces disambiguation with a `<N>' suffix."
  (cond
   (no-overwrite (bookmark-gt-disambiguate-name name))
   ((and bookmark-gt-same-name-overwrite
         (bookmark-gt--collision-record name record))
    (setq bookmark-alist (assoc-delete-all name bookmark-alist))
    name)
   (bookmark-gt-allow-duplicate-names name)
   (t (bookmark-gt-disambiguate-name name))))

;;;; Hook runners (internal)

(defun bookmark-gt--refine-name (default-name context)
  "Run `bookmark-gt-set-name-reader-hook' and return the refined name.
Returns the first non-nil string returned by a hook, or
DEFAULT-NAME if every hook returns nil.  CONTEXT is passed to
each hook as its second argument."
  (or (run-hook-with-args-until-success
       'bookmark-gt-set-name-reader-hook default-name context)
      default-name))

(defun bookmark-gt--collect-tags (record seed-tags)
  "Return the final tag list for RECORD, starting from SEED-TAGS.
The pipeline is: default-tags contribution when
`bookmark-gt-default-tags-mode' is on, then the interactive
reader when `bookmark-gt-prompt-for-tags-flag' is non-nil,
then any third-party functions on the public
`bookmark-gt-set-tag-reader-hook'."
  (let ((tags seed-tags))
    (when bookmark-gt-default-tags-mode
      (setq tags (bookmark-gt-default-tags--hook record tags)))
    (when bookmark-gt-prompt-for-tags-flag
      (setq tags (bookmark-gt-tags-read "Tags" tags)))
    (seq-reduce (lambda (acc fn) (funcall fn record acc))
                bookmark-gt-set-tag-reader-hook
                tags)))

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
;; The essential built-in `bookmark-store' contract is: push the
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
  "Push (NAME . ALIST) onto `bookmark-alist' compatibly with `bookmark-store'.
NAME's text properties are stripped, matching what the built-in
`bookmark-store' does.  Adds `created' and `last-modified'
timestamps unless ALIST already carries them (callers that
preserve historical timestamps, e.g. migration, pass their own).
Returns the stripped name."
  (let ((stripped (copy-sequence name))
        (now (current-time)))
    (set-text-properties 0 (length stripped) nil stripped)
    (unless (assq 'created alist)
      (setq alist (cons (cons 'created now) alist)))
    (unless (assq 'last-modified alist)
      (setq alist (cons (cons 'last-modified now) alist)))
    (push (cons stripped alist) bookmark-alist)
    (setq bookmark-current-bookmark stripped)
    (setq bookmark-alist-modification-count
          (1+ bookmark-alist-modification-count))
    (when (bookmark-time-to-save-p)
      (bookmark-save))
    stripped))

;;;; Public: elisp API

(defun bookmark-gt-set-non-file (name handler props &optional no-notify)
  "Store a non-file bookmark called NAME using HANDLER.
PROPS is an alist of additional record entries (URL, page
title, etc.).  When NO-NOTIFY is non-nil, skip UI refresh and
the external `bookmark-gt-set-after-hook' — the caller is
expected to notify once at end of a batch.  Returns the
stored `(NAME . DATA)' pair."
  (let* ((initial-data (cons (cons 'handler handler) props))
         (refined-name (bookmark-gt--refine-name name initial-data))
         (unique-name (bookmark-gt--resolve-collision
                       refined-name initial-data nil))
         (tags (bookmark-gt--collect-tags initial-data nil))
         (final-data (bookmark-gt--with-tags initial-data tags))
         (final-name (bookmark-gt--push-record unique-name final-data))
         (stored (cons final-name final-data)))
    (unless no-notify
      (bookmark-gt--after-mutation stored))
    stored))

;;;; Temporary bookmarks
;;
;; A record carrying the `bmkp-temp' alist key is a temp bookmark:
;; visible in `bookmark-alist' for the life of the Emacs session,
;; excluded from `bookmark-save' output.  Same key name as
;; bookmark+'s `bmkp-temp' so bookmark files round-trip either way.
;;
;; The save filter is installed via advice on `bookmark-save' —
;; `bookmark.el' has no extension hook there.  Install / uninstall is
;; controlled by `bookmark-gt-mode' so a user who never enables it
;; sees the built-in behavior unchanged.

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
      (bookmark-gt--after-mutation record)
      (message "%s temp on %S"
               (if current "Cleared" "Set") name))))

;;;; jump-via catch tag
;;
;; The built-in `bookmark--jump-via' calls the handler, then unconditionally
;; runs `bookmark-after-jump-hook' and (if
;; `bookmark-automatically-show-annotations' is non-nil) pops up the
;; annotation buffer.  For handlers whose target is external — a
;; web browser opened via `browse-url', a browser tab focused via
;; browsel — the annotation buffer moves focus from the
;; browser back to Emacs, which is not what the user wants.
;;
;; The handler cannot let-bind
;; `bookmark-automatically-show-annotations' to nil because the
;; check happens after the handler returns and the let has unwound.
;;
;; Bookmark+ solves this by redefining `bookmark--jump-via' with a
;; `(catch 'bookmark--jump-via ...)' around the body; handlers
;; then throw to skip everything after step 2.  We do the same
;; less intrusively via `:around' advice that wraps the built-in
;; body in our own catch tag; handlers throw
;; `bookmark-gt-skip-post-handler' to opt out.
;;
;; The install/uninstall pair is wired to `bookmark-gt-mode' so
;; a user who never enables the package sees the built-in
;; behavior.  Handlers wrap their throw in a `condition-case' /
;; `no-catch' shim so a throw when the advice is not installed
;; silently degrades to a no-op.

(defun bookmark-gt--jump-via-catch-advice (orig-fn &rest args)
  "Wrap ORIG-FN (called with ARGS) in a `bookmark-gt-skip-post-handler' catch.
Handlers throw that tag to bail out of the post-handler steps
that built-in `bookmark--jump-via' runs (annotation buffer,
`bookmark-after-jump-hook', fringe mark)."
  (catch 'bookmark-gt-skip-post-handler
    (apply orig-fn args)))

(defmacro bookmark-gt-skip-post-handler (value)
  "Throw VALUE to the catch tag `bookmark-gt-skip-post-handler'.
Handlers use this at their tail to abort the built-in post-
handler steps (annotation buffer, hooks, fringe mark) for the
current jump.  Safe to call even when the catch is not
installed: a `no-catch' error is silently swallowed by the
surrounding `condition-case'."
  `(condition-case nil
       (throw 'bookmark-gt-skip-post-handler ,value)
     (no-catch nil)))

;;;; Per-bookmark highlighting
;;
;; Every file bookmark that points at the visited file gets an
;; overlay showing its position (or its region, if the record has
;; `end-position').  Overlays are refreshed when a buffer is
;; visited (`find-file-hook') and when a bookmark mutates
;; (`bookmark-gt-set-after-hook').  Mode-off removes them.
;;
;; Optimized single-file refresh: after-hook fires with a
;; specific record → only the buffer visiting that record's file
;; is refreshed.  Full sweep only for the `nil' sentinel (batch
;; operations, unknown provenance).
;;
;; Overlays live in a buffer-local list so they die with the
;; buffer.  Nothing on disk; no records-only-invariant impact —
;; overlays are process-scoped display state (category 3).

(defcustom bookmark-gt-highlight-enable t
  "Non-nil: highlight file-bookmarks in their visited buffers.
An overlay is added at each bookmark's position (or spanning
its region) when the file is opened, refreshed on any
mutation, and removed when the mode turns off."
  :type 'boolean
  :group 'bookmark-gt)

(defface bookmark-gt-face-highlight
  '((t :inherit hl-line))
  "Overlay face for bookmarks in file-visiting buffers.
Applied per bookmark; region bookmarks span the full region,
point bookmarks span the containing line."
  :group 'bookmark-gt)

(defvar-local bookmark-gt-highlight--overlays nil
  "Buffer-local list of overlays created by the highlighter.
Overlays die with the buffer; the list can go stale on kill
but stale entries are ignored on next refresh.")

(defvar-local bookmark-gt-highlight--jumped-positions nil
  "Buffer-local hash: record cons → integer point after a jump.
Records without a numeric `position' (e.g. org-heading
bookmarks whose location is resolved by the handler at jump
time) go here after `bookmark-after-jump-hook' fires, so
subsequent refreshes still overlay them.")

(defun bookmark-gt-highlight--effective-position (record)
  "Return the position at which to overlay RECORD in this buffer.
Prefers the record's numeric `position'; falls back to a
post-jump position recorded in
`bookmark-gt-highlight--jumped-positions'.  Returns nil when
neither is available."
  (let ((p (bookmark-prop-get record 'position)))
    (cond
     ((numberp p) p)
     ((and bookmark-gt-highlight--jumped-positions
           (gethash record bookmark-gt-highlight--jumped-positions)))
     (t nil))))

(defun bookmark-gt-highlight--make-overlay (record)
  "Create and return a highlight overlay for RECORD in the current buffer.
Returns nil when the record has neither a numeric `position'
nor a post-jump recorded position."
  (let ((pos (bookmark-gt-highlight--effective-position record)))
    (when (numberp pos)
      (let* ((end (or (bookmark-prop-get record 'end-position) pos))
             (start (save-excursion
                      (goto-char (max (point-min)
                                      (min pos (point-max))))
                      (line-beginning-position)))
             (finish (save-excursion
                       (goto-char (max (point-min)
                                       (min end (point-max))))
                       (line-end-position)))
             (ov (make-overlay start finish nil t nil)))
        (overlay-put ov 'face 'bookmark-gt-face-highlight)
        (overlay-put ov 'bookmark-gt-highlight t)
        (overlay-put ov 'help-echo
                     (format "bookmark-gt: %s"
                             (bookmark-gt-display-name (car record))))
        ov))))

(defun bookmark-gt-highlight--clear-buffer ()
  "Remove every bookmark-gt highlight overlay from the current buffer."
  (dolist (ov bookmark-gt-highlight--overlays)
    (when (overlayp ov) (delete-overlay ov)))
  (setq bookmark-gt-highlight--overlays nil))

(defun bookmark-gt-highlight--refresh-buffer ()
  "Rebuild highlight overlays for the current buffer.
Iterate `bookmark-alist' for records whose `filename' resolves
to the buffer's file (via `file-equal-p') and create one
overlay per match."
  (bookmark-gt-highlight--clear-buffer)
  (when-let* ((bookmark-gt-highlight-enable)
              (path (buffer-file-name)))
    (dolist (rec bookmark-alist)
      (let ((f (bookmark-gt-filename-of rec)))
        (when (and f
                   (not (file-remote-p f))
                   (file-exists-p f)
                   (file-equal-p f path))
          (when-let ((ov (bookmark-gt-highlight--make-overlay rec)))
            (push ov bookmark-gt-highlight--overlays)))))))

(defun bookmark-gt-highlight--refresh-all-visible ()
  "Rebuild the highlight overlays of every live file-visiting buffer."
  (dolist (buf (buffer-list))
    (when (buffer-file-name buf)
      (with-current-buffer buf
        (bookmark-gt-highlight--refresh-buffer)))))

(defun bookmark-gt-highlight--on-find-file ()
  "Refresh highlight overlays for the just-opened buffer."
  (bookmark-gt-highlight--refresh-buffer))

(defun bookmark-gt-highlight--on-jump ()
  "Record the point after a jump and refresh the buffer's overlays.
Lets records without a numeric `position' (e.g. org-heading
bookmarks) still get an overlay at their landed position."
  (when-let* ((bookmark-gt-highlight-enable)
              (name bookmark-current-bookmark)
              (rec (bookmark-get-bookmark name 'noerror)))
    (unless bookmark-gt-highlight--jumped-positions
      (setq bookmark-gt-highlight--jumped-positions
            (make-hash-table :test 'eq)))
    (puthash rec (point) bookmark-gt-highlight--jumped-positions)
    (bookmark-gt-highlight--refresh-buffer)))

(defun bookmark-gt-highlight-refresh (entry)
  "Refresh the buffer visiting ENTRY's file, if any."
  (when-let* ((bookmark-gt-highlight-enable)
              (entry)
              (path (bookmark-gt-filename-of entry))
              (buf (find-buffer-visiting path)))
    (with-current-buffer buf
      (bookmark-gt-highlight--refresh-buffer))))

(defun bookmark-gt-highlight--clear-all-visible ()
  "Remove every bookmark-gt highlight overlay from every buffer."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when bookmark-gt-highlight--overlays
        (bookmark-gt-highlight--clear-buffer)))))

;;;; Mutation notification
;;
;; Called directly by every internal mutator.  Refreshes list
;; buffers and highlight overlays, then runs the public
;; `bookmark-gt-set-after-hook' for third-party observers.

(defun bookmark-gt--after-mutation (entry)
  "Notify UI observers that ENTRY was created or mutated.
Stamps `last-modified' on ENTRY when it names a specific
record, refreshes list buffers and highlight overlays, then
runs the public `bookmark-gt-set-after-hook'."
  (when (and (consp entry) (stringp (car entry)))
    (bookmark-prop-set entry 'last-modified (current-time)))
  (bookmark-gt-list-refresh)
  (bookmark-gt-highlight-refresh entry)
  (run-hook-with-args 'bookmark-gt-set-after-hook entry))

;;;; In-buffer cycling
;;
;; `bookmark-gt-cycle-next' / `-prev' walk the bookmarks that
;; live in the current buffer's file, in position order.  Wrap
;; around at the ends.  Purely record-driven — nothing looks at
;; the highlight overlays, so cycling works even with
;; `bookmark-gt-highlight-enable' set to nil.

(defun bookmark-gt--current-file-entries ()
  "Return a list of (POSITION . NAME) for bookmarks in this buffer's file.
Sorted by POSITION ascending.  Only local, existing files are
considered.  Records without a numeric `position' are skipped."
  (let ((path (buffer-file-name)))
    (when path
      (sort
       (delq nil
             (mapcar
              (lambda (rec)
                (let ((f (bookmark-gt-filename-of rec))
                      (p (bookmark-prop-get rec 'position)))
                  (and f (numberp p)
                       (not (file-remote-p f))
                       (file-exists-p f)
                       (file-equal-p f path)
                       (cons p (bookmark-gt-display-name (car rec))))))
              bookmark-alist))
       (lambda (a b) (< (car a) (car b)))))))

(defun bookmark-gt--cycle-to (entry)
  "Go to ENTRY's position and message its name.
ENTRY is a (POSITION . NAME) pair as returned by
`bookmark-gt--current-file-entries'."
  (goto-char (car entry))
  (message "Bookmark: %s" (cdr entry)))

;;;###autoload
(defun bookmark-gt-cycle-next ()
  "Move point to the next bookmark position in this buffer.
Bookmarks are those in `bookmark-alist' whose `filename'
resolves to the buffer's file.  Wraps from end to start when
past the last one."
  (interactive)
  (let* ((entries (bookmark-gt--current-file-entries))
         (cur (point))
         (next (seq-find (lambda (e) (> (car e) cur)) entries)))
    (unless entries
      (user-error "No bookmarks in this file"))
    (bookmark-gt--cycle-to (or next (car entries)))))

;;;###autoload
(defun bookmark-gt-cycle-prev ()
  "Move point to the previous bookmark position in this buffer.
Wraps from start to end when before the first one."
  (interactive)
  (let* ((entries (bookmark-gt--current-file-entries))
         (cur (point))
         (before (seq-filter (lambda (e) (< (car e) cur)) entries))
         (prev (car (last before))))
    (unless entries
      (user-error "No bookmarks in this file"))
    (bookmark-gt--cycle-to (or prev (car (last entries))))))

;;;; Region bookmarks
;;
;; When `bookmark-gt-set' is called with an active region and
;; `bookmark-gt-use-region' is non-nil, the record captures both
;; region anchors plus context strings around the end.  On jump,
;; `bookmark-gt--on-jump-restore-region' (fired from
;; `bookmark-after-jump-hook') pushes the mark at the end
;; position and activates it, so the region reappears
;; highlighted.
;;
;; Alist-key names match bookmark+ (`end-position',
;; `front-context-region-string', `rear-context-region-string')
;; so bookmark files round-trip.  The built-in `bookmark.el' ignores
;; the extra keys — the record still jumps correctly there,
;; just without region restore.

(defcustom bookmark-gt-use-region t
  "Non-nil: capture and restore the active region on set/jump.
When set on `bookmark-gt-set' with an active region, the record
gains `end-position' plus context strings around it.  On
`bookmark-after-jump-hook', if a record has `end-position', the
mark is pushed there and the region is re-activated.

Turn off to store point bookmarks even when a region is
active — records that already carry region info still restore
their region on jump; this flag only gates the capture path.

To fully disable region restore, turn off `bookmark-gt-mode'."
  :type 'boolean
  :group 'bookmark-gt)

(defcustom bookmark-gt-region-context-size 40
  "Characters of context captured around a region's end.
Used by the re-anchoring logic to relocate the end position
when the buffer has been edited between save and re-jump."
  :type 'integer
  :group 'bookmark-gt)

(defun bookmark-gt--region-context-before (pos)
  "Return up to `bookmark-gt-region-context-size' chars ending at POS."
  (buffer-substring-no-properties
   (max (point-min) (- pos bookmark-gt-region-context-size)) pos))

(defun bookmark-gt--region-context-after (pos)
  "Return up to `bookmark-gt-region-context-size' chars starting at POS."
  (buffer-substring-no-properties
   pos (min (point-max) (+ pos bookmark-gt-region-context-size))))

(defun bookmark-gt--record-with-region (record-data)
  "Return RECORD-DATA augmented with region info when the region is active.
No-op when `bookmark-gt-use-region' is nil or the region is not
active.  Overrides `position' with `region-beginning' and adds
`end-position' plus the two region context strings."
  (if (not (and bookmark-gt-use-region (use-region-p)))
      record-data
    (let* ((start (region-beginning))
           (end   (region-end))
           (front (bookmark-gt--region-context-before end))
           (rear  (bookmark-gt--region-context-after end))
           (stripped (assq-delete-all
                      'position
                      (assq-delete-all
                       'end-position
                       (assq-delete-all
                        'front-context-region-string
                        (assq-delete-all
                         'rear-context-region-string
                         record-data))))))
      (append
       `((position . ,start)
         (end-position . ,end)
         (front-context-region-string . ,front)
         (rear-context-region-string . ,rear))
       stripped))))

(defun bookmark-gt--on-jump-restore-region ()
  "Hook on `bookmark-after-jump-hook' that re-activates the region.
When the just-jumped record has `end-position', push the mark
there (activated) so the region reappears highlighted.  Apply
a delta correction so context-based re-anchoring at the start
propagates to the end anchor."
  (when-let* ((bookmark-gt-use-region)
              (name bookmark-current-bookmark)
              (rec (bookmark-get-bookmark name 'noerror))
              (end-pos (bookmark-prop-get rec 'end-position))
              (raw-pos (bookmark-prop-get rec 'position)))
    (let ((delta (- (point) raw-pos)))
      (push-mark (+ end-pos delta) t t))))

;;;; Visit tracker
;;
;; Increments the `visits' count and sets `last-visited' on every
;; jump.  These two alist keys drive `bookmark-gt-jump''s
;; `:sort-by 'mru' and `:sort-by 'visits' features.
;;
;; Wiring: built-in `bookmark-after-jump-hook' fires the tracker
;; for file-typed jumps.  Handlers that throw
;; `bookmark-gt-skip-post-handler' (URL, browser-tab) call
;; `bookmark-gt-record-visit' directly at their tail because the
;; throw bypasses the after-jump-hook.
;;
;; Mutation does NOT bump `bookmark-alist-modification-count' —
;; visit tracking on every jump should not trigger an auto-save
;; per jump.  Users get MRU / visit-count sorting within the
;; session; disk persistence happens on the next explicit save.

(defun bookmark-gt-record-visit (name-or-record)
  "Increment visits and set `last-visited' on NAME-OR-RECORD.
Both alist keys are written directly onto the record — no
`modification-count' bump, so visit tracking doesn't force a
disk write per jump."
  (let* ((rec (bookmark-get-bookmark name-or-record))
         (visits (or (bookmark-prop-get rec 'visits) 0)))
    (bookmark-prop-set rec 'visits (1+ visits))
    (bookmark-prop-set rec 'last-visited (current-time))))

(defun bookmark-gt--on-jump-record-visit ()
  "Hook for `bookmark-after-jump-hook'.
Records the visit against `bookmark-current-bookmark' (set by
built-in `bookmark-handle-bookmark' before the after-jump-hook
runs).  Handlers that throw `bookmark-gt-skip-post-handler'
bypass this hook and must call `bookmark-gt-record-visit'
themselves."
  (when bookmark-current-bookmark
    (bookmark-gt-record-visit bookmark-current-bookmark)))

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
further built-in arguments.  Rewrites bookmarks whose
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

(defun bookmark-gt--save-filter-advice (orig-fn &rest args)
  "Around advice for `bookmark-save' that excludes temp records.
Every call binds `bookmark-alist' to a filtered copy without
records carrying `bookmark-gt-temp-key' before delegating to
ORIG-FN with ARGS.  The user's live alist is untouched — the
filter is only applied to what gets written to disk."
  (let ((bookmark-alist
         (seq-remove #'bookmark-gt-temp-p bookmark-alist)))
    (apply orig-fn args)))

;;;; File-type handler dispatch
;;
;; A regexp → function table consulted when jumping a file
;; bookmark.  On match, the associated function is called with
;; the whole bookmark record instead of the built-in
;; `find-file' path.  The function's contract matches a
;; standard `bookmark.el' handler (one argument, the record).
;; See `bookmark-gt-file-type-handlers'.

(defcustom bookmark-gt-file-type-handlers nil
  "Alist mapping filename regexp to a bookmark handler function.
When jumping a file bookmark whose `filename' matches one of
the regexps, the corresponding function is called with the
bookmark record and takes over the jump.  The function's
contract is the same as a standard `bookmark.el' handler: one
argument, the bookmark record; it may read any record prop —
`filename', `position', `tags', and so on.

If the function opens an external target and does not want
the built-in post-jump popup, it should end with
`(bookmark-gt-skip-post-handler \\='file-type)'.

Entries are tried in order; the first matching regexp wins."
  :type '(alist :key-type regexp :value-type function)
  :group 'bookmark-gt)

(defun bookmark-gt--file-type-handler-advice (orig-fn bookmark &rest args)
  "Around advice for `bookmark-default-handler'.
If BOOKMARK's `filename' matches an entry in
`bookmark-gt-file-type-handlers', call that entry's function
with BOOKMARK.  Otherwise delegate to ORIG-FN with ARGS."
  (let ((filename (bookmark-prop-get bookmark 'filename))
        (matched  nil))
    (when filename
      (dolist (entry bookmark-gt-file-type-handlers)
        (unless matched
          (when (string-match-p (car entry) filename)
            (setq matched (cdr entry))))))
    (if matched
        (funcall matched bookmark)
      (apply orig-fn bookmark args))))

;;;; Public: interactive entry point

(defun bookmark-gt-set (&optional name no-overwrite)
  "Set a bookmark.
NAME is the bookmark name (prompted for when nil interactively).
NO-OVERWRITE (a prefix argument) forces disambiguation with a
`<N>' suffix.  Otherwise the same-name policy in
`bookmark-gt-same-name-overwrite' and
`bookmark-gt-allow-duplicate-names' applies.  Returns the
stored (NAME . DATA) pair."
  (interactive "i\nP")
  (bookmark-maybe-load-default-file)
  (let* ((region-active (and bookmark-gt-use-region (use-region-p)))
         (raw-record (if region-active
                         ;; Capture context around region-start (not
                         ;; wherever point happens to be within the
                         ;; region) so the built-in front/rear context
                         ;; strings anchor to the region's beginning.
                         (save-excursion
                           (goto-char (region-beginning))
                           (bookmark-make-record))
                       (bookmark-make-record)))
         (record-data (if (stringp (car raw-record))
                          (cdr raw-record)
                        raw-record))
         (record-data (bookmark-gt--record-with-region record-data))
         ;; bookmark-gt owns the Dired handler; when setting from a
         ;; Dired buffer, force our handler so the record is
         ;; unambiguous on disk regardless of what Dired's
         ;; `bookmark-make-record-function' produced.
         (record-data (if (derived-mode-p 'dired-mode)
                          (cons (cons 'handler
                                      'bookmark-gt-handler-dired-jump)
                                (assq-delete-all 'handler record-data))
                        record-data))
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
         (unique-name (bookmark-gt--resolve-collision
                       chosen-name record-data no-overwrite))
         (tags (bookmark-gt--collect-tags record-data nil))
         (final-data (bookmark-gt--with-tags record-data tags))
         (final-name (bookmark-gt--push-record unique-name final-data))
         (stored (cons final-name final-data)))
    (bookmark-gt--after-mutation stored)
    stored))

;;;; Relocate
;;
;; Interactive "change where this bookmark points" command.
;; File records read a new path via `read-file-name'; records
;; carrying a `url' key read a new URL via `read-string'.
;; Position is left unchanged — the common trigger for
;; relocation is a file rename, where the offset is still valid.
;; For a genuinely different location the user can jump into
;; the new file, place point, and re-invoke `bookmark-gt-set';
;; the same-name-overwrite policy updates `position' in place.

;;;###autoload
(defun bookmark-gt-relocate (name)
  "Change the target of the bookmark called NAME.
File bookmarks prompt for a new filename with `read-file-name'
and keep the current position.  Records with a `url' key
prompt for a new URL.  Records with neither signal a
`user-error'.  Fires `bookmark-gt-set-after-hook'."
  (interactive (list (bookmark-completing-read "Relocate bookmark")))
  (let* ((entry    (bookmark-get-bookmark name))
         (filename (bookmark-prop-get entry 'filename))
         (url      (bookmark-prop-get entry 'url)))
    (cond
     (filename
      (let ((new (read-file-name
                  (format "Relocate `%s' to file: " name)
                  (file-name-directory filename)
                  filename nil (file-name-nondirectory filename))))
        (bookmark-prop-set entry 'filename (expand-file-name new))))
     (url
      (let ((new (read-string
                  (format "Relocate `%s' URL: " name) url)))
        (bookmark-prop-set entry 'url new)))
     (t
      (user-error
       "bookmark-gt-relocate: `%s' has neither `filename' nor `url'"
       name)))
    (setq bookmark-alist-modification-count
          (1+ bookmark-alist-modification-count))
    (when (bookmark-time-to-save-p)
      (bookmark-save))
    (bookmark-gt--after-mutation entry)
    entry))

(provide 'bookmark-gt-core)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-core.el ends here
