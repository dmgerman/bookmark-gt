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

(defun bookmark-gt-tags-set (record tags)
  "Replace RECORD's tag list with TAGS.
TAGS is normalized (trimmed, empty-stripped, deduplicated) before
storing.  Fires `bookmark-gt-set-after-hook'."
  (let* ((normalized (bookmark-gt--normalize-tags tags))
         (entry (bookmark-gt--set-tags-property record normalized)))
    (run-hook-with-args 'bookmark-gt-set-after-hook entry)
    entry))

(defun bookmark-gt-tags-add (record tags)
  "Add TAGS to RECORD's existing tag list (set union)."
  (bookmark-gt-tags-set record
                        (append (bookmark-gt-tags-of record) tags)))

(defun bookmark-gt-tags-remove (record tags)
  "Remove TAGS from RECORD's existing tag list (set difference)."
  (bookmark-gt-tags-set record
                        (seq-difference (bookmark-gt-tags-of record)
                                        tags)))

;;;; Interactive reader

(defvar bookmark-gt-tags-history nil
  "History for `bookmark-gt-tags-read'.")

(defun bookmark-gt-tags-read (prompt &optional initial)
  "Read a list of tags from the minibuffer.
PROMPT is the completion prompt.  INITIAL, if non-nil, seeds the
minibuffer with a comma-separated form of the given tag list.

Completion candidates come from `bookmark-gt-tags-list'.
Returns a normalized list of strings."
  (let* ((candidates (bookmark-gt-tags-list))
         (initial-text (and initial (mapconcat #'identity initial ", ")))
         (raw (completing-read-multiple
               (format-prompt prompt (or initial-text ""))
               candidates
               nil nil initial-text
               'bookmark-gt-tags-history)))
    (bookmark-gt--normalize-tags raw)))

;;;; Tag-reader hook integration
;;
;; Registered into `bookmark-gt-set-tag-reader-hook' when a
;; bookmark-gt session is active.  The hook receives (RECORD
;; SEED-TAGS); we ignore RECORD and read from the user, using
;; SEED-TAGS as initial input so default-tags rules (S5) chain
;; naturally into the reader.

(defun bookmark-gt-tags--reader-hook (_record seed-tags)
  "Interactive tag-reader hook for `bookmark-gt-set-tag-reader-hook'.
Reads tags via `bookmark-gt-tags-read', using SEED-TAGS as the
minibuffer's initial content."
  (if (called-interactively-p 'any)
      (bookmark-gt-tags-read "Tags" seed-tags)
    seed-tags))

;;;###autoload
(defun bookmark-gt-tags-enable ()
  "Enable the interactive tag reader for `bookmark-gt-set'.
Registers `bookmark-gt-tags--reader-hook' into
`bookmark-gt-set-tag-reader-hook'.  Idempotent."
  (add-hook 'bookmark-gt-set-tag-reader-hook
            #'bookmark-gt-tags--reader-hook
            90))

;;;###autoload
(defun bookmark-gt-tags-disable ()
  "Remove the interactive tag reader from `bookmark-gt-set'."
  (remove-hook 'bookmark-gt-set-tag-reader-hook
               #'bookmark-gt-tags--reader-hook))

(provide 'bookmark-gt-tags)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-tags.el ends here
