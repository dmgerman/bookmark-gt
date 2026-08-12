;;; bookmark-gt-list.el --- Bookmarks-gt list buffer  -*- lexical-binding: t; -*-

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
;; The `*Bookmarks-gt List*' buffer, implemented on top of
;; `tabulated-list-mode'.  Columns: Mark, Name, Type, Tags,
;; Location.  Sort headers, mark / flag-for-deletion / execute,
;; jump-same-window / jump-other-window, filter (`/'), edit-in-
;; place (rename / edit tags / edit annotation) all use vanilla
;; tabulated-list machinery — no advice on any other package.
;;
;; Filter registry (`bookmark-gt-filter-alist') and sort registry
;; (`bookmark-gt-sort-alist') are plain alists per
;; ai/design/registries.org.

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'tabulated-list)
(require 'bookmark-gt-core)
(require 'bookmark-gt-tags)
(require 'bookmark-gt-handlers)

;;;; Customization

(defcustom bookmark-gt-list-name-width 32
  "Width of the Name column in the bookmark list buffer."
  :type 'integer
  :group 'bookmark-gt)

(defcustom bookmark-gt-list-type-width 12
  "Width of the Type column in the bookmark list buffer."
  :type 'integer
  :group 'bookmark-gt)

(defcustom bookmark-gt-list-tags-width 24
  "Width of the Tags column in the bookmark list buffer."
  :type 'integer
  :group 'bookmark-gt)

(defcustom bookmark-gt-list-group-width 6
  "Width of the Group column in the bookmark list buffer."
  :type 'integer
  :group 'bookmark-gt)

(defcustom bookmark-gt-list-buffer-name "*Bookmarks-gt List*"
  "Name of the bookmark list buffer."
  :type 'string
  :group 'bookmark-gt)

(defcustom bookmark-gt-list-deletion-mark ?D
  "Character shown for bookmarks queued for deletion."
  :type 'character
  :group 'bookmark-gt)

(defcustom bookmark-gt-list-selection-mark ?*
  "Character used to select a bookmark for bulk actions."
  :type 'character
  :group 'bookmark-gt)

;;;; Filter registry

(defvar bookmark-gt-filter-alist nil
  "Filter registry for the bookmark list buffer.
Each entry is (KEY :name STRING :reader FN :predicate FN :doc STRING).
The :reader takes no arguments and returns whatever argument
:predicate needs; :predicate is called as (RECORD ARG) and
returns non-nil to include RECORD.")

;;;; Sort registry

(defvar bookmark-gt-sort-alist nil
  "Sort registry.
Each entry is (KEY :name STRING :comparator FN :doc STRING).
:comparator takes two records and returns non-nil when the
first should sort before the second.")

;;;; Buffer-local state
;;
;; All buffer-local variables listed in
;; ai/design/records-only-allowlist as category 3 (process-scoped
;; resource — bounded to the buffer's lifetime, cleared on
;; buffer kill).

(defvar-local bookmark-gt-list--filters nil
  "Alist of active filters in this buffer ((KEY . ARG) ...).")

(defvar-local bookmark-gt-list--marks nil
  "Hash table id → mark character for the current buffer.
Keys are record conses from `bookmark-alist' (compared with
`eq').  Values are the mark char (`bookmark-gt-list-selection-mark'
or `bookmark-gt-list-deletion-mark').  Missing key = unmarked.

Persists across `tabulated-list-print' — the mark column is
populated by reading this hash at render time.  Interactive
mark commands mutate the hash and patch buffer character 0
directly for speed.")

;;;; Rendering

(defun bookmark-gt-list--render-tags (record)
  "Return a display string for RECORD's tags, truncated to fit."
  (let* ((tags (bookmark-gt-tags-of record))
         (joined (mapconcat #'identity tags ", ")))
    (truncate-string-to-width joined bookmark-gt-list-tags-width nil nil t)))

(defun bookmark-gt-list--render-location (record)
  "Return a display string for RECORD's location.
Reads via `bookmark-gt-filename-of' (which treats the bookmark+
placeholder as absent) and `bookmark-gt-url-of' (which accepts
both `url' and `location' props)."
  (or (bookmark-gt-filename-of record)
      (bookmark-gt-url-of record)
      ""))

(defun bookmark-gt-list--auto-update-glyph (record)
  "Return \"^\" when RECORD carries the `auto-update' property, else \" \"."
  (if (bookmark-prop-get record 'auto-update) "^" " "))

(defun bookmark-gt-list--temp-glyph (record)
  "Return \"t\" when RECORD is a temporary bookmark, else \" \".
The check reads `bookmark-gt-temp-key' directly so the column
lights up for records created by either bookmark-gt or the old
bookmark+ package (both use the `bmkp-temp' alist key)."
  (if (bookmark-prop-get record bookmark-gt-temp-key) "t" " "))

(defun bookmark-gt-list--missing-file-p (record)
  "Return non-nil when RECORD has a `filename' but no file exists there.
Remote (Tramp) filenames are skipped — probing them would
require a network round-trip, too slow for a list render."
  (let ((f (bookmark-gt-filename-of record)))
    (and f
         (not (file-remote-p f))
         (not (file-exists-p f)))))

(defun bookmark-gt-list--name-faces (record)
  "Return the face (or `face-list') to apply to RECORD's Name column.
Composes the type face from the handler registry with
`bookmark-gt-face-missing-file' when the record's file is
absent.  Returns nil when no face applies."
  (let ((type-face (bookmark-gt-handler-face record))
        (missing-p (bookmark-gt-list--missing-file-p record)))
    (cond
     ((and type-face missing-p) (list 'bookmark-gt-face-missing-file
                                      type-face))
     (missing-p                 'bookmark-gt-face-missing-file)
     (type-face                 type-face)
     (t                         nil))))

(defun bookmark-gt-list--mark-string (record)
  "Return RECORD's mark as a 1-char string.
Looks up the buffer-local hash `bookmark-gt-list--marks'; when
no mark is stored, returns a single space."
  (let ((ch (and bookmark-gt-list--marks
                 (gethash record bookmark-gt-list--marks))))
    (if ch (char-to-string ch) " ")))

(defun bookmark-gt-list--entry-vector (record)
  "Return the tabulated-list vector for RECORD.
Name, Type, and Group are truncated via `truncate-string-to-width',
which uses `string-width' internally so wide characters (CJK,
emoji) are counted correctly.  `tabulated-list-mode' itself only
pads short values — it does not truncate long ones, so long
names would overflow into subsequent columns without our
intervention.

The mark cell (index 0) is read from
`bookmark-gt-list--marks' so marks survive re-render (sort,
revert, mutation) as long as the record cons is still in
`bookmark-alist'."
  (let* ((raw-name (bookmark-gt-display-name (car record)))
         (name (truncate-string-to-width raw-name
                                         bookmark-gt-list-name-width
                                         nil nil t))
         (raw-type (bookmark-gt-handler-name record))
         (type (truncate-string-to-width raw-type
                                         bookmark-gt-list-type-width
                                         nil nil t))
         (raw-group (bookmark-gt-group-name
                     (bookmark-gt-handler-group record)))
         (group (propertize
                 (truncate-string-to-width (or raw-group "")
                                           bookmark-gt-list-group-width
                                           nil nil t)
                 'face 'bookmark-gt-face-group))
         (faces (bookmark-gt-list--name-faces record)))
    (vector (bookmark-gt-list--mark-string record)
            (bookmark-gt-list--auto-update-glyph record)
            (bookmark-gt-list--temp-glyph record)
            (if faces (propertize name 'face faces) name)
            type
            group
            (bookmark-gt-list--render-tags record)
            (bookmark-gt-list--render-location record))))

(defun bookmark-gt-list--apply-filters (records)
  "Return RECORDS narrowed by every filter in `bookmark-gt-list--filters'."
  (seq-filter
   (lambda (record)
     (seq-every-p
      (lambda (filter)
        (let* ((entry (alist-get (car filter) bookmark-gt-filter-alist))
               (predicate (plist-get entry :predicate)))
          (or (null predicate)
              (funcall predicate record (cdr filter)))))
      bookmark-gt-list--filters))
   records))

(defun bookmark-gt-list--entries ()
  "Compute `tabulated-list-entries' for the current buffer.
Records are filtered by `bookmark-gt-list--filters'; the record
itself is used as the tabulated-list ID so mutations survive
sorting."
  (mapcar (lambda (record)
            (list record (bookmark-gt-list--entry-vector record)))
          (bookmark-gt-list--apply-filters bookmark-alist)))

;;;; Mode + keymap

(defvar-keymap bookmark-gt-list-mode-map
  :doc "Keymap for `bookmark-gt-list-mode'."
  :parent tabulated-list-mode-map
  "RET"   #'bookmark-gt-list-jump
  "o"     #'bookmark-gt-list-jump-other-window
  "C-o"   #'bookmark-gt-list-jump-other-window
  "TAB"   #'bookmark-gt-list-preview
  "^"     #'bookmark-gt-list-auto-update-toggle
  "T"   #'bookmark-gt-list-temp-toggle
  "i"   #'bookmark-gt-list-describe-record
  "s"   #'bookmark-gt-list-sort-cycle
  "m"   #'bookmark-gt-list-mark
  "u"   #'bookmark-gt-list-unmark
  "U"   #'bookmark-gt-list-unmark-all
  "d"   #'bookmark-gt-list-flag-for-deletion
  "x"   #'bookmark-gt-list-execute-deletions
  "r"   #'bookmark-gt-list-rename
  "R"   #'bookmark-gt-list-relocate
  "t"   #'bookmark-gt-list-edit-tags
  "a"   #'bookmark-gt-list-edit-annotation
  "/"   #'bookmark-gt-list-filter-by
  "g"   #'revert-buffer
  "q"   #'quit-window)

(define-derived-mode bookmark-gt-list-mode tabulated-list-mode "Bookmarks-gt"
  "Major mode for the bookmark-gt list buffer.

Each row shows one bookmark record from `bookmark-alist',
possibly narrowed by any filter active in
`bookmark-gt-list--filters'.  Click a column header (or press
`S') to sort by that column; \\[bookmark-gt-list-sort-cycle]
cycles the sort column to the next sortable one.

Marker columns (three single-character indicators before Name):

  \" \"   Selection / deletion mark, set by:
          \\[bookmark-gt-list-mark]  select for a bulk action (shown as `*')
          \\[bookmark-gt-list-flag-for-deletion]  flag for deletion   (shown as `D')
          \\[bookmark-gt-list-unmark]  clear one mark
          \\[bookmark-gt-list-unmark-all]  clear all marks
          \\[bookmark-gt-list-execute-deletions]  execute pending deletions

  \"^\"   Auto-update indicator.  Lit when the record carries
        the `auto-update' alist key.  Under
        `bookmark-gt-auto-update-mode' the record's position is
        refreshed to the visiting buffer's point on every idle
        tick.  Toggle with \\[bookmark-gt-list-auto-update-toggle].

  \"t\"   Temporary indicator.  Lit when the record carries the
        `bmkp-temp' alist key.  Temp records are visible in
        this buffer but excluded from `bookmark-save' output.
        Toggle with \\[bookmark-gt-list-temp-toggle].

Jump: \\[bookmark-gt-list-jump] jumps in the same window,
\\[bookmark-gt-list-jump-other-window] in another window,
\\[bookmark-gt-list-preview] previews in another window without
leaving the list.

Inspect: \\[bookmark-gt-list-describe-record] displays the raw
record's alist in a popup for debugging.

Edit in place: \\[bookmark-gt-list-rename] rename,
\\[bookmark-gt-list-relocate] relocate (change filename or URL),
\\[bookmark-gt-list-edit-tags] edit tags,
\\[bookmark-gt-list-edit-annotation] edit annotation.

Filter: \\[bookmark-gt-list-filter-by] then choose a
predicate (`by-type', `by-tag', `by-name-regexp', or
`unfilter').

\\{bookmark-gt-list-mode-map}"
  (setq tabulated-list-format
        `[("*"  1 bookmark-gt-list--sort-by-mark)
          ("^"  1 ,(bookmark-gt-list--sort-by-record-flag 'auto-update))
          ("t"  1 ,(bookmark-gt-list--sort-by-record-flag
                    bookmark-gt-temp-key))
          ("Name"     ,bookmark-gt-list-name-width t)
          ("Type"     ,bookmark-gt-list-type-width t)
          ("Group"    ,bookmark-gt-list-group-width
                      bookmark-gt-list--sort-by-group)
          ("Tags"     ,bookmark-gt-list-tags-width t)
          ("Location" 0 t)])
  ;; No padding: column 0 IS the mark column now.  The mark char
  ;; lands at buffer position 0 of each row and aligns exactly with
  ;; the "*" header.
  (setq tabulated-list-padding 0)
  (setq bookmark-gt-list--marks (make-hash-table :test #'eq))
  (setq tabulated-list-sort-key '("Name" . nil))
  (setq tabulated-list-entries #'bookmark-gt-list--entries)
  (setq-local revert-buffer-function #'bookmark-gt-list--revert)
  (tabulated-list-init-header)
  (add-hook 'bookmark-gt-set-after-hook
            #'bookmark-gt-list--refresh-observer))

;;;; Auto-refresh observer
;;
;; Registered globally into `bookmark-gt-set-after-hook' (idempotent
;; via `add-hook').  Any live list buffer refreshes whenever any
;; mutator fires the hook.

(defun bookmark-gt-list--name-at-point ()
  "Return the visible name of the record at point, or nil."
  (when-let ((rec (tabulated-list-get-id)))
    (bookmark-gt-display-name (car rec))))

(defun bookmark-gt-list--goto-name (name)
  "Move point to the first row whose visible name equals NAME.
No-op when NAME is nil; falls back to `point-min' when no row
matches."
  (when name
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not (eobp)) (not found))
        (let ((rec (tabulated-list-get-id)))
          (if (and rec
                   (equal (bookmark-gt-display-name (car rec)) name))
              (setq found t)
            (forward-line 1))))
      (unless found (goto-char (point-min))))))

(defun bookmark-gt-list--redraw-preserving-point ()
  "`tabulated-list-print t' with two preservation fallbacks.

1. Id-based point preservation via `tabulated-list-print's own
   REMEMBER-POS.  Fails when a refresh replaces the cons under
   point (browser-tab refetch, execute-deletions of the record
   at point, etc.).

2. Name-based point fallback: if the id lookup failed, walk to
   the first row rendering the previous name.

3. Visual-line preservation: capture the row's offset from
   `window-start' before redraw, restore via `recenter' after.
   Without this, rows added or removed above point cause the
   buffer to shift visually under the (id-preserved) cursor.

All three preservations are per-buffer; a buffer without a
live window skips the visual restore."
  (let* ((win (get-buffer-window (current-buffer)))
         (visual-line (and win
                           (count-lines (window-start win)
                                        (line-beginning-position))))
         (old-name (bookmark-gt-list--name-at-point)))
    (tabulated-list-print t)
    (unless (tabulated-list-get-id)
      (bookmark-gt-list--goto-name old-name))
    (when (and win visual-line
               (window-live-p win))
      (with-selected-window win
        (recenter visual-line)))))

(defun bookmark-gt-list--refresh-observer (&rest _)
  "Refresh every live `bookmark-gt-list-mode' buffer.
Invoked from `bookmark-gt-set-after-hook' so any mutation of the
alist \(create, rename, edit tags, delete) updates the display
without manual polling.  A full redraw is used because the
record cons is the tabulated-list ID and mutations happen in
place \(same ID, changed content), which the differential-update
path would skip.  Uses `bookmark-gt-list--redraw-preserving-point'
so point survives cons replacements."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'bookmark-gt-list-mode)
        (let ((inhibit-read-only t))
          (bookmark-gt-list--redraw-preserving-point))))))

;;;; Interactive entry point

;;;###autoload
(defun bookmark-gt-list ()
  "Display the bookmark-gt list buffer.
Fires `bookmark-gt-ephemeral-refresh-hook' before the initial
render so transient sources (browser tabs, auto-update targets)
show current state."
  (interactive)
  (bookmark-maybe-load-default-file)
  (bookmark-gt-refresh-ephemeral)
  (let ((buf (get-buffer-create bookmark-gt-list-buffer-name)))
    (with-current-buffer buf
      (bookmark-gt-list-mode)
      (tabulated-list-print))
    (pop-to-buffer-same-window buf)))

(defun bookmark-gt-list--revert (&rest _args)
  "Revert function for the bookmark-gt list buffer.
Runs `bookmark-gt-refresh-ephemeral' before re-rendering so
`g' picks up fresh browser tabs, refreshed auto-update
positions, and any other transient state.  Preserves point
across the redraw via
`bookmark-gt-list--redraw-preserving-point'."
  (bookmark-gt-refresh-ephemeral)
  (bookmark-gt-list--redraw-preserving-point))

;;;; Cursor → record lookup

(defun bookmark-gt-list--record-at-point ()
  "Return the bookmark record on the current line, or nil."
  (tabulated-list-get-id))

(defun bookmark-gt-list--require-record ()
  "Return the record on the current line, signalling if none."
  (or (bookmark-gt-list--record-at-point)
      (user-error "No bookmark on this line")))

;;;; Marks
;;
;; Selection marks live in `bookmark-gt-list--marks' (buffer-local
;; hash: id → char).  Interactive commands mutate the hash and
;; patch character 0 of the current buffer line directly for speed;
;; re-renders (sort, revert) read the hash to populate cell 0 of
;; the entry vector, so marks survive them.

(defun bookmark-gt-list--set-mark-at-point (char)
  "Store CHAR as the mark for the record at point.
CHAR = ?\\s clears the mark (removes the hash entry).  The
buffer's first character on the current line is patched
directly so the display updates without a full re-render.

The replacement preserves the `tabulated-list-id' and
`tabulated-list-entry' text properties on char 0 — without
this, `tabulated-list-get-id' on a marked row would return
nil."
  (let ((id (tabulated-list-get-id)))
    (when id
      (if (eq char ?\s)
          (remhash id bookmark-gt-list--marks)
        (puthash id char bookmark-gt-list--marks))
      (save-excursion
        (beginning-of-line)
        (let ((inhibit-read-only t)
              (props (text-properties-at (point))))
          (delete-char 1)
          (insert (apply #'propertize (string char) props)))))))

(defun bookmark-gt-list--mark-forward (char arg)
  "Set CHAR as the mark for the next ARG rows starting here.
Moves point forward one line per row marked.  Negative ARG
walks backward."
  (let* ((n (abs (or arg 1)))
         (step (if (and arg (< arg 0)) -1 1)))
    (dotimes (_ n)
      (when (tabulated-list-get-id)
        (bookmark-gt-list--set-mark-at-point char))
      (forward-line step))))

(defun bookmark-gt-list-mark (&optional arg)
  "Mark the current bookmark and move down ARG lines (default 1)."
  (interactive "p" bookmark-gt-list-mode)
  (bookmark-gt-list--mark-forward bookmark-gt-list-selection-mark
                                  (or arg 1)))

(defun bookmark-gt-list-flag-for-deletion (&optional arg)
  "Flag the current bookmark for deletion and move down ARG lines."
  (interactive "p" bookmark-gt-list-mode)
  (bookmark-gt-list--mark-forward bookmark-gt-list-deletion-mark
                                  (or arg 1)))

(defun bookmark-gt-list-unmark (&optional arg)
  "Remove any mark from the current bookmark and move down ARG lines."
  (interactive "p" bookmark-gt-list-mode)
  (bookmark-gt-list--mark-forward ?\s (or arg 1)))

(defun bookmark-gt-list-unmark-all ()
  "Remove every mark from the buffer."
  (interactive nil bookmark-gt-list-mode)
  (clrhash bookmark-gt-list--marks)
  (tabulated-list-print t))

(defun bookmark-gt-list--collect-marked (char)
  "Return records whose stored mark equals CHAR.
Skips hash entries whose id is no longer in `bookmark-alist'
\(stale from a since-deleted record)."
  (let (records)
    (maphash (lambda (id mark)
               (when (and (eq mark char)
                          (memq id bookmark-alist))
                 (push id records)))
             bookmark-gt-list--marks)
    records))

(defun bookmark-gt-list-execute-deletions ()
  "Delete every bookmark flagged with `bookmark-gt-list-deletion-mark'.
Visual position of point is preserved by
`bookmark-gt-list--redraw-preserving-point' when the observer
runs the refresh."
  (interactive nil bookmark-gt-list-mode)
  (let ((flagged (bookmark-gt-list--collect-marked
                  bookmark-gt-list-deletion-mark)))
    (unless flagged
      (user-error "No bookmarks flagged for deletion"))
    (unless (yes-or-no-p (format "Delete %d bookmark(s)? "
                                 (length flagged)))
      (user-error "Aborted"))
    (dolist (record flagged)
      (bookmark-delete (car record) t)
      (remhash record bookmark-gt-list--marks))
    (run-hook-with-args 'bookmark-gt-set-after-hook (car flagged))
    (message "Deleted %d bookmark(s)" (length flagged))))

;;;; Jump

(defun bookmark-gt-list-jump ()
  "Jump to the bookmark on the current line."
  (interactive nil bookmark-gt-list-mode)
  (let ((record (bookmark-gt-list--require-record)))
    (bookmark-jump (car record))))

(defun bookmark-gt-list-jump-other-window ()
  "Jump to the bookmark on the current line in another window."
  (interactive nil bookmark-gt-list-mode)
  (let ((record (bookmark-gt-list--require-record)))
    (bookmark-jump-other-window (car record))))

(defun bookmark-gt-list-preview ()
  "Preview the bookmark on the current line in another window.
When the record's handler registry entry carries a `:preview'
function, that function is called with the record — a chance to
provide a lightweight or non-focus-stealing rendering (e.g. an
EWW render for URL bookmarks, or a browser-tab hover instead of
switch-to-tab).

Absent :preview, falls back to `bookmark-jump-other-window'
on the record's own handler — equivalent to
`bookmark-gt-list-jump-other-window' except window selection
is restored to the list afterwards, so the cursor stays here
and you can walk down the list previewing each row."
  (interactive nil bookmark-gt-list-mode)
  (let* ((record (bookmark-gt-list--require-record))
         (entry (bookmark-gt-handler-classify record))
         (preview-fn (plist-get (cdr entry) :preview)))
    (save-selected-window
      (if preview-fn
          (funcall preview-fn record)
        (bookmark-jump-other-window (car record))))))

;;;; Edit in place

(defun bookmark-gt-list-rename (new-name)
  "Rename the bookmark on the current line to NEW-NAME."
  (interactive
   (let ((record (bookmark-gt-list--require-record)))
     (list (read-string
            (format-prompt "Rename to"
                           (bookmark-gt-display-name (car record)))
            nil nil (bookmark-gt-display-name (car record)))))
   bookmark-gt-list-mode)
  (let* ((record (bookmark-gt-list--require-record))
         (unique (bookmark-gt-disambiguate-name new-name)))
    (bookmark-rename (car record) unique)
    (run-hook-with-args 'bookmark-gt-set-after-hook
                        (cons unique (cdr record)))))

(defun bookmark-gt-list-relocate ()
  "Relocate the bookmark on the current line.
Dispatches to `bookmark-gt-relocate' with the row's record
name so the user gets file-name completion for file
bookmarks and a plain string prompt for URL bookmarks."
  (interactive nil bookmark-gt-list-mode)
  (let ((record (bookmark-gt-list--require-record)))
    (bookmark-gt-relocate (car record))))

(defun bookmark-gt-list-edit-tags ()
  "Prompt for a new tag list for the bookmark on the current line."
  (interactive nil bookmark-gt-list-mode)
  (let* ((record (bookmark-gt-list--require-record))
         (current (bookmark-gt-tags-of record))
         (new (bookmark-gt-tags-read "Tags" current)))
    (bookmark-gt-tags-set record new)))

(defun bookmark-gt-list-edit-annotation ()
  "Edit the annotation of the bookmark on the current line."
  (interactive nil bookmark-gt-list-mode)
  (let ((record (bookmark-gt-list--require-record)))
    (bookmark-edit-annotation (car record))))

(defun bookmark-gt-list-auto-update-toggle ()
  "Toggle the `auto-update' property on the bookmark on the current line.
Requires `bookmark-gt-auto-update' to be loaded (which defines
the toggle command); the column glyph itself works without it."
  (interactive nil bookmark-gt-list-mode)
  (let ((record (bookmark-gt-list--require-record)))
    (if (fboundp 'bookmark-gt-auto-update-toggle)
        (bookmark-gt-auto-update-toggle (car record))
      (user-error "The bookmark-gt-auto-update module is not loaded"))))

(defun bookmark-gt-list-temp-toggle ()
  "Toggle the temp property on the bookmark on the current line.
A temp bookmark is excluded from `bookmark-save' output (see
`bookmark-gt-install-temp-save-filter')."
  (interactive nil bookmark-gt-list-mode)
  (let ((record (bookmark-gt-list--require-record)))
    (bookmark-gt-toggle-temp (car record))))

(defcustom bookmark-gt-list-record-buffer-name "*Bookmark-gt Record*"
  "Name of the buffer that displays a single bookmark's record."
  :type 'string
  :group 'bookmark-gt)

;;;; Sort predicates for the marker columns
;;
;; Both `auto-update' and `bmkp-temp' are record-backed flags, so
;; sorting by them is straightforward — the predicate reads the
;; alist directly.  Records with the flag set come first (so the
;; flagged rows cluster at the top); ties fall back to display
;; name for a stable order.
;;
;; The `*' selection column is not sortable: its state lives in
;; `tabulated-list-mode's padding area, not in the record, and
;; `tabulated-list-print' wipes the padding on every re-render.
;; Sorting by `*' would thus be lossy in both directions.

(defun bookmark-gt-list--sort-by-mark (a b)
  "Sort A before B: deletion-flagged first, then selected, then unmarked.
Reads `bookmark-gt-list--marks' — mark state lives in that
hash, not in the record."
  (let* ((rank
          (lambda (id)
            (let ((m (and bookmark-gt-list--marks
                          (gethash id bookmark-gt-list--marks))))
              (cond
               ((eq m bookmark-gt-list-deletion-mark)  2)
               ((eq m bookmark-gt-list-selection-mark) 1)
               (t                                       0)))))
         (ra (funcall rank (car a)))
         (rb (funcall rank (car b))))
    (if (= ra rb)
        (string< (bookmark-gt-display-name (car (car a)))
                 (bookmark-gt-display-name (car (car b))))
      (> ra rb))))

(defun bookmark-gt-list--sort-by-group (a b)
  "Sort A before B by their group's display name, ties by record name."
  (let* ((ga (bookmark-gt-group-name (bookmark-gt-handler-group (car a))))
         (gb (bookmark-gt-group-name (bookmark-gt-handler-group (car b)))))
    (if (equal ga gb)
        (string< (bookmark-gt-display-name (car (car a)))
                 (bookmark-gt-display-name (car (car b))))
      (string< (or ga "") (or gb "")))))

(defun bookmark-gt-list--sort-by-record-flag (prop)
  "Return a comparator that puts records carrying PROP before others.
Ties break by display name for stability."
  (lambda (a b)
    (let* ((ra (car a))
           (rb (car b))
           (fa (and (bookmark-prop-get ra prop) t))
           (fb (and (bookmark-prop-get rb prop) t)))
      (cond
       ((and fa (not fb)) t)
       ((and fb (not fa)) nil)
       (t (string< (bookmark-gt-display-name (car ra))
                   (bookmark-gt-display-name (car rb))))))))

(defun bookmark-gt-list--sortable-columns ()
  "Return the ordered names of sortable columns in `tabulated-list-format'.
A column is sortable when its third element (the sort predicate)
is non-nil.  Order matches the visual left-to-right layout, which
is the order `bookmark-gt-list-sort-cycle' rotates through."
  (let (out)
    (dotimes (i (length tabulated-list-format))
      (let ((col (aref tabulated-list-format i)))
        (when (nth 2 col)
          (push (car col) out))))
    (nreverse out)))

(defun bookmark-gt-list-sort-cycle ()
  "Cycle the sort column to the next sortable column.
Considers only columns whose `tabulated-list-format' entry has
a non-nil sort predicate.  Ascending only — no direction
toggle."
  (interactive nil bookmark-gt-list-mode)
  (let* ((cols (bookmark-gt-list--sortable-columns))
         (_ (unless cols
              (user-error "No sortable columns in this buffer")))
         (current (car-safe tabulated-list-sort-key))
         (idx (or (seq-position cols current #'equal) -1))
         (next (nth (mod (1+ idx) (length cols)) cols)))
    (setq tabulated-list-sort-key (cons next nil))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (message "Sorted by: %s" next)))

(defun bookmark-gt-list-describe-record ()
  "Display the raw record of the bookmark on the current line.
Pretty-prints the (NAME . ALIST) cons via `pp' in
`bookmark-gt-list-record-buffer-name', with `emacs-lisp-mode'
syntax highlighting and `view-mode' for read-only navigation
\(`q' buries the buffer)."
  (interactive nil bookmark-gt-list-mode)
  (let* ((record (bookmark-gt-list--require-record))
         (name (bookmark-gt-display-name (car record)))
         (buf (get-buffer-create bookmark-gt-list-record-buffer-name)))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (format ";; Record for bookmark: %S\n;;\n" name))
      (pp record (current-buffer))
      (goto-char (point-min))
      (emacs-lisp-mode)
      (view-mode 1))
    (display-buffer buf)))

;;;; Filter

(defun bookmark-gt-list-filter-by (key)
  "Add a filter to the current buffer, chosen from `bookmark-gt-filter-alist'.
The special KEY `unfilter' clears every active filter."
  (interactive
   (let ((choices (cons '(unfilter
                          :name "Unfilter"
                          :doc "Clear every active filter.")
                        bookmark-gt-filter-alist)))
     (list (intern (completing-read
                    "Filter by: "
                    (mapcar (lambda (e) (symbol-name (car e))) choices)
                    nil t))))
   bookmark-gt-list-mode)
  (cond
   ((eq key 'unfilter)
    (setq bookmark-gt-list--filters nil))
   (t
    (let* ((entry (alist-get key bookmark-gt-filter-alist))
           (reader (plist-get entry :reader))
           (arg (funcall reader)))
      (setq bookmark-gt-list--filters
            (cons (cons key arg)
                  (assq-delete-all key bookmark-gt-list--filters))))))
  (revert-buffer))

;;;; Built-in filter entries

(add-to-list 'bookmark-gt-filter-alist
             (cons 'by-type
                   (list :name "Type"
                         :reader
                         (lambda ()
                           (intern
                            (completing-read
                             "Type: "
                             ;; Dedupe by :type — the handler registry
                             ;; is keyed by handler symbol and many
                             ;; entries share a type (URL has three
                             ;; handler-symbol aliases, browser-tab has
                             ;; three, etc.).
                             (let ((seen (make-hash-table :test #'eq))
                                   candidates)
                               (dolist (e bookmark-gt-handler-alist)
                                 (let ((type (plist-get (cdr e) :type)))
                                   (unless (gethash type seen)
                                     (puthash type t seen)
                                     (push (symbol-name type) candidates))))
                               (nreverse candidates))
                             nil t)))
                         :predicate (lambda (record type-key)
                                      (eq (bookmark-gt-handler-type record)
                                          type-key))
                         :doc "Show only bookmarks of the chosen type.")))

(add-to-list 'bookmark-gt-filter-alist
             (cons 'by-group
                   (list :name "Group"
                         :reader
                         (lambda ()
                           (intern
                            (completing-read
                             "Group: "
                             (mapcar (lambda (e) (symbol-name (car e)))
                                     bookmark-gt-group-alist)
                             nil t)))
                         :predicate (lambda (record group)
                                      (eq (bookmark-gt-handler-group record)
                                          group))
                         :doc "Show only bookmarks in the chosen group.")))

(add-to-list 'bookmark-gt-filter-alist
             (cons 'by-tag
                   (list :name "Tag"
                         :reader (lambda ()
                                   (completing-read
                                    "Tag: "
                                    (bookmark-gt-tags-list)
                                    nil t))
                         :predicate (lambda (record tag)
                                      (bookmark-gt-has-tag-p record tag))
                         :doc "Show only bookmarks carrying the chosen tag.")))

(add-to-list 'bookmark-gt-filter-alist
             (cons 'by-name-regexp
                   (list :name "Name regexp"
                         :reader (lambda ()
                                   (read-regexp "Name matches"))
                         :predicate (lambda (record regexp)
                                      (string-match-p
                                       regexp
                                       (bookmark-gt-display-name (car record))))
                         :doc "Show only bookmarks whose name matches a regexp.")))

;;;; Built-in sort entries
;;
;; Registered for completeness — tabulated-list itself sorts using
;; the column's own comparator string function.  The sort registry
;; is the public seam for future dispatch (mark-by, jump-order,
;; etc.) that would take a comparator by symbol.

(add-to-list 'bookmark-gt-sort-alist
             (cons 'name
                   (list :name "Name"
                         :comparator
                         (lambda (a b)
                           (string< (bookmark-gt-display-name (car a))
                                    (bookmark-gt-display-name (car b))))
                         :doc "Alphabetical by name.")))

(add-to-list 'bookmark-gt-sort-alist
             (cons 'type
                   (list :name "Type"
                         :comparator
                         (lambda (a b)
                           (string< (bookmark-gt-handler-name a)
                                    (bookmark-gt-handler-name b)))
                         :doc "Alphabetical by type name.")))

(provide 'bookmark-gt-list)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-list.el ends here
