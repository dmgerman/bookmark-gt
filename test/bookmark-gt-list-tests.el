;;; bookmark-gt-list-tests.el --- Tests for bookmark-gt-list   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the `*Bookmarks-gt List*' buffer: rendering, revert
;; observer, marks, deletion, jump dispatch, filter, edit commands.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-list)

(defmacro bookmark-gt-list-test--in-buffer (&rest body)
  "Open the list buffer, run BODY in it, kill on exit."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (bookmark-gt-list)
         (with-current-buffer bookmark-gt-list-buffer-name
           ,@body))
     (when (get-buffer bookmark-gt-list-buffer-name)
       (kill-buffer bookmark-gt-list-buffer-name))))

(defun bookmark-gt-list-test--column (col)
  "Return the trimmed text of COL (0-based) on the current line."
  (string-trim (aref (tabulated-list-get-entry) col)))

(defun bookmark-gt-list-test--row-count ()
  "Return the number of rendered tabulated-list rows in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (not (eobp))
        (when (tabulated-list-get-id) (setq n (1+ n)))
        (forward-line 1))
      n)))

;;;; Rendering

(ert-deftest bookmark-gt-list-test-buffer-shows-entries ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "one" 'bookmark-gt-handler-url-jump
                              '((url . "https://one.example/")))
    (bookmark-gt-set-non-file "two" 'bookmark-gt-handler-url-jump
                              '((url . "https://two.example/")))
    (bookmark-gt-list-test--in-buffer
      (should (= (bookmark-gt-list-test--row-count) 2))
      (goto-char (point-min))
      (should (member (bookmark-gt-list-test--column 3) '("one" "two"))))))

(ert-deftest bookmark-gt-list-test-type-column-uses-registry ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x.example/")))
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 4) "URL")))))


(ert-deftest bookmark-gt-list-test-tags-column-joins ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'h
                              '((tags . ("proj" "urgent"))))
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 6) "proj, urgent")))))

;;;; Revert observer

(ert-deftest bookmark-gt-list-test-after-hook-refreshes-buffer ()
  "Mutating the alist via `bookmark-gt-set-non-file' triggers refresh."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-list-test--in-buffer
      (should (= (bookmark-gt-list-test--row-count) 0))
      (bookmark-gt-set-non-file "new" 'h nil)
      (should (= (bookmark-gt-list-test--row-count) 1)))))

(ert-deftest bookmark-gt-list-test-revert-picks-up-external-changes ()
  "`revert-buffer' rebuilds from the current `bookmark-alist'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-list-test--in-buffer
      (push (cons "manual" '((handler . h))) bookmark-alist)
      (revert-buffer)
      (should (= (bookmark-gt-list-test--row-count) 1)))))

;;;; Marks

(ert-deftest bookmark-gt-list-test-mark-and-collect ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (bookmark-gt-set-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (bookmark-gt-list-mark 1)
      (goto-char (point-min))
      (should (eq (char-after) bookmark-gt-list-selection-mark))
      (let ((marked (bookmark-gt-list--collect-marked
                     bookmark-gt-list-selection-mark)))
        (should (= (length marked) 1))))))

(ert-deftest bookmark-gt-list-test-unmark ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (bookmark-gt-list-mark 1)
      (goto-char (point-min))
      (bookmark-gt-list-unmark 1)
      (goto-char (point-min))
      (should (eq (char-after) ?\s)))))

;;;; Deletion

(ert-deftest bookmark-gt-list-test-flag-and-execute ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "keep" 'h nil)
    (bookmark-gt-set-non-file "drop" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      ;; Find the "drop" line and flag it.
      (while (and (not (eobp))
                  (not (equal (bookmark-gt-list-test--column 3) "drop")))
        (forward-line 1))
      (bookmark-gt-list-flag-for-deletion 1)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (bookmark-gt-list-execute-deletions))
      (should (= (length bookmark-alist) 1))
      (should (equal (caar bookmark-alist) "keep")))))

;;;; Jump

(ert-deftest bookmark-gt-list-test-jump-dispatches ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let (seen)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url seen))))
        (bookmark-gt-list-test--in-buffer
          (goto-char (point-min))
          (bookmark-gt-list-jump)))
      (should (equal seen '("https://example.org"))))))

;;;; Filter

(ert-deftest bookmark-gt-list-test-filter-by-type-narrows ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://a")))
    (bookmark-gt-set-non-file "e" 'eww-bookmark-jump nil)
    (bookmark-gt-list-test--in-buffer
      (setq bookmark-gt-list--filters '((by-type . url)))
      (revert-buffer)
      (should (= (bookmark-gt-list-test--row-count) 1))
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 3) "u")))))

(ert-deftest bookmark-gt-list-test-filter-by-tag-narrows ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h '((tags . ("proj"))))
    (bookmark-gt-set-non-file "b" 'h '((tags . ("other"))))
    (bookmark-gt-list-test--in-buffer
      (setq bookmark-gt-list--filters '((by-tag . "proj")))
      (revert-buffer)
      (should (= (bookmark-gt-list-test--row-count) 1))
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 3) "a")))))

(ert-deftest bookmark-gt-list-test-filter-unfilter-restores ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (bookmark-gt-set-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
      (revert-buffer)
      (should (= (bookmark-gt-list-test--row-count) 1))
      (setq bookmark-gt-list--filters nil)
      (revert-buffer)
      (should (= (bookmark-gt-list-test--row-count) 2)))))

;;;; Edit commands

(ert-deftest bookmark-gt-list-test-rename-mutates-and-refreshes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "old" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (bookmark-gt-list-rename "new")
      (should (bookmark-get-bookmark "new" 'noerror))
      (should-not (bookmark-get-bookmark "old" 'noerror))
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 3) "new")))))

(ert-deftest bookmark-gt-list-test-edit-tags-updates ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h '((tags . ("old"))))
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (_prompt &optional _init) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (goto-char (point-min))
        (bookmark-gt-list-edit-tags)
        (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                       '("new")))
        (goto-char (point-min))
        (should (equal (bookmark-gt-list-test--column 6) "new"))))))

(provide 'bookmark-gt-list-tests)
;;; bookmark-gt-list-tests.el ends here
