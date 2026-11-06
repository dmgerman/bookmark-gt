;;; bookmark-gt-tags.el --- Tag storage, reader, index API, default tags  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Keywords: convenience, matching, hypermedia
;; URL: https://github.com/dmgerman/bookmark-gt

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
;; Tag storage lives on the bookmark record under the `tags' alist
;; key (list of strings) — same key name as bookmark+ so files
;; round-trip.  This file provides the tag-index API
;; (`bookmark-gt-tags-of', `bookmark-gt-tags-list',
;; `bookmark-gt-tags-alist', `bookmark-gt-bookmarks-with-tag',
;; `bookmark-gt-has-tag-p'), the mutation API
;; (`bookmark-gt-tags-add', `-remove', `-set'), and the interactive
;; reader (`bookmark-gt-tags-read').
;;
;; The reader is called directly by `bookmark-gt--collect-tags' when
;; `bookmark-gt-prompt-for-tags-flag' is non-nil.  It is not added to
;; `bookmark-gt-create-tag-reader-hook' — that hook is external surface
;; and ships empty.
;;
;; `bookmark-gt-default-tags-mode' seeds the reader with tags
;; computed from `bookmark-gt-default-tags', a small DSL:
;;
;;   nil                — no default tags (feature off).
;;   \"tag\"              — one tag, always applied.
;;   (\"a\" \"b\")          — a list of tags, always applied.
;;   (lambda (record))  — called at set time with the record's
;;                        data alist; must return any of the above
;;                        shapes.  Errors are caught and demoted
;;                        to a warning; nothing is applied.
;;
;; Context-sensitive rules (per-mode, per-file, per-URL) are
;; expressed by writing a function that inspects the record and
;; returns the right tag list.  When the mode is on,
;; `bookmark-gt--collect-tags' calls `bookmark-gt-default-tags--hook'
;; before the interactive reader, so the defaults become the
;; reader's initial input; the user can accept, edit, or clear them.

;;; Code:

(require 'bookmark)
(require 'map)
(require 'seq)
(require 'bookmark-gt-core)

;;;; Invariant enforcement helpers

(defun bookmark-gt--normalize-tags (tags)
  "Return TAGS trimmed, empty-stripped, and duplicate-free.
Order is preserved with respect to first appearance."
  (seq-uniq
   (seq-remove #'string-empty-p
               (mapcar (lambda (s) (string-trim (or s ""))) tags))
   #'string=))

;;;; Query API (pure over `bookmark-alist')

(defun bookmark-gt-tags-of (record)
  "Return the tag list stored on RECORD.
RECORD is a bookmark record — either the (NAME . DATA) pair from
`bookmark-alist' or a bookmark name string.  Returns nil when the
bookmark has no tags."
  (bookmark-prop-get record 'tags))

(defun bookmark-gt-has-tag-p (record tag)
  "Return non-nil when RECORD carries TAG."
  (and (member tag (bookmark-gt-tags-of record)) t))

(defun bookmark-gt-tags-list ()
  "Return a sorted unique list of every tag in `bookmark-alist'."
  (sort (seq-uniq
         (seq-mapcat #'bookmark-gt-tags-of bookmark-alist)
         #'string=)
        #'string<))

(defun bookmark-gt-tags-alist ()
  "Return an alist ((TAG . COUNT) ...) sorted descending by COUNT.
COUNT is the number of bookmarks that carry TAG."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (entry bookmark-alist)
      (dolist (tag (bookmark-gt-tags-of entry))
        (puthash tag (1+ (gethash tag counts 0)) counts)))
    (sort (map-into counts 'list)
          (lambda (a b)
            (if (= (cdr a) (cdr b))
                (string< (car a) (car b))
              (> (cdr a) (cdr b)))))))

(defun bookmark-gt-bookmarks-with-tag (tag)
  "Return the list of bookmark records in `bookmark-alist' carrying TAG."
  (seq-filter (lambda (entry) (bookmark-gt-has-tag-p entry tag))
              bookmark-alist))

;;;; Mutation API
;;
;; Each mutator fires `bookmark-gt-record-changed-hook' with the updated
;; (NAME . DATA) pair so observers refresh.  Direct mutation of the
;; tag list is discouraged; go through these functions.

(defun bookmark-gt--set-tags-property (record tags)
  "Set RECORD's `tags' property to TAGS, or remove the key when TAGS is nil.
Returns the record entry from `bookmark-alist' (the mutated
cons)."
  (let ((entry (bookmark-get-bookmark record)))
    (if (null tags)
        (setcdr entry (assq-delete-all 'tags (cdr entry)))
      (let* ((data (cdr entry))
             (cell (assq 'tags data)))
        (if cell
            (setcdr cell tags)
          (setcdr entry (cons (cons 'tags tags) data)))))
    entry))

(defun bookmark-gt-tags-set (record tags &optional no-notify)
  "Replace RECORD's tag list with TAGS (normalized).
RECORD is a `(NAME . DATA)' pair or a bookmark name.  A name is
resolved to the first record carrying it: this runs in batches
and from timers, where prompting to disambiguate would be wrong,
so the caller is expected to pass a record when it matters.

When NO-NOTIFY is non-nil, skip UI refresh and the external
`bookmark-gt-record-changed-hook' — the caller is expected to notify
once at end of a batch.  The record is stamped `last-modified'
either way."
  (let* ((normalized (bookmark-gt--normalize-tags tags))
         (entry (bookmark-gt--set-tags-property record normalized)))
    (if no-notify
        (bookmark-gt--stamp-modified entry)
      (bookmark-gt--after-mutation entry 'tags))
    entry))

(defun bookmark-gt-tags-add (record tags &optional no-notify)
  "Add TAGS to RECORD's existing tag list (set union).
NO-NOTIFY is passed to `bookmark-gt-tags-set'."
  (bookmark-gt-tags-set record
                        (append (bookmark-gt-tags-of record) tags)
                        no-notify))

(defun bookmark-gt-tags-remove (record tags &optional no-notify)
  "Remove TAGS from RECORD's existing tag list (set difference).
NO-NOTIFY is passed to `bookmark-gt-tags-set'."
  (bookmark-gt-tags-set record
                        (seq-difference (bookmark-gt-tags-of record)
                                        tags)
                        no-notify))

;;;; Interactive reader

(defvar bookmark-gt-tags-history nil
  "History for `bookmark-gt-tags-read'.
Populated by `completing-read' inside the sequential loop; the
most-recently-entered tags appear first, and the reader uses
this order to present candidates MRU-first.")

(defun bookmark-gt-tags--candidates-mru ()
  "Return every known tag ordered MRU-first.
Tags present in `bookmark-gt-tags-history' come first, in
history order; tags never chosen come next in the sort order
returned by `bookmark-gt-tags-list'."
  (let* ((all (bookmark-gt-tags-list))
         (all-set (make-hash-table :test #'equal))
         (seen (make-hash-table :test #'equal))
         (front nil)
         (back nil))
    (dolist (tag all) (puthash tag t all-set))
    (dolist (h bookmark-gt-tags-history)
      (when (and (gethash h all-set) (not (gethash h seen)))
        (push h front)
        (puthash h t seen)))
    (dolist (tag all)
      (unless (gethash tag seen) (push tag back)))
    (nconc (nreverse front) (nreverse back))))

(defun bookmark-gt-tags--completion-table (candidates)
  "Return a completion table that preserves the order of CANDIDATES.
The default completion machinery sorts alphabetically; MRU
ordering is only visible if `display-sort-function' and
`cycle-sort-function' are pinned to `identity'."
  (lambda (str pred action)
    (if (eq action 'metadata)
        '(metadata
          (display-sort-function . identity)
          (cycle-sort-function . identity))
      (complete-with-action action candidates str pred))))

(defun bookmark-gt-tags-read (prompt &optional initial candidates)
  "Read a list of tags under PROMPT, one prompt per tag.
Empty \\`RET' or \\`M-RET' ends the loop.  INITIAL seeds the
accumulator.  CANDIDATES restricts the completion set to that
list (order preserved); nil means every tag currently in
`bookmark-alist' (MRU-ordered).  Returns the normalized tag
list."
  (let* ((candidates (or candidates (bookmark-gt-tags--candidates-mru)))
         (table (bookmark-gt-tags--completion-table candidates))
         (accum (and initial (copy-sequence initial))))
    (catch 'done
      (while t
        (let* ((finished nil)
               (seen (and accum
                          (format " [%s]"
                                  (mapconcat #'identity accum ","))))
               (fmt (format "%s%s (M-RET or empty RET to finish): "
                            prompt (or seen "")))
               (input
                (minibuffer-with-setup-hook
                    (lambda ()
                      (let ((m (make-sparse-keymap)))
                        (set-keymap-parent m (current-local-map))
                        (define-key m (kbd "M-RET")
                                    (lambda ()
                                      (interactive)
                                      (setq finished t)
                                      (exit-minibuffer)))
                        (use-local-map m)))
                  (completing-read fmt table nil nil nil
                                   'bookmark-gt-tags-history))))
          (cond
           (finished
            (unless (string-empty-p input) (push input accum))
            (throw 'done nil))
           ((string-empty-p input) (throw 'done nil))
           (t (push input accum))))))
    (bookmark-gt--normalize-tags (nreverse accum))))

;;;; Prompt gate
;;
;; `bookmark-gt--collect-tags' calls `bookmark-gt-tags-read' with
;; the seed tags (including any default tags) as initial input.
;; The call is gated by `bookmark-gt-prompt-for-tags-flag' — a defcustom so
;; users can disable prompts globally, and batch callers
;; (`bookmark-gt-browser-tabs-refresh', tests) let-bind it to
;; nil around their loops.  Previously this check was
;; `called-interactively-p 'any', which is unreliable when the
;; hook is invoked via funcall through seq-reduce (the
;; interactive frame of `bookmark-gt-create' does not always reach
;; the check).

(defcustom bookmark-gt-prompt-for-tags-flag t
  "Non-nil means the tag reader prompts on `bookmark-gt-create'.
Set to nil to suppress the prompt globally, or let-bind around
a batch operation that stores many records without user
interaction."
  :type 'boolean
  :group 'bookmark-gt)

;; No enable/disable functions here — the interactive tag
;; reader is called directly by `bookmark-gt--collect-tags'
;; and gated by `bookmark-gt-prompt-for-tags-flag'.

;;;; Default tags: customization

(defcustom bookmark-gt-default-tags nil
  "Default tag list to seed the tag reader on `bookmark-gt-create'.

Value shape:

  nil               — no defaults (feature off).
  a string          — one tag.
  a list of strings — multiple tags.
  a function        — called with one argument, the record's data
                      alist.  Must return one of the above shapes.
                      Errors are caught and demoted to a warning.

The value is a seed the user can accept or override in the tag
reader.  Nothing is forced onto the record — see
`bookmark-gt-default-tags--hook' for the composition contract."
  :type '(choice (const  :tag "None"          nil)
                 (string :tag "Single tag")
                 (repeat :tag "List of tags"  string)
                 (function :tag "Function returning any of the above"))
  :group 'bookmark-gt)

;;;; Default tags: shape classifier

(defun bookmark-gt-default-tags--kind (val)
  "Classify VAL as one of the DSL shapes.
Returns `empty', `bare', `flat', `function', or `unknown'."
  (cond
   ((null val)                          'empty)
   ((stringp val)                       'bare)
   ((functionp val)                     'function)
   ((and (listp val)
         (seq-every-p #'stringp val))   'flat)
   (t                                   'unknown)))

;;;; Default tags: resolver

(defun bookmark-gt-default-tags--warn (fmt &rest args)
  "Show a warning built from FMT + ARGS under this feature's warning class."
  (display-warning 'bookmark-gt-default-tags
                   (apply #'format fmt args) :warning))

(defun bookmark-gt-default-tags--resolve (val record)
  "Return a normalized tag list from VAL, given RECORD.
VAL follows the shape described in `bookmark-gt-default-tags'.
Returns nil for the empty shape or on any resolution error;
never signals."
  (pcase (bookmark-gt-default-tags--kind val)
    ('empty nil)
    ('bare  (list val))
    ('flat  val)
    ('function
     (condition-case err
         (let ((computed (funcall val record)))
           (pcase (bookmark-gt-default-tags--kind computed)
             ('empty nil)
             ('bare  (list computed))
             ('flat  computed)
             (_
              (bookmark-gt-default-tags--warn
               "`bookmark-gt-default-tags' function returned %S, \
which is not a recognized shape.  No tags applied."
               computed)
              nil)))
       (error
        (bookmark-gt-default-tags--warn
         "`bookmark-gt-default-tags' function signaled: %s.  \
No tags applied."
         (error-message-string err))
        nil)))
    (_
     (bookmark-gt-default-tags--warn
      "`bookmark-gt-default-tags' value %S is not a recognized \
shape.  No tags applied." val)
     nil)))

;;;; Default tags: contribution

(defun bookmark-gt-default-tags--hook (record seed-tags)
  "Return SEED-TAGS augmented with `bookmark-gt-default-tags' for RECORD.
Called directly by `bookmark-gt--collect-tags' when
`bookmark-gt-default-tags-mode' is on."
  (let ((defaults (bookmark-gt-default-tags--resolve
                   bookmark-gt-default-tags record)))
    (bookmark-gt--normalize-tags (append seed-tags defaults))))

;;;###autoload
(define-minor-mode bookmark-gt-default-tags-mode
  "Global minor mode that applies `bookmark-gt-default-tags' on set."
  :global t
  :group 'bookmark-gt)

(provide 'bookmark-gt-tags)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-tags.el ends here
