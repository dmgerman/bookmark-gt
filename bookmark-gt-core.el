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
(declare-function bookmark-gt--dired-collect-state
                  "bookmark-gt-handlers")
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
  (when-let* ((existing (bookmark-get-bookmark name 'noerror)))
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

(defun bookmark-gt--push-record (name alist &optional no-current)
  "Push (NAME . ALIST) onto `bookmark-alist' compatibly with `bookmark-store'.
NAME's text properties are stripped, matching what the built-in
`bookmark-store' does.  Adds `created' and `last-modified'
timestamps unless ALIST already carries them (callers that
preserve historical timestamps, e.g. migration, pass their own).

With NO-CURRENT non-nil, leave `bookmark-current-bookmark'
alone.  That variable is buffer-local, and its value is the
default offered by several name prompts, so a caller that
stores records unrelated to the current buffer (a browser-tab
refresh running from a timer) must not write it.

Returns the stripped name."
  (let ((stripped (copy-sequence name))
        (now (current-time)))
    (set-text-properties 0 (length stripped) nil stripped)
    (unless (assq 'created alist)
      (setq alist (cons (cons 'created now) alist)))
    (unless (assq 'last-modified alist)
      (setq alist (cons (cons 'last-modified now) alist)))
    (push (cons stripped alist) bookmark-alist)
    (unless no-current
      (setq bookmark-current-bookmark stripped))
    (setq bookmark-alist-modification-count
          (1+ bookmark-alist-modification-count))
    (when (bookmark-time-to-save-p)
      (bookmark-save))
    stripped))

;;;; Public: elisp API

(defun bookmark-gt-set-non-file (name handler props &optional no-notify
                                      no-current)
  "Store a non-file bookmark called NAME using HANDLER.
PROPS is an alist of additional record entries (URL, page
title, etc.).  When NO-NOTIFY is non-nil, skip UI refresh and
the external `bookmark-gt-set-after-hook' — the caller is
expected to notify once at end of a batch.  When NO-CURRENT is
non-nil, leave `bookmark-current-bookmark' alone; see
`bookmark-gt--push-record'.  Returns the stored `(NAME . DATA)'
pair."
  (let* ((initial-data (cons (cons 'handler handler) props))
         (refined-name (bookmark-gt--refine-name name initial-data))
         (unique-name (bookmark-gt--resolve-collision
                       refined-name initial-data nil))
         (tags (bookmark-gt--collect-tags initial-data nil))
         (final-data (bookmark-gt--with-tags initial-data tags))
         (final-name (bookmark-gt--push-record unique-name final-data
                                              no-current))
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

;;;; Session-only record properties
;;
;; A module may attach data identifying a live object owned by
;; another process — `bookmark-gt-browser-tabs.el' stores a browser
;; tab's id and the name of its client.  Such a value is valid only
;; for the session that produced it, so it is removed when a record
;; stops being temporary and becomes eligible to be written to the
;; bookmark file.

(defvar bookmark-gt-session-only-props nil
  "Record keys that describe live session state.
A list of alist keys.  `bookmark-gt-toggle-temp' removes them
from a record when it clears the temp flag, so they are never
written to the bookmark file.  Modules that attach such data
register their keys at load time.")

(defun bookmark-gt--session-only-key-p (cell)
  "Return non-nil when alist CELL's key is registered as session-only."
  (memq (car-safe cell) bookmark-gt-session-only-props))

(defun bookmark-gt-toggle-temp (name)
  "Toggle the temp property on the bookmark called NAME.
Clearing the flag makes the record eligible for the bookmark
file, so any `bookmark-gt-session-only-props' key is removed at
the same time.  Fires `bookmark-gt-set-after-hook' so the list
buffer and any other observers refresh."
  (interactive
   (list (bookmark-completing-read "Toggle temporary"
                                   (or bookmark-current-bookmark ""))))
  (let ((record (bookmark-get-bookmark name)))
    (unless record
      (user-error "No bookmark called %S" name))
    (let ((current (bookmark-gt-temp-p record)))
      (if current
          ;; Mutated in place: `bookmark-alist' and the list
          ;; buffer both hold this record by identity.
          (setcdr record
                  (seq-remove
                   (lambda (cell)
                     (or (eq (car-safe cell) bookmark-gt-temp-key)
                         (bookmark-gt--session-only-key-p cell)))
                   (cdr record)))
        (setcdr record (cons (cons bookmark-gt-temp-key t)
                             (cdr record))))
      (bookmark-gt--after-mutation record)
      (message "%s temp on %S"
               (if current "Cleared" "Set") name))))

;;;; jump-via override
;;
;; Built-in `bookmark--jump-via' runs, in order:
;;   1. `save-window-excursion' around `bookmark-handle-bookmark',
;;      capturing the handler's final buffer + point;
;;   2. `funcall' DISPLAY-FUNCTION on that buffer;
;;   3. `set-window-point' on the displayed window;
;;   4. fringe-mark;
;;   5. `run-hooks' `bookmark-after-jump-hook';
;;   6. `bookmark-show-annotation' when
;;      `bookmark-automatically-show-annotations' is non-nil.
;;
;; This override behaves identically EXCEPT that a handler which
;; throws `bookmark-gt-skip-post-handler' suppresses only step 6.
;; Steps 2-5 always run.  This exists as an extension point for
;; third-party handlers whose target is external (a URL opened
;; via `browse-url', a browser tab focused via a bridge) and
;; whose annotation popup would move window-manager focus off the
;; external target back to Emacs.  No handler shipped in
;; bookmark-gt itself calls the macro — the mechanism is retained
;; for third-party use only.

(declare-function bookmark--set-fringe-mark "bookmark" ())

(defun bookmark-gt--jump-via-override (bookmark-name-or-record display-function)
  "Override of `bookmark--jump-via'.
Handle BOOKMARK-NAME-OR-RECORD, then call DISPLAY-FUNCTION on
the buffer left current by the handler.  Same behavior as the
built-in EXCEPT that a handler which throws
`bookmark-gt-skip-post-handler' suppresses only
`bookmark-show-annotation'; display, `set-window-point',
fringe mark, and `bookmark-after-jump-hook' all still run."
  (let (buf point skip)
    (save-window-excursion
      (setq skip (catch 'bookmark-gt-skip-post-handler
                   (bookmark-handle-bookmark bookmark-name-or-record)
                   nil))
      (setq buf (current-buffer)
            point (point)))
    (funcall display-function buf)
    (when-let* ((win (get-buffer-window buf 0)))
      (set-window-point win point))
    (when bookmark-fringe-mark
      (let ((overlays (overlays-in (pos-bol) (1+ (pos-bol))))
            temp found)
        (while (and (not found) (setq temp (pop overlays)))
          (when (eq 'bookmark (overlay-get temp 'category))
            (setq found t)))
        (unless found
          (bookmark--set-fringe-mark))))
    (run-hooks 'bookmark-after-jump-hook)
    (when (and bookmark-automatically-show-annotations (not skip))
      (bookmark-show-annotation bookmark-name-or-record))))

(defmacro bookmark-gt-skip-post-handler (value)
  "Throw VALUE to suppress this jump's annotation popup.
Extension point for third-party handlers.  A handler that calls
this at its tail prevents `bookmark-show-annotation' from
opening after the jump.  Intended for handlers whose target is
external (a browser URL, a browser tab, an OS application):
opening the annotation buffer would move window-manager focus
from the external target back to Emacs.
Does NOT skip display, `set-window-point', fringe mark, or
`bookmark-after-jump-hook'; the buffer-display flow and the
visit-tracker hook always run.  Safe to call when the enclosing
override is not installed — a `no-catch' signal is swallowed.
No handler shipped with bookmark-gt calls this macro."
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
;; Optimized single-file refresh: after-hook runs with a
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
time) go here after `bookmark-after-jump-hook' runs, so
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
          (when-let* ((ov (bookmark-gt-highlight--make-overlay rec)))
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
;; `bookmark-gt--on-jump-restore-region' (called from
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
;; Wiring: `bookmark-after-jump-hook' runs
;; `bookmark-gt--on-jump-record-visit' after every jump.  Under
;; `bookmark-gt--jump-via-override' the after-jump-hook always
;; runs, so handlers do not need to call
;; `bookmark-gt-record-visit' themselves.
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
runs).  Runs on every jump under
`bookmark-gt--jump-via-override'."
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

;;;; Auto-temp on store for known transient names
;;
;; Some third-party code stores bookmarks under fixed names that
;; are transient by design (`org-capture-last-stored', updated on
;; every capture; similar patterns exist for other packages).
;; Persisting them clutters the bookmark file with a moving
;; target.  This advice marks such records temp at store time,
;; so the save filter excludes them.

(defcustom bookmark-gt-auto-temp-names
  '("\\`org-capture-last-stored\\'")
  "Bookmark names (regexps) auto-marked temporary on store.
Each element is a regexp matched against the stored name.
When any regexp matches, `bookmark-gt-temp-key' is set on the
record so `bookmark-save' skips it via the temp filter.

Default entry covers `org-capture-last-stored', the bookmark
`org-capture' re-stores on every capture."
  :type '(repeat regexp)
  :group 'bookmark-gt)

(defun bookmark-gt--auto-temp-advice (name &rest _)
  "Mark NAME temp when it matches `bookmark-gt-auto-temp-names'.
Attached as `:after' advice on `bookmark-store' so the record
is marked immediately after storage."
  (when (and (stringp name)
             (seq-some (lambda (pat) (string-match-p pat name))
                       bookmark-gt-auto-temp-names))
    (when-let* ((rec (bookmark-get-bookmark name 'noerror)))
      (bookmark-prop-set rec bookmark-gt-temp-key t))))

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

;; NAME's sentinel distinguishes an interactive call from a Lisp
;; call passing nil.  `called-interactively-p' cannot do this
;; reliably here: invoking `bookmark-gt-set' as a transient suffix
;; (as in a `transient-define-prefix' menu) makes it return nil
;; even though the user invoked the command interactively.
;; `bookmark-gt-tags.el' hit the same issue with its tag reader
;; and moved off `called-interactively-p'; this sentinel is the
;; equivalent fix for the name prompt.
(defconst bookmark-gt--prompt-name (make-symbol "bookmark-gt--prompt-name")
  "Sentinel NAME value that requests the interactive name prompt.
`bookmark-gt-set' produces this value from its `interactive'
spec.  Lisp callers should pass a name string, or nil to accept
the suggested name without prompting.")

(defun bookmark-gt-set (&optional name no-overwrite)
  "Set a bookmark.
NAME is the bookmark name; interactive calls prompt for it with
the suggested name as editable initial input.  Lisp callers may
pass a name string, or nil to accept the suggested name without
prompting.  NO-OVERWRITE (a prefix
argument) forces disambiguation with a `<N>' suffix.  Otherwise
the same-name policy in `bookmark-gt-same-name-overwrite' and
`bookmark-gt-allow-duplicate-names' applies.  Returns the
stored (NAME . DATA) pair."
  (interactive (list bookmark-gt--prompt-name current-prefix-arg))
  (bookmark-maybe-load-default-file)
  (let* ((region-active (and bookmark-gt-use-region (use-region-p)))
         ;; `bookmark-make-record' names the record after
         ;; `bookmark-current-bookmark' when the buffer's
         ;; `bookmark-make-record-function' supplies no name, and
         ;; lists it first under `defaults'.  That variable holds
         ;; the last bookmark jumped to or stored in this buffer,
         ;; which has nothing to do with the location being
         ;; bookmarked now, so it is bound to nil here — over the
         ;; record construction only, not over the
         ;; `bookmark-gt--push-record' call below, which is meant
         ;; to update it.
         (raw-record (let ((bookmark-current-bookmark nil))
                       (if region-active
                           ;; Capture context around region-start (not
                           ;; wherever point happens to be within the
                           ;; region) so the built-in front/rear
                           ;; context strings anchor to the region's
                           ;; beginning.
                           (save-excursion
                             (goto-char (region-beginning))
                             (bookmark-make-record))
                         (bookmark-make-record))))
         (record-data (if (stringp (car raw-record))
                          (cdr raw-record)
                        raw-record))
         (record-data (bookmark-gt--record-with-region record-data))
         ;; bookmark-gt owns the Dired handler; when setting from a
         ;; Dired buffer, force our handler so the record is
         ;; unambiguous on disk regardless of what Dired's
         ;; `bookmark-make-record-function' produced.  Also splice
         ;; in the dired state (marks, inserted/hidden subdirs, ls
         ;; switches, `dired-directory') so jumps restore what the
         ;; user saw.  Existing keys with the same name are dropped
         ;; first so re-setting an already-dired record refreshes
         ;; the captured state instead of accumulating stale copies.
         (record-data
          (if (derived-mode-p 'dired-mode)
              (let* ((state (bookmark-gt--dired-collect-state))
                     (state-keys (mapcar #'car state))
                     (stripped (seq-remove
                                (lambda (cell)
                                  (memq (car-safe cell) state-keys))
                                record-data))
                     (rehandled (cons (cons 'handler
                                            'bookmark-gt-handler-dired-jump)
                                      (assq-delete-all 'handler stripped))))
                (append rehandled state))
            record-data))
         (suggested-name
          (or (and (stringp (car raw-record)) (car raw-record))
              (car (bookmark-prop-get raw-record 'defaults))
              (buffer-name)))
         (refined-suggested (bookmark-gt--refine-name suggested-name
                                                     record-data))
         (chosen-name
          (cond
           ((eq name bookmark-gt--prompt-name)
            ;; The suggested name is inserted as editable initial
            ;; input rather than offered as a minibuffer default:
            ;; RET accepts it, point sits at its end for a small
            ;; edit, and `C-a C-k' rewrites it from scratch.  It is
            ;; passed as the default as well, so an emptied
            ;; minibuffer still yields it.
            (read-from-minibuffer
             "Set bookmark: " refined-suggested nil nil
             'bookmark-history refined-suggested))
           (name name)
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
