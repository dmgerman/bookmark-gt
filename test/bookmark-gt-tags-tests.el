;;; bookmark-gt-tags-tests.el --- Tests for bookmark-gt-tags   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the tag query, mutation, and normalization API, and for
;; `bookmark-gt-default-tags-mode': shape classification, resolution
;; over each DSL shape, and its contribution to the tag pipeline.

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

;;;; TAGS passed to a create command

(ert-deftest bookmark-gt-tags-test-create-list-is-stored-without-prompt ()
  "A TAGS list is stored as given; the tag reader does not run."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-prompt-for-tags-flag t))
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (&rest _) (error "Reader must not run"))))
        (bookmark-gt-create-url "https://example.org" "site"
                                (list "web" "reference"))))
    (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "site"))
                   '("web" "reference")))))

(ert-deftest bookmark-gt-tags-test-create-t-runs-the-reader ()
  "TAGS t runs the tag pipeline, and the reader's result is stored."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-prompt-for-tags-flag t))
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (_prompt _seed) '("chosen"))))
        (bookmark-gt-create-url "https://example.org" "site" t)))
    (should (equal (bookmark-gt-tags-of (bookmark-get-bookmark "site"))
                   '("chosen")))))

(ert-deftest bookmark-gt-tags-test-create-stores-one-tags-cell ()
  "The pipeline result replaces a `tags' entry in DATA.
Two `tags' cells would leave the stale list on the record but
unreachable, since `bookmark-prop-get' takes the first."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt--create-record "site"
                                '((handler . bookmark-gt-handler-url-jump)
                                  (url . "https://example.org")
                                  (tags . ("web")))
                                (lambda (_data seed) (cons "chosen" seed)))
    (let ((record (bookmark-get-bookmark "site")))
      (should (equal (bookmark-gt-tags-of record) '("chosen" "web")))
      (should (= 1 (seq-count (lambda (cell) (eq (car-safe cell) 'tags))
                              (cdr record)))))))

(ert-deftest bookmark-gt-tags-test-refused-name-signals-before-pipeline ()
  "A name the same-name policy refuses signals before the tag prompt."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'never)
          (bookmark-gt-prompt-for-tags-flag t))
      (bookmark-gt-create-url "https://a.example" "site" nil)
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (&rest _) (error "Reader must not run"))))
        (should-error (bookmark-gt-create-url "https://b.example" "site" t)
                      :type 'user-error)))))

(ert-deftest bookmark-gt-tags-test-create-non-file-skips-pipeline ()
  "`bookmark-gt-create-non-file' applies neither default tags nor the reader."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-default-tags '("auto"))
          (bookmark-gt-default-tags-mode t)
          (bookmark-gt-prompt-for-tags-flag t))
      (cl-letf (((symbol-function 'bookmark-gt-tags-read)
                 (lambda (&rest _) (error "Reader must not run"))))
        (bookmark-gt-create-non-file "x" 'h '((tags . ("given"))))))
    (should (equal (bookmark-gt-tags-of (car bookmark-alist)) '("given")))))

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

;;;; Default tags: kind classifier

(ert-deftest bookmark-gt-default-tags-test-kind ()
  (should (eq (bookmark-gt-default-tags--kind nil) 'empty))
  (should (eq (bookmark-gt-default-tags--kind "one") 'bare))
  (should (eq (bookmark-gt-default-tags--kind '("a" "b")) 'flat))
  (should (eq (bookmark-gt-default-tags--kind #'ignore) 'function))
  (should (eq (bookmark-gt-default-tags--kind 42) 'unknown))
  (should (eq (bookmark-gt-default-tags--kind '((a . 1))) 'unknown)))

;;;; Default tags: resolver

(ert-deftest bookmark-gt-default-tags-test-resolve-empty ()
  (should (null (bookmark-gt-default-tags--resolve nil '((handler . h))))))

(ert-deftest bookmark-gt-default-tags-test-resolve-bare ()
  (should (equal (bookmark-gt-default-tags--resolve "proj" nil)
                 '("proj"))))

(ert-deftest bookmark-gt-default-tags-test-resolve-flat ()
  (should (equal (bookmark-gt-default-tags--resolve '("a" "b") nil)
                 '("a" "b"))))

(ert-deftest bookmark-gt-default-tags-test-resolve-function ()
  "The function form is called with RECORD; return shape is normalized."
  (let ((fn (lambda (_rec) '("x" "y"))))
    (should (equal (bookmark-gt-default-tags--resolve fn nil)
                   '("x" "y")))))

(ert-deftest bookmark-gt-default-tags-test-resolve-function-context-sensitive ()
  "The function receives the record and can dispatch on its properties."
  (let ((fn (lambda (rec)
              (if (eq (alist-get 'handler rec) 'my-h)
                  '("matched")
                '("other")))))
    (should (equal (bookmark-gt-default-tags--resolve
                    fn '((handler . my-h)))
                   '("matched")))
    (should (equal (bookmark-gt-default-tags--resolve
                    fn '((handler . other-h)))
                   '("other")))))

(ert-deftest bookmark-gt-default-tags-test-resolve-function-error-is-warning ()
  "A function that signals returns nil (never propagates)."
  (let ((fn (lambda (_rec) (error "boom"))))
    (let ((warning-minimum-level :emergency))  ; suppress display
      (should (null (bookmark-gt-default-tags--resolve fn nil))))))

(ert-deftest bookmark-gt-default-tags-test-resolve-unknown-is-warning ()
  (let ((warning-minimum-level :emergency))
    (should (null (bookmark-gt-default-tags--resolve 42 nil)))))

;;;; Default tags: hook contribution

(ert-deftest bookmark-gt-default-tags-test-hook-adds-defaults-to-seed ()
  (let ((bookmark-gt-default-tags '("proj")))
    (should (equal (bookmark-gt-default-tags--hook nil '("orig"))
                   '("orig" "proj")))))

(ert-deftest bookmark-gt-default-tags-test-hook-preserves-seed-when-off ()
  (let ((bookmark-gt-default-tags nil))
    (should (equal (bookmark-gt-default-tags--hook nil '("orig"))
                   '("orig")))))

(ert-deftest bookmark-gt-default-tags-test-hook-dedupes ()
  (let ((bookmark-gt-default-tags '("dup")))
    (should (equal (bookmark-gt-default-tags--hook nil '("dup"))
                   '("dup")))))

;;;; Default tags: end-to-end via a creation command

(ert-deftest bookmark-gt-default-tags-test-applied-during-set ()
  "With the mode on, the tag pipeline applies defaults."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-default-tags '("auto"))
          (bookmark-gt-default-tags-mode t))
      (bookmark-gt-create-url "https://example.org" "x" t)
      (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                     '("auto"))))))

(ert-deftest bookmark-gt-default-tags-test-caller-seed-composes-with-defaults ()
  "Tags contributed by a third-party hook compose with defaults."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-default-tags '("auto"))
          (bookmark-gt-default-tags-mode t)
          (bookmark-gt-create-tag-reader-hook
           ;; Third-party contributor that appends "manual"; the
           ;; default-tags contribution runs first and returns
           ;; ("auto"), then this appends.
           (list (lambda (_rec seed) (append seed '("manual"))))))
      (bookmark-gt-create-url "https://example.org" "x" t)
      (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                     '("auto" "manual"))))))

(provide 'bookmark-gt-tags-tests)
;;; bookmark-gt-tags-tests.el ends here
