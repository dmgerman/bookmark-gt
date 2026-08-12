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

(defun bookmark-gt-list--entry-vector (record)
  "Return the tabulated-list vector for RECORD."
  (let* ((name (bookmark-gt-display-name (car record)))
         (type (bookmark-gt-handler-name record))
         (face (bookmark-gt-handler-face record)))
    (vector ""
            (bookmark-gt-list--auto-update-glyph record)
            (bookmark-gt-list--temp-glyph record)
            (if face (propertize name 'face face) name)
            type
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
  "RET" #'bookmark-gt-list-jump
  "o"   #'bookmark-gt-list-jump-other-window
  "C-o" #'bookmark-gt-list-jump-other-window
  "^"   #'bookmark-gt-list-auto-update-toggle
  "T"   #'bookmark-gt-list-temp-toggle
  "m"   #'bookmark-gt-list-mark
  "u"   #'bookmark-gt-list-unmark
  "U"   #'bookmark-gt-list-unmark-all
  "d"   #'bookmark-gt-list-flag-for-deletion
  "x"   #'bookmark-gt-list-execute-deletions
  "r"   #'bookmark-gt-list-rename
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
`S') to sort by that column.

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
\\[bookmark-gt-list-jump-other-window] in another window.

Edit in place: \\[bookmark-gt-list-rename] rename,
\\[bookmark-gt-list-edit-tags] edit tags,
\\[bookmark-gt-list-edit-annotation] edit annotation.

Filter: \\[bookmark-gt-list-filter-by] then choose a
predicate (`by-type', `by-tag', `by-name-regexp', or
`unfilter').

\\{bookmark-gt-list-mode-map}"
  (setq tabulated-list-format
        `[(" "  1 nil)
          ("^"  1 nil)
          ("t"  1 nil)
          ("Name"     ,bookmark-gt-list-name-width t)
          ("Type"     ,bookmark-gt-list-type-width t)
          ("Tags"     ,bookmark-gt-list-tags-width t)
          ("Location" 0 t)])
  (setq tabulated-list-padding 2)
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

(defun bookmark-gt-list--refresh-observer (&rest _)
  "Refresh every live `bookmark-gt-list-mode' buffer.
Invoked from `bookmark-gt-set-after-hook' so any mutation of the
alist \(create, rename, edit tags, delete) updates the display
without manual polling.  A full redraw is used because the
record cons is the tabulated-list ID and mutations happen in
place \(same ID, changed content), which the differential-update
path would skip."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'bookmark-gt-list-mode)
        (let ((inhibit-read-only t))
          (tabulated-list-print t))))))

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
positions, and any other transient state."
  (bookmark-gt-refresh-ephemeral)
  (tabulated-list-print t))

;;;; Cursor → record lookup

(defun bookmark-gt-list--record-at-point ()
  "Return the bookmark record on the current line, or nil."
  (tabulated-list-get-id))

(defun bookmark-gt-list--require-record ()
  "Return the record on the current line, signalling if none."
  (or (bookmark-gt-list--record-at-point)
      (user-error "No bookmark on this line")))

;;;; Marks

(defun bookmark-gt-list-mark (&optional arg)
  "Mark the current bookmark and move down ARG lines (default 1)."
  (interactive "p" bookmark-gt-list-mode)
  (tabulated-list-put-tag (char-to-string bookmark-gt-list-selection-mark)
                          (> (or arg 1) 0))
  (unless (and arg (< arg 0))
    (dotimes (_ (max 0 (1- (or arg 1))))
      (tabulated-list-put-tag (char-to-string bookmark-gt-list-selection-mark) t))))

(defun bookmark-gt-list-flag-for-deletion (&optional arg)
  "Flag the current bookmark for deletion and move down ARG lines."
  (interactive "p" bookmark-gt-list-mode)
  (tabulated-list-put-tag (char-to-string bookmark-gt-list-deletion-mark)
                          (> (or arg 1) 0))
  (unless (and arg (< arg 0))
    (dotimes (_ (max 0 (1- (or arg 1))))
      (tabulated-list-put-tag (char-to-string bookmark-gt-list-deletion-mark) t))))

(defun bookmark-gt-list-unmark (&optional arg)
  "Remove any mark from the current bookmark and move down ARG lines."
  (interactive "p" bookmark-gt-list-mode)
  (tabulated-list-put-tag " " (> (or arg 1) 0))
  (unless (and arg (< arg 0))
    (dotimes (_ (max 0 (1- (or arg 1))))
      (tabulated-list-put-tag " " t))))

(defun bookmark-gt-list-unmark-all ()
  "Remove every mark and flag from the buffer."
  (interactive nil bookmark-gt-list-mode)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (tabulated-list-put-tag " " t))))

(defun bookmark-gt-list--collect-tagged (char)
  "Return records whose mark column matches CHAR."
  (let (records)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (eq (char-after) char)
          (when-let ((rec (tabulated-list-get-id)))
            (push rec records)))
        (forward-line 1)))
    (nreverse records)))

(defun bookmark-gt-list-execute-deletions ()
  "Delete every bookmark flagged with `bookmark-gt-list-deletion-mark'."
  (interactive nil bookmark-gt-list-mode)
  (let ((flagged (bookmark-gt-list--collect-tagged
                  bookmark-gt-list-deletion-mark)))
    (unless flagged
      (user-error "No bookmarks flagged for deletion"))
    (unless (yes-or-no-p (format "Delete %d bookmark(s)? "
                                 (length flagged)))
      (user-error "Aborted"))
    (dolist (record flagged)
      (bookmark-delete (car record) t))
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

;;;; Filter

(defun bookmark-gt-list-filter-by (key)
  "Add a filter to the current buffer, chosen from `bookmark-gt-filter-alist'.
The special KEY `unfilter' clears every active filter."
  (interactive
   (let ((choices (cons '("unfilter"
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
