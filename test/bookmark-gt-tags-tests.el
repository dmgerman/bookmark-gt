;;; bookmark-gt-tags-tests.el --- Tests for bookmark-gt-tags   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the tag query, mutation, and normalization API.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-tags)

(defun bookmark-gt-test--make (name handler tags)
  "Create a non-file bookmark NAME with HANDLER and TAGS."
  (bookmark-gt-create-non-file
   name handler
   (if tags (list (cons 'tags tags)) nil)))

;;;; Normalization

(ert-deftest bookmark-gt-test-normalize-strips-empty ()
  (should (equal (bookmark-gt--normalize-tags '("a" "" " " "b"))
                 '("a" "b"))))

(ert-deftest bookmark-gt-test-normalize-trims-whitespace ()
  (should (equal (bookmark-gt--normalize-tags '("  foo  " "\tbar\n"))
                 '("foo" "bar"))))

(ert-deftest bookmark-gt-test-normalize-dedupes ()
  (should (equal (bookmark-gt--normalize-tags '("a" "b" "a"))
                 '("a" "b"))))

;;;; Query API

(ert-deftest bookmark-gt-test-tags-of-empty ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "foo" 'h nil)
    (should (null (bookmark-gt-tags-of (car bookmark-alist))))))

(ert-deftest bookmark-gt-test-tags-list-sorted-unique ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("z" "b"))
    (bookmark-gt-test--make "b" 'h '("b" "a"))
    (should (equal (bookmark-gt-tags-list) '("a" "b" "z")))))

(ert-deftest bookmark-gt-test-tags-alist-counts ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("proj" "urgent"))
    (bookmark-gt-test--make "b" 'h '("proj"))
    (bookmark-gt-test--make "c" 'h '("proj" "review"))
    (let ((alist (bookmark-gt-tags-alist)))
      (should (equal (assoc "proj" alist) '("proj" . 3)))
      (should (equal (assoc "urgent" alist) '("urgent" . 1)))
      (should (equal (assoc "review" alist) '("review" . 1))))))

(ert-deftest bookmark-gt-test-bookmarks-with-tag-finds ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("proj"))
    (bookmark-gt-test--make "b" 'h '("other"))
    (bookmark-gt-test--make "c" 'h '("proj"))
    (should (= (length (bookmark-gt-bookmarks-with-tag "proj")) 2))
    (should (= (length (bookmark-gt-bookmarks-with-tag "nope")) 0))))

(ert-deftest bookmark-gt-test-has-tag-p ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("proj"))
    (should (bookmark-gt-has-tag-p (car bookmark-alist) "proj"))
    (should-not (bookmark-gt-has-tag-p (car bookmark-alist) "other"))))

;;;; Mutation API

(ert-deftest bookmark-gt-test-tags-set-normalizes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h nil)
    (bookmark-gt-tags-set (car bookmark-alist) '(" proj " "" "urgent"))
    (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                   '("proj" "urgent")))))

(ert-deftest bookmark-gt-test-tags-set-nil-removes-key ()
  "Storing an empty tag list removes the alist entry entirely."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("proj"))
    (bookmark-gt-tags-set (car bookmark-alist) nil)
    (should-not (assq 'tags (cdr (car bookmark-alist))))))

(ert-deftest bookmark-gt-test-tags-add-unions ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("one"))
    (bookmark-gt-tags-add (car bookmark-alist) '("one" "two"))
    (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                   '("one" "two")))))

(ert-deftest bookmark-gt-test-tags-remove-diffs ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("a" "b" "c"))
    (bookmark-gt-tags-remove (car bookmark-alist) '("b"))
    (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                   '("a" "c")))))

;;;; MRU candidate ordering

(ert-deftest bookmark-gt-test-tags-candidates-mru-history-first ()
  "Tags present in `bookmark-gt-tags-history' precede unseen tags."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("alpha" "beta" "gamma" "delta"))
    ;; Simulate a history where user picked gamma then alpha most recently.
    (let ((bookmark-gt-tags-history '("alpha" "gamma")))
      (should (equal (bookmark-gt-tags--candidates-mru)
                     '("alpha" "gamma" "beta" "delta"))))))

(ert-deftest bookmark-gt-test-tags-candidates-mru-empty-history ()
  "With no history, candidates fall back to `bookmark-gt-tags-list' order."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("gamma" "alpha" "beta"))
    (let ((bookmark-gt-tags-history nil))
      (should (equal (bookmark-gt-tags--candidates-mru)
                     '("alpha" "beta" "gamma"))))))

(ert-deftest bookmark-gt-test-tags-candidates-mru-drops-unknown ()
  "History entries not present in the current tag universe are ignored."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("alpha" "beta"))
    (let ((bookmark-gt-tags-history '("ghost" "alpha")))
      (should (equal (bookmark-gt-tags--candidates-mru)
                     '("alpha" "beta"))))))

;;;; Save / load round-trip

(ert-deftest bookmark-gt-test-tags-survive-save-load ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-test--make "a" 'h '("proj" "urgent"))
    (bookmark-save)
    (let ((bookmark-alist nil))
      (bookmark-load bookmark-default-file t t nil)
      (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                     '("proj" "urgent"))))))

;;;; TAGS passed to a create command seeds the reader

(ert-deftest bookmark-gt-tags-test-create-seeds-the-reader ()
  "The TAGS argument reaches the tag reader as its seed."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-prompt-for-tags-flag t)
          seen)
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (_prompt seed) (setq seen seed) seed)))
        (bookmark-gt-create-url "https://example.org" "site"
                                (list "web" "reference")))
      (should (equal seen '("web" "reference"))))))

(ert-deftest bookmark-gt-tags-test-create-stores-one-tags-cell ()
  "The pipeline replaces the seed rather than shadowing it.
Two `tags' cells would leave the caller's list on the record but
unreachable, since `bookmark-prop-get' takes the first."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-prompt-for-tags-flag t))
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (_prompt _seed) '("chosen"))))
        (bookmark-gt-create-url "https://example.org" "site"
                                (list "web"))))
    (let ((record (bookmark-get-bookmark "site")))
      (should (equal (bookmark-gt-tags-of record) '("chosen")))
      (should (= 1 (seq-count (lambda (cell) (eq (car-safe cell) 'tags))
                              (cdr record)))))))

(ert-deftest bookmark-gt-tags-test-create-accepts-tags ()
  "`bookmark-gt-create' takes TAGS like the typed creators do."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-prompt-for-tags-flag nil)
          (tmp (make-temp-file "bookmark-gt-tags-")))
      (unwind-protect
          (with-current-buffer (find-file-noselect tmp)
            (unwind-protect
                (let ((record (bookmark-gt-create "here" (list "work"))))
                  (should (equal (bookmark-gt-tags-of record) '("work"))))
              (kill-buffer)))
        (delete-file tmp)))))

(provide 'bookmark-gt-tags-tests)
;;; bookmark-gt-tags-tests.el ends here
