;;; bookmark-gt-tags.el --- Tag storage, reader, and index API  -*- lexical-binding: t; -*-

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
;; Tag storage lives on the bookmark record under the `tags' alist
;; key (list of strings) — same key name as bookmark+ so files
;; round-trip.  This file provides the tag-index API
;; (`bookmark-gt-tags-of', `bookmark-gt-tags-list',
;; `bookmark-gt-tags-alist', `bookmark-gt-bookmarks-with-tag',
;; `bookmark-gt-has-tag-p'), the mutation API
;; (`bookmark-gt-tags-add', `-remove', `-set'), and the interactive
;; reader (`bookmark-gt-tags-read') registered into
;; `bookmark-gt-set-tag-reader-hook'.
;;
;; See ai/design/tag-storage.org for the API contract.

;;; Code:

(require 'bookmark)
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
;; Each mutator fires `bookmark-gt-set-after-hook' with the updated
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
When NO-NOTIFY is non-nil, skip UI refresh and the external
`bookmark-gt-set-after-hook' — the caller is expected to notify
once at end of a batch.  The record is stamped `last-modified'
either way."
  (let* ((normalized (bookmark-gt--normalize-tags tags))
         (entry (bookmark-gt--set-tags-property record normalized)))
    (if no-notify
        (bookmark-gt--stamp-modified entry)
      (bookmark-gt--after-mutation entry))
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

;;;; Tag-reader hook integration
;;
;; Registered into `bookmark-gt-set-tag-reader-hook' when a
;; bookmark-gt session is active.  The hook receives (RECORD
;; SEED-TAGS); we ignore RECORD and read from the user, using
;; SEED-TAGS as initial input so default-tags rules chain
;; naturally into the reader.
;;
;; Gated by `bookmark-gt-prompt-for-tags-flag' — a defcustom so
;; users can disable prompts globally, and batch callers
;; (`bookmark-gt-browser-tabs-refresh', tests) let-bind it to
;; nil around their loops.  Previously this check was
;; `called-interactively-p 'any', which is unreliable when the
;; hook is invoked via funcall through seq-reduce (the
;; interactive frame of `bookmark-gt-set' does not always reach
;; the check).

(defcustom bookmark-gt-prompt-for-tags-flag t
  "Non-nil means the tag reader prompts on `bookmark-gt-set'.
Set to nil to suppress the prompt globally, or let-bind around
a batch operation that stores many records without user
interaction."
  :type 'boolean
  :group 'bookmark-gt)

;; No enable/disable functions here — the interactive tag
;; reader is called directly by `bookmark-gt--collect-tags'
;; and gated by `bookmark-gt-prompt-for-tags-flag'.

(provide 'bookmark-gt-tags)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-tags.el ends here
