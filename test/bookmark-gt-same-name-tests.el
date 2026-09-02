;;; bookmark-gt-same-name-tests.el --- Same-name record targeting  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Regression tests for acting on the record you hold rather than
;; on the first record carrying its name.
;;
;; `bookmark-get-bookmark' resolves a name with `assoc', so any
;; code that holds a record and passes its name acts on a
;; different record whenever two share a name.  Each test here
;; builds two records with one name and asserts the operation hit
;; the intended one.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'test-helper)
(require 'bookmark-gt-core)
(require 'bookmark-gt-list)

(defun bookmark-gt-same-name-test--pair ()
  "Store two records both named \"todo\" and return them as (A B).
A points at /tmp/a/notes.org, B at /tmp/b/notes.org.  They are
identified by target, not by position: `bookmark-gt--push-record'
pushes onto the front of `bookmark-alist', so `bookmark-get-bookmark'
resolves \"todo\" to B, the most recently stored one."
  ;; Fresh conses, not quoted literals: relocate mutates the
  ;; `filename' cell in place, which would rewrite a literal
  ;; constant and change what later calls return.
  (bookmark-gt-create-non-file "todo" 'h-a
                            (list (cons 'filename "/tmp/a/notes.org")))
  (bookmark-gt-create-non-file "todo" 'h-b
                            (list (cons 'filename "/tmp/b/notes.org")))
  (let ((a (seq-find (lambda (r)
                       (equal (bookmark-gt-filename-of r) "/tmp/a/notes.org"))
                     bookmark-alist))
        (b (seq-find (lambda (r)
                       (equal (bookmark-gt-filename-of r) "/tmp/b/notes.org"))
                     bookmark-alist)))
    (should (= 2 (seq-count (lambda (r) (equal (car r) "todo")) bookmark-alist)))
    (should a)
    (should b)
    (should-not (eq a b))
    ;; The premise every test here rests on.
    (should (eq (bookmark-get-bookmark "todo") b))
    (list a b)))

;;;; Delete

(ert-deftest bookmark-gt-same-name-test-delete-removes-that-record ()
  "Deleting record A removes A, not the one its name resolves to."
  (bookmark-gt-test-with-clean-bookmarks
    (pcase-let ((`(,a ,b) (bookmark-gt-same-name-test--pair)))
      (bookmark-gt-delete-record a)
      (should-not (memq a bookmark-alist))
      (should (memq b bookmark-alist)))))

(ert-deftest bookmark-gt-same-name-test-delete-by-name-takes-first ()
  "Built-in `bookmark-delete' removes the name's first match — what we avoid."
  (bookmark-gt-test-with-clean-bookmarks
    (pcase-let ((`(,a ,b) (bookmark-gt-same-name-test--pair)))
      (bookmark-delete "todo" t)
      (should-not (memq b bookmark-alist))
      (should (memq a bookmark-alist)))))

;;;; Rename

(ert-deftest bookmark-gt-same-name-test-rename-renames-that-record ()
  "Renaming record A renames A and leaves B named \"todo\"."
  (bookmark-gt-test-with-clean-bookmarks
    (pcase-let ((`(,a ,b) (bookmark-gt-same-name-test--pair)))
      (bookmark-gt-rename-record a "renamed")
      (should (equal (bookmark-name-from-full-record a) "renamed"))
      (should (equal (bookmark-name-from-full-record b) "todo")))))

;;;; Relocate

(ert-deftest bookmark-gt-same-name-test-relocate-targets-that-record ()
  "Relocating record A retargets A and leaves B alone."
  (bookmark-gt-test-with-clean-bookmarks
    (pcase-let ((`(,a ,b) (bookmark-gt-same-name-test--pair)))
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) "/tmp/moved/notes.org")))
        (bookmark-gt-relocate a))
      (should (equal (bookmark-gt-filename-of a) "/tmp/moved/notes.org"))
      (should (equal (bookmark-gt-filename-of b) "/tmp/b/notes.org")))))

;;;; Visit tracking

(ert-deftest bookmark-gt-same-name-test-visit-credits-that-record ()
  "A visit is credited to the record jumped to, not the name's first match."
  (bookmark-gt-test-with-clean-bookmarks
    (pcase-let ((`(,a ,b) (bookmark-gt-same-name-test--pair)))
      (let ((bookmark-gt-current-bookmark a))
        (bookmark-gt--on-jump-record-visit))
      (should (= 1 (bookmark-prop-get a 'visits)))
      (should-not (bookmark-prop-get b 'visits)))))

;;;; File-rename tracking

(ert-deftest bookmark-gt-same-name-test-file-rename-tracks-each-record ()
  "Renaming a file rewrites the record pointing at it, not a namesake."
  (bookmark-gt-test-with-clean-bookmarks
    (let* ((dir (make-temp-file "bookmark-gt-rename" t))
           (src (expand-file-name "a.txt" dir))
           (dst (expand-file-name "moved.txt" dir)))
      (unwind-protect
          (progn
            (with-temp-file src (insert "x\n"))
            ;; Two records share a name; only one points at SRC.
            (bookmark-gt-create-non-file "todo" 'h-a
                                      (list (cons 'filename src)))
            (bookmark-gt-create-non-file "todo" 'h-b
                                      (list (cons 'filename
                                                  "/tmp/elsewhere.txt")))
            (let* ((tracked (seq-find (lambda (r)
                                        (equal (bookmark-gt-filename-of r) src))
                                      bookmark-alist))
                   (other (seq-find (lambda (r) (not (eq r tracked)))
                                    bookmark-alist))
                   (bookmark-gt-track-renames t))
              (bookmark-gt--rename-file-advice #'rename-file src dst)
              (should (equal (bookmark-gt-filename-of tracked) dst))
              (should (equal (bookmark-gt-filename-of other)
                             "/tmp/elsewhere.txt"))))
        (delete-directory dir t)))))

;;;; Record-taking API rejects names

(ert-deftest bookmark-gt-same-name-test-record-api-rejects-names ()
  "The record-taking helpers signal rather than resolve a name."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "solo" 'h nil)
    (should-error (bookmark-gt-delete-record "solo"))
    (should-error (bookmark-gt-rename-record "solo" "other"))
    (should-error (bookmark-gt-jump-record "solo"))))

;;;; Name-taking commands ask rather than take the first

(ert-deftest bookmark-gt-same-name-test-relocate-refuses-ambiguous-name ()
  "Given an ambiguous name, relocate resolves rather than taking one.
Batch mode cannot prompt, so the resolution signals."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-same-name-test--pair)
    (should-error (bookmark-gt-relocate "todo"))))

(ert-deftest bookmark-gt-same-name-test-toggle-temp-refuses-ambiguous-name ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-same-name-test--pair)
    (should-error (bookmark-gt-toggle-temp "todo"))))

(ert-deftest bookmark-gt-same-name-test-toggles-take-a-record ()
  "Given the record, each toggle acts on it and leaves its namesake alone."
  (bookmark-gt-test-with-clean-bookmarks
    (pcase-let ((`(,a ,b) (bookmark-gt-same-name-test--pair)))
      (bookmark-gt-toggle-temp a)
      (should (bookmark-gt-temp-p a))
      (should-not (bookmark-gt-temp-p b)))))

(provide 'bookmark-gt-same-name-tests)

;;; bookmark-gt-same-name-tests.el ends here
