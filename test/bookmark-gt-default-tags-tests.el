;;; bookmark-gt-default-tags-tests.el --- Tests for default-tags   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for shape classification, resolution over each DSL shape,
;; and the hook's contribution to the tag-reader chain.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-default-tags)

;;;; Kind classifier

(ert-deftest bookmark-gt-default-tags-test-kind ()
  (should (eq (bookmark-gt-default-tags--kind nil) 'empty))
  (should (eq (bookmark-gt-default-tags--kind "one") 'bare))
  (should (eq (bookmark-gt-default-tags--kind '("a" "b")) 'flat))
  (should (eq (bookmark-gt-default-tags--kind #'ignore) 'function))
  (should (eq (bookmark-gt-default-tags--kind 42) 'unknown))
  (should (eq (bookmark-gt-default-tags--kind '((a . 1))) 'unknown)))

;;;; Resolver

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

;;;; Hook contribution

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

;;;; End-to-end via bookmark-gt-set-non-file

(ert-deftest bookmark-gt-default-tags-test-applied-during-set ()
  "With the mode on, `bookmark-gt-set-non-file' applies defaults."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-default-tags '("auto"))
          (bookmark-gt-default-tags-mode t))
      (bookmark-gt-set-non-file "x" 'h nil)
      (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                     '("auto"))))))

(ert-deftest bookmark-gt-default-tags-test-caller-seed-composes-with-defaults ()
  "Tags contributed by a third-party hook compose with defaults."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-default-tags '("auto"))
          (bookmark-gt-default-tags-mode t)
          (bookmark-gt-set-tag-reader-hook
           ;; Third-party contributor that appends "manual"; the
           ;; default-tags contribution runs first and returns
           ;; ("auto"), then this appends.
           (list (lambda (_rec seed) (append seed '("manual"))))))
      (bookmark-gt-set-non-file "x" 'h nil)
      (should (equal (bookmark-gt-tags-of (car bookmark-alist))
                     '("auto" "manual"))))))

(provide 'bookmark-gt-default-tags-tests)
;;; bookmark-gt-default-tags-tests.el ends here
