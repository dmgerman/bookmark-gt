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
    (bookmark-gt-create-non-file "one" 'bookmark-gt-handler-url-jump
                              '((url . "https://one.example/")))
    (bookmark-gt-create-non-file "two" 'bookmark-gt-handler-url-jump
                              '((url . "https://two.example/")))
    (bookmark-gt-list-test--in-buffer
      (should (= (bookmark-gt-list-test--row-count) 2))
      (goto-char (point-min))
      (should (member (bookmark-gt-list-test--column 3) '("one" "two"))))))

(ert-deftest bookmark-gt-list-test-type-column-uses-registry ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x.example/")))
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 4) "URL")))))


(ert-deftest bookmark-gt-list-test-tags-column-joins ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'h
                              '((tags . ("proj" "urgent"))))
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 6) "proj, urgent")))))

;;;; Revert observer

(ert-deftest bookmark-gt-list-test-after-hook-refreshes-buffer ()
  "Mutating the alist via `bookmark-gt-create-non-file' triggers refresh."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-list-test--in-buffer
      (should (= (bookmark-gt-list-test--row-count) 0))
      (bookmark-gt-create-non-file "new" 'h nil)
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
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
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
    (bookmark-gt-create-non-file "a" 'h nil)
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
    (bookmark-gt-create-non-file "keep" 'h nil)
    (bookmark-gt-create-non-file "drop" 'h nil)
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
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
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
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://a")))
    (bookmark-gt-create-non-file "e" 'eww-bookmark-jump nil)
    (bookmark-gt-list-test--in-buffer
      (setq bookmark-gt-list--filters '((by-type . url)))
      (revert-buffer)
      (should (= (bookmark-gt-list-test--row-count) 1))
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 3) "u")))))

(ert-deftest bookmark-gt-list-test-filter-by-tag-narrows ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((tags . ("proj"))))
    (bookmark-gt-create-non-file "b" 'h '((tags . ("other"))))
    (bookmark-gt-list-test--in-buffer
      (setq bookmark-gt-list--filters '((by-tag . "proj")))
      (revert-buffer)
      (should (= (bookmark-gt-list-test--row-count) 1))
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 3) "a")))))

(ert-deftest bookmark-gt-list-test-filter-unfilter-restores ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
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
    (bookmark-gt-create-non-file "old" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (bookmark-gt-list-rename "new")
      (should (bookmark-get-bookmark "new" 'noerror))
      (should-not (bookmark-get-bookmark "old" 'noerror))
      (goto-char (point-min))
      (should (equal (bookmark-gt-list-test--column 3) "new")))))

(ert-deftest bookmark-gt-list-test-edit-tags-replaces ()
  "Editing the CSV replaces the tag list with the parsed result."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h '((tags . ("old" "keep"))))
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (&rest _) "new, keep")))
      (bookmark-gt-list-test--in-buffer
        (goto-char (point-min))
        (bookmark-gt-list-edit-tags)
        (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                       '("new" "keep")))))))

(ert-deftest bookmark-gt-list-test-edit-tags-removes-all ()
  "Emptying the CSV clears the record's tag list."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h '((tags . ("gone"))))
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (&rest _) "")))
      (bookmark-gt-list-test--in-buffer
        (goto-char (point-min))
        (bookmark-gt-list-edit-tags)
        (should-not (bookmark-gt-tags-of (car bookmark-alist)))))))

(ert-deftest bookmark-gt-list-test-edit-tags-removes-one ()
  "Deleting one tag from the CSV drops just that tag."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h '((tags . ("a" "b" "c"))))
    (cl-letf (((symbol-function 'read-from-minibuffer)
               (lambda (&rest _) "a, c")))
      (bookmark-gt-list-test--in-buffer
        (goto-char (point-min))
        (bookmark-gt-list-edit-tags)
        (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                       '("a" "c")))))))

;;;; Selection-scoped commands
;;
;; Every command reached through
;; `bookmark-gt-list--records-to-act-on' acts on the marked rows
;; when there are any, and on the row at point otherwise.

(defun bookmark-gt-list-test--mark-all ()
  "Mark every row in the current list buffer."
  (goto-char (point-min))
  (while (not (eobp))
    (when (tabulated-list-get-id)
      (bookmark-gt-list--set-mark-at-point
       bookmark-gt-list-selection-mark))
    (forward-line 1)))

(defun bookmark-gt-list-test--mark-named (name)
  "Mark the row whose Name column is NAME."
  (goto-char (point-min))
  (while (and (not (eobp))
              (not (equal (bookmark-gt-list-test--column 3) name)))
    (forward-line 1))
  (bookmark-gt-list--set-mark-at-point bookmark-gt-list-selection-mark))

(ert-deftest bookmark-gt-list-test-records-to-act-on-defaults-to-point ()
  "With no marks, the acted-on set is the single row at point."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (let ((records (bookmark-gt-list--records-to-act-on)))
        (should (= (length records) 1))
        (should (eq (car records) (tabulated-list-get-id)))))))

(ert-deftest bookmark-gt-list-test-records-to-act-on-uses-marks ()
  "Marked rows take precedence over the row at point, in row order."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (bookmark-gt-list-test--mark-all)
      ;; Point deliberately parked on the first row; both rows must
      ;; still come back, ordered as displayed.
      (goto-char (point-min))
      (let ((records (bookmark-gt-list--records-to-act-on)))
        (should (= (length records) 2))
        (should (equal (mapcar #'car records) '("a" "b")))))))

(ert-deftest bookmark-gt-list-test-add-tags-applies-to-all-marked ()
  "Adding a tag with several rows marked tags every marked record."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((tags . ("keep"))))
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (bookmark-gt-list-test--mark-all)
        (bookmark-gt-list-add-tags)
        (should (equal (bookmark-gt-tags-of
                        (bookmark-get-bookmark "a"))
                       '("keep" "new")))
        (should (equal (bookmark-gt-tags-of
                        (bookmark-get-bookmark "b"))
                       '("new")))))))

(ert-deftest bookmark-gt-list-test-remove-tags-offers-union ()
  "Removal completion covers the union of the marked records' tags."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((tags . ("only-a"))))
    (bookmark-gt-create-non-file "b" 'h '((tags . ("only-b"))))
    (let (offered)
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (_prompt _initial candidates)
                   (setq offered candidates)
                   '("only-a" "only-b"))))
        (bookmark-gt-list-test--in-buffer
          (bookmark-gt-list-test--mark-all)
          (bookmark-gt-list-remove-tags)
          (should (equal (sort (copy-sequence offered) #'string<)
                         '("only-a" "only-b")))
          ;; A tag absent from a record leaves that record alone.
          (should-not (bookmark-gt-tags-of (bookmark-get-bookmark "a")))
          (should-not (bookmark-gt-tags-of
                       (bookmark-get-bookmark "b"))))))))

(ert-deftest bookmark-gt-list-test-edit-tags-replaces-on-all-marked ()
  "The edited CSV replaces the tag list on every marked record."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((tags . ("old"))))
    (bookmark-gt-create-non-file "b" 'h '((tags . ("other"))))
    (let (seeded)
      (cl-letf (((symbol-function 'read-from-minibuffer)
                 (lambda (_prompt initial &rest _)
                   (setq seeded initial)
                   "shared")))
        (bookmark-gt-list-test--in-buffer
          (bookmark-gt-list-test--mark-all)
          (bookmark-gt-list-edit-tags)
          ;; Seeded with the union of both records' tags.
          (should (equal seeded "old, other"))
          (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "a"))
                         '("shared")))
          (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "b"))
                         '("shared"))))))))

(ert-deftest bookmark-gt-list-test-toggle-temp-makes-selection-uniform ()
  "A mixed selection goes uniformly on, then uniformly off."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-temp-set (bookmark-get-bookmark "a") t)
    (bookmark-gt-list-test--in-buffer
      (bookmark-gt-list-test--mark-all)
      ;; Mixed: "a" temp, "b" not.  First press turns both on.
      (bookmark-gt-list-toggle-temp)
      (should (bookmark-gt-temp-p (bookmark-get-bookmark "a")))
      (should (bookmark-gt-temp-p (bookmark-get-bookmark "b")))
      ;; All on: next press turns both off.
      (bookmark-gt-list-test--mark-all)
      (bookmark-gt-list-toggle-temp)
      (should-not (bookmark-gt-temp-p (bookmark-get-bookmark "a")))
      (should-not (bookmark-gt-temp-p (bookmark-get-bookmark "b"))))))

(ert-deftest bookmark-gt-list-test-toggle-temp-unmarked-negates-point ()
  "With no marks, the toggle still negates the record at point."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (bookmark-gt-list-toggle-temp)
      (should (bookmark-gt-temp-p (bookmark-get-bookmark "a")))
      (goto-char (point-min))
      (bookmark-gt-list-toggle-temp)
      (should-not (bookmark-gt-temp-p (bookmark-get-bookmark "a"))))))

(ert-deftest bookmark-gt-list-test-toggle-auto-update-marked ()
  "The auto-update toggle applies one value to the whole selection."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((auto-update . t)))
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (bookmark-gt-list-test--mark-all)
      (bookmark-gt-list-toggle-auto-update)
      (should (bookmark-prop-get (bookmark-get-bookmark "a") 'auto-update))
      (should (bookmark-prop-get (bookmark-get-bookmark "b") 'auto-update)))))

(ert-deftest bookmark-gt-list-test-marks-ignore-unmarked-rows ()
  "Only marked rows are acted on; unmarked rows are left alone."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (bookmark-gt-list-test--mark-named "a")
        ;; Point on "b", which is not marked: it must stay untagged.
        (goto-char (point-max))
        (forward-line -1)
        (bookmark-gt-list-add-tags)
        (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "a"))
                       '("new")))
        (should-not (bookmark-gt-tags-of (bookmark-get-bookmark "b")))))))

(ert-deftest bookmark-gt-list-test-deletion-flags-are-not-a-selection ()
  "Rows flagged `D' are not acted on by selection-scoped commands."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (goto-char (point-min))
        (bookmark-gt-list-flag-for-deletion 1)
        ;; Point back on the flagged row: it is the row at point, so
        ;; it is acted on as a single record, but not as a selection.
        (goto-char (point-max))
        (forward-line -1)
        (bookmark-gt-list-add-tags)
        (should-not (bookmark-gt-tags-of (bookmark-get-bookmark "a")))
        (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "b"))
                       '("new")))))))

(ert-deftest bookmark-gt-list-test-completed-command-deselects ()
  "Completing a selection-scoped command clears the marks."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (bookmark-gt-list-test--mark-all)
        (bookmark-gt-list-add-tags)
        (should-not (bookmark-gt-list--marked-records))
        (should (zerop (hash-table-count bookmark-gt-list--marks)))
        ;; The mark column is repainted, not just the hash cleared.
        (goto-char (point-min))
        (should (eq (char-after) ?\s))))))

(ert-deftest bookmark-gt-list-test-toggle-deselects ()
  "A completed toggle clears the marks too."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (bookmark-gt-list-test--mark-all)
      (bookmark-gt-list-toggle-temp)
      (should-not (bookmark-gt-list--marked-records))
      ;; A second press without re-marking acts on the row at
      ;; point alone, leaving the other record temp.
      (goto-char (point-min))
      (bookmark-gt-list-toggle-temp)
      (should-not (bookmark-gt-temp-p (bookmark-get-bookmark "a")))
      (should (bookmark-gt-temp-p (bookmark-get-bookmark "b"))))))

(ert-deftest bookmark-gt-list-test-empty-reader-keeps-selection ()
  "Ending the tag reader without input changes and clears nothing."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) nil)))
      (bookmark-gt-list-test--in-buffer
        (bookmark-gt-list-test--mark-all)
        (bookmark-gt-list-add-tags)
        (should (= (length (bookmark-gt-list--marked-records)) 2))))))

(ert-deftest bookmark-gt-list-test-deselect-keeps-deletion-flags ()
  "Deselecting after a command leaves `D' flags for `x' to consume."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        ;; "a" flagged for deletion, "b" selected for tagging.
        (goto-char (point-min))
        (bookmark-gt-list-flag-for-deletion 1)
        (bookmark-gt-list-test--mark-named "b")
        (bookmark-gt-list-add-tags)
        (should-not (bookmark-gt-list--marked-records))
        (should (= (length (bookmark-gt-list--collect-marked
                            bookmark-gt-list-deletion-mark))
                   1))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (bookmark-gt-list-execute-deletions))
        (should (= (length bookmark-alist) 1))
        (should (equal (caar bookmark-alist) "b"))))))

(ert-deftest bookmark-gt-list-test-execute-deletions-skips-hidden ()
  "Deletion is bounded by the view: hidden flagged rows survive."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      ;; Flag both, then narrow to "a".
      (goto-char (point-min))
      (bookmark-gt-list-flag-for-deletion 2)
      (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
      (tabulated-list-print t)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (bookmark-gt-list-execute-deletions))
      (should (= (length bookmark-alist) 1))
      (should (equal (caar bookmark-alist) "b"))
      ;; "b" keeps its flag, so lifting the filter allows a second
      ;; deliberate pass.
      (setq bookmark-gt-list--filters nil)
      (tabulated-list-print t)
      (should (equal (mapcar #'car (bookmark-gt-list--visible-marked
                                    bookmark-gt-list-deletion-mark))
                     '("b"))))))

(ert-deftest bookmark-gt-list-test-execute-deletions-counts-visible-only ()
  "The confirmation prompt counts only the rows that will be deleted."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      (goto-char (point-min))
      (bookmark-gt-list-flag-for-deletion 2)
      (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
      (tabulated-list-print t)
      (let (prompt)
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (p) (setq prompt p) t)))
          (bookmark-gt-list-execute-deletions))
        (should (string-match-p "1 bookmark" prompt))))))

(ert-deftest bookmark-gt-list-test-execute-deletions-all-hidden-signals ()
  "With every flagged row hidden, deletion refuses and deletes nothing."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-list-test--in-buffer
      ;; Flag "b" alone, then narrow to "a".
      (goto-char (point-min))
      (while (and (not (eobp))
                  (not (equal (bookmark-gt-list-test--column 3) "b")))
        (forward-line 1))
      (bookmark-gt-list-flag-for-deletion 1)
      (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
      (tabulated-list-print t)
      (let (asked)
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (setq asked t) t)))
          (should-error (bookmark-gt-list-execute-deletions)
                        :type 'user-error))
        ;; Refused before the confirmation prompt.
        (should-not asked))
      (should (= (length bookmark-alist) 2)))))

;;;; Selection under a filter

(ert-deftest bookmark-gt-list-test-filter-excludes-hidden-from-selection ()
  "A command acts only on marked rows the filter leaves visible."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        ;; Mark both, then narrow to "a" alone.
        (bookmark-gt-list-test--mark-all)
        (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
        (tabulated-list-print t)
        (should (= (bookmark-gt-list-test--row-count) 1))
        (bookmark-gt-list-add-tags)
        (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "a"))
                       '("new")))
        ;; "b" was marked but hidden: untouched.
        (should-not (bookmark-gt-tags-of (bookmark-get-bookmark "b")))))))

(ert-deftest bookmark-gt-list-test-filter-preserves-hidden-marks ()
  "Deselecting after a command leaves marks on filtered-out rows."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (bookmark-gt-list-test--mark-all)
        (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
        (tabulated-list-print t)
        (bookmark-gt-list-add-tags)
        ;; "a" acted on and deselected; "b" still marked in the hash.
        (should-not (bookmark-gt-list--marked-records))
        (setq bookmark-gt-list--filters nil)
        (tabulated-list-print t)
        (should (equal (mapcar #'car (bookmark-gt-list--marked-records))
                       '("b")))))))

(ert-deftest bookmark-gt-list-test-filter-hiding-all-marks-signals ()
  "With every marked row hidden, the command refuses rather than
falling back to the row at point."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (let ((prompted nil))
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (&rest _) (setq prompted t) '("new"))))
        (bookmark-gt-list-test--in-buffer
          ;; Mark only "b", then narrow to "a".
          (bookmark-gt-list-test--mark-named "b")
          (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
          (tabulated-list-print t)
          (goto-char (point-min))
          (should-error (bookmark-gt-list-add-tags) :type 'user-error)
          ;; Refused before reading anything from the user.
          (should-not prompted)
          ;; Neither the visible row at point nor the hidden marked
          ;; row was touched.
          (should-not (bookmark-gt-tags-of (bookmark-get-bookmark "a")))
          (should-not (bookmark-gt-tags-of (bookmark-get-bookmark "b")))
          ;; The mark survives for when the filter is lifted.
          (setq bookmark-gt-list--filters nil)
          (tabulated-list-print t)
          (should (equal (mapcar #'car (bookmark-gt-list--marked-records))
                         '("b"))))))))

(ert-deftest bookmark-gt-list-test-hidden-marks-signal-for-every-command ()
  "Every selection-scoped command refuses when the selection is hidden."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((tags . ("t"))))
    (bookmark-gt-create-non-file "b" 'h '((tags . ("t"))))
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new")))
              ((symbol-function 'read-from-minibuffer)
               (lambda (&rest _) "new")))
      (bookmark-gt-list-test--in-buffer
        (bookmark-gt-list-test--mark-named "b")
        (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
        (tabulated-list-print t)
        (goto-char (point-min))
        (dolist (command '(bookmark-gt-list-add-tags
                           bookmark-gt-list-remove-tags
                           bookmark-gt-list-edit-tags
                           bookmark-gt-list-toggle-temp
                           bookmark-gt-list-toggle-auto-update))
          (should-error (funcall command) :type 'user-error))
        ;; Nothing changed anywhere.
        (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "a"))
                       '("t")))
        (should-not (bookmark-gt-temp-p (bookmark-get-bookmark "a")))))))

(ert-deftest bookmark-gt-list-test-no-marks-still-uses-point ()
  "With nothing marked anywhere, a filter does not block the fallback."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
        (tabulated-list-print t)
        (goto-char (point-min))
        (bookmark-gt-list-add-tags)
        (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "a"))
                       '("new")))))))

(ert-deftest bookmark-gt-list-test-filter-scopes-toggle-target ()
  "The toggle's uniform value is computed over visible rows only."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    ;; "b" is already temp, "a" is not.  Were the hidden "b" counted,
    ;; the selection would read as mixed either way; what matters is
    ;; that only "a" is considered and only "a" changes.
    (bookmark-gt-temp-set (bookmark-get-bookmark "b") t)
    (bookmark-gt-list-test--in-buffer
      (bookmark-gt-list-test--mark-all)
      (setq bookmark-gt-list--filters '((by-name-regexp . "\\`a")))
      (tabulated-list-print t)
      (bookmark-gt-list-toggle-temp)
      (should (bookmark-gt-temp-p (bookmark-get-bookmark "a")))
      ;; Hidden "b" keeps the state it had.
      (should (bookmark-gt-temp-p (bookmark-get-bookmark "b"))))))

(ert-deftest bookmark-gt-list-test-show-temp-hidden-rows-excluded ()
  "Rows hidden by the `show-temp' toggle are outside the selection."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (cl-letf (((symbol-function 'bookmark-gt-tags-read)
               (lambda (&rest _) '("new"))))
      (bookmark-gt-list-test--in-buffer
        (bookmark-gt-list-test--mark-all)
        (bookmark-gt-temp-set (bookmark-get-bookmark "b") t)
        (setq bookmark-gt-list--show-temp nil)
        (tabulated-list-print t)
        (bookmark-gt-list-add-tags)
        (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "a"))
                       '("new")))
        (should-not (bookmark-gt-tags-of (bookmark-get-bookmark "b")))))))

;;;; View bookmarks

(ert-deftest bookmark-gt-list-test-save-view-captures-state ()
  "Calling `bookmark-gt-set' in the list buffer stores a view record."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'ignore nil)
    (bookmark-gt-list-test--in-buffer
      (setq bookmark-gt-list--filters '((by-tag . "work")))
      (setq tabulated-list-sort-key '("Name" . nil))
      (setq bookmark-gt-list--show-temp nil)
      (bookmark-gt-create "my-view"))
    (let ((rec (assoc "my-view" bookmark-alist)))
      (should rec)
      (should (eq (bookmark-prop-get rec 'handler)
                  'bookmark-gt-handler-view-jump))
      (should (equal (bookmark-prop-get rec 'filters)
                     '((by-tag . "work"))))
      (should (equal (bookmark-prop-get rec 'sort-key)
                     '("Name" . nil)))
      (should (eq (bookmark-prop-get rec 'show-temp) nil)))))

(ert-deftest bookmark-gt-list-test-view-jump-restores-state ()
  "Jumping a view record applies its saved state to the list buffer."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'ignore nil)
    ;; Store a view record by hand (skip the save-view command so
    ;; the test doesn't depend on the list buffer's live state).
    (bookmark-gt-create-non-file
     "v" 'bookmark-gt-handler-view-jump
     '((filters   . ((by-tag . "urgent")))
       (sort-key  . ("Type" . nil))
       (show-temp . nil)))
    (unwind-protect
        (progn
          (condition-case _err
              (bookmark-gt-handler-view-jump (assoc "v" bookmark-alist))
            (no-catch nil))
          (with-current-buffer bookmark-gt-list-buffer-name
            (should (equal bookmark-gt-list--filters
                           '((by-tag . "urgent"))))
            (should (equal tabulated-list-sort-key '("Type" . nil)))
            (should (eq bookmark-gt-list--show-temp nil))))
      (when (get-buffer bookmark-gt-list-buffer-name)
        (kill-buffer bookmark-gt-list-buffer-name)))))

(ert-deftest bookmark-gt-list-test-view-classifies-as-view ()
  "View records classify as type `view' via the registry."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "v" 'bookmark-gt-handler-view-jump
     '((filters . nil) (sort-key . nil) (show-temp . t)))
    (let ((rec (assoc "v" bookmark-alist)))
      (should (eq (bookmark-gt-handler-type rec) 'bookmark-gt-view))
      (should (equal (bookmark-gt-handler-name rec) "BkView")))))

;;;; Ephemeral sources are rebuilt when the list is read

(ert-deftest bookmark-gt-list-test-open-refreshes-ephemeral ()
  "Opening the list refreshes browser tabs, not only reverting does.
Nothing else populates tab records between reads, so a list
opened without this shows nothing in a session where no jump has
happened."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((refreshed 0))
      (cl-letf (((symbol-function 'bookmark-gt-browser-tabs-refresh)
                 (lambda (&rest _) (cl-incf refreshed))))
        (let ((bookmark-gt-browser-tabs-mode t))
          (bookmark-gt-list-test--in-buffer
            (should (= refreshed 1))))))))

(ert-deftest bookmark-gt-list-test-revert-refreshes-ephemeral ()
  (bookmark-gt-test-with-clean-bookmarks
    (let ((refreshed 0))
      (cl-letf (((symbol-function 'bookmark-gt-browser-tabs-refresh)
                 (lambda (&rest _) (cl-incf refreshed))))
        (let ((bookmark-gt-browser-tabs-mode t))
          (bookmark-gt-list-test--in-buffer
            (setq refreshed 0)
            (bookmark-gt-list--revert)
            (should (= refreshed 1))))))))

(provide 'bookmark-gt-list-tests)
;;; bookmark-gt-list-tests.el ends here
