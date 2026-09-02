;;; bookmark-gt-handlers-tests.el --- Tests for bookmark-gt-handlers   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the handler registry (handler-symbol-keyed alist +
;; derive-entry fallback), the type accessors, and the URL handler
;; bookmark-gt owns end-to-end.  Registry entries are (HANDLER
;; . PLIST) cons cells; callers query via
;; `bookmark-gt-handler-type' / `-name' / `-face' rather than
;; unpacking the cons directly.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-handlers)

;;;; Registry classification — direct handler symbols

(ert-deftest bookmark-gt-test-classify-url ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "example" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (let ((record (car bookmark-alist)))
      (should (eq (bookmark-gt-handler-type record) 'url))
      (should (equal (bookmark-gt-handler-name record) "URL")))))

(ert-deftest bookmark-gt-test-classify-file-null-handler ()
  "A record with no `handler' classifies as file."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "built-in" nil
                              '((filename . "/tmp/foo")
                                (position . 1)))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'file))))

(ert-deftest bookmark-gt-test-classify-file-explicit-default ()
  "`bookmark-default-handler' also classifies as file (alias)."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "built-in" 'bookmark-default-handler
     '((filename . "/tmp/foo") (position . 1)))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'file))))

(ert-deftest bookmark-gt-test-classify-eww ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "page" 'eww-bookmark-jump nil)
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'eww))))

;;;; Registry classification — alias handler symbols share a type

(ert-deftest bookmark-gt-test-classify-bookmark-plus-url-alias ()
  "bookmark+'s `bmkp-jump-url-browse' classifies as :type url."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bmkp-jump-url-browse
                              '((location . "https://example.org")))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'url))
    (should (bookmark-gt-handler-url-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-test-classify-bookmark-plus-dired-alias ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "d" 'bmkp-jump-dired nil)
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'dired))
    (should (bookmark-gt-handler-dired-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-test-classify-browser-gt-tab-manager-alias ()
  "`browser-gt-tab-manager-bookmark-jump' classifies as browser-tab."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "t" 'browser-gt-tab-manager-bookmark-jump nil)
    (should (eq (bookmark-gt-handler-type (car bookmark-alist))
                'browser-tab))
    (should (bookmark-gt-handler-browser-tab-p (car bookmark-alist)))))

;;;; Derive-entry fallback for unregistered handlers

(ert-deftest bookmark-gt-test-derive-entry-strips-jump-handler-suffix ()
  (let ((entry (bookmark-gt--handler-derive-entry
                'nov-bookmark-jump-handler)))
    (should (equal (plist-get (cdr entry) :name) "Nov"))
    (should (eq (plist-get (cdr entry) :type) 'nov))))

(ert-deftest bookmark-gt-test-derive-entry-strips-handle-bookmark-suffix ()
  (let ((entry (bookmark-gt--handler-derive-entry
                'someunknown--handle-bookmark)))
    (should (equal (plist-get (cdr entry) :name) "Someunknown"))))

(ert-deftest bookmark-gt-test-derive-entry-unknown-nil ()
  (let ((entry (bookmark-gt--handler-derive-entry nil)))
    (should (equal (plist-get (cdr entry) :name) "Unknown"))))

(ert-deftest bookmark-gt-test-classify-unknown-falls-back ()
  "An unregistered handler still classifies (via derive)."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "x" 'brand-new-bookmark-jump nil)
    (should (equal (bookmark-gt-handler-name (car bookmark-alist))
                   "Brand"))))

;;;; Type-based predicates

(ert-deftest bookmark-gt-test-url-p-recognizes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (should (bookmark-gt-handler-url-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-test-file-p-recognizes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "f" nil
                              '((filename . "/tmp/f") (position . 1)))
    (should (bookmark-gt-handler-file-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-test-predicates-cover-every-registered-type ()
  "Each registered type has a matching `bookmark-gt-handler-<type>-p'.
A `bookmark-gt-' prefix on the type symbol is stripped when
deriving the predicate name so namespaced types (e.g.
`bookmark-gt-view') get a readable predicate (`-view-p').
Prevents drift where a new type is registered but no predicate
is added alongside it."
  (dolist (entry bookmark-gt-handler-alist)
    (let* ((type (plist-get (cdr entry) :type))
           (short (and type
                       (replace-regexp-in-string
                        "\\`bookmark-gt-" "" (symbol-name type))))
           (name (and short
                      (intern (format "bookmark-gt-handler-%s-p" short)))))
      (when type
        (should (fboundp name))))))

(ert-deftest bookmark-gt-test-added-predicates-recognize ()
  "Smoke-test the six predicates added for completeness."
  (bookmark-gt-test-with-clean-bookmarks
    (dolist (case '((magit-p    magit--handle-bookmark)
                    (help-p     help-bookmark-jump)
                    (image-p    image-bookmark-jump)
                    (epub-p     nov-bookmark-jump-handler)
                    (function-p bookmark-gt-handler-function-jump)
                    (sequence-p bookmark-gt-handler-sequence-jump)))
      (let ((bookmark-alist nil))
        (bookmark-gt-create-non-file (symbol-name (car case)) (cadr case) nil)
        (should (funcall (intern (format "bookmark-gt-handler-%s"
                                         (car case)))
                         (car bookmark-alist)))))))

;;;; URL handler

(ert-deftest bookmark-gt-test-url-jump-invokes-browse-url ()
  "The URL handler calls `browse-url' with the record's URL."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (let (seen)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url seen))))
        (bookmark-gt-handler-url-jump (car bookmark-alist)))
      (should (equal seen '("https://example.org"))))))

(ert-deftest bookmark-gt-test-url-jump-reads-location-fallback ()
  "The URL handler falls back on the `location' prop (bookmark+ compat)."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((location . "https://legacy.example")))
    (let (seen)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url seen))))
        (bookmark-gt-handler-url-jump (car bookmark-alist)))
      (should (equal seen '("https://legacy.example"))))))

(ert-deftest bookmark-gt-test-url-jump-missing-url-errors ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump nil)
    (should-error (bookmark-gt-handler-url-jump (car bookmark-alist))
                  :type 'user-error)))

;;;; Save / load round-trip

(ert-deftest bookmark-gt-test-url-survives-save-load ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (bookmark-save)
    (let ((bookmark-alist nil))
      (bookmark-load bookmark-default-file t t nil)
      (should (bookmark-gt-handler-url-p (car bookmark-alist)))
      (should (equal (bookmark-prop-get (car bookmark-alist) 'url)
                     "https://example.org"))
      (should-not (bookmark-prop-get (car bookmark-alist) 'filename)))))

;;;; Placeholder filename compat

(ert-deftest bookmark-gt-test-filename-of-skips-placeholder ()
  "`bookmark-gt-filename-of' treats the bookmark+ placeholder as absent."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "legacy" 'bmkp-jump-url-browse
     `((filename . ,bookmark-gt-non-file-placeholder)
       (location . "https://example.org")))
    (should (null (bookmark-gt-filename-of (car bookmark-alist))))
    (should (equal (bookmark-gt-url-of (car bookmark-alist))
                   "https://example.org"))))

;;;; Function bookmarks

(ert-deftest bookmark-gt-handlers-test-function-jump-calls-fn ()
  "Jumping a function bookmark invokes the stored callable."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((called 0))
      (bookmark-gt-create-function "fn" (lambda () (setq called (1+ called))))
      (condition-case _err
          (bookmark-gt-handler-function-jump (car bookmark-alist))
        (no-catch nil))
      (should (= called 1)))))

(ert-deftest bookmark-gt-handlers-test-function-classify ()
  "Function bookmarks classify as `function' via the registry."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-function "fn" (function ignore))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'function))
    (should (equal (bookmark-gt-handler-name (car bookmark-alist))
                   "Function"))))

(ert-deftest bookmark-gt-handlers-test-function-missing-signals ()
  "A function bookmark with no callable signals a user error."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "fn" (quote bookmark-gt-handler-function-jump) nil)
    (should-error
     (condition-case err
         (bookmark-gt-handler-function-jump (car bookmark-alist))
       (no-catch (signal 'user-error nil)))
     :type 'user-error)))

;;;; Sequence bookmarks

(ert-deftest bookmark-gt-handlers-test-sequence-jump-visits-each ()
  "Jumping a sequence bookmark visits each member record in order."
  (bookmark-gt-test-with-clean-bookmarks
    (let (jumped)
      ;; Create three placeholder bookmarks the sequence will reference.
      (dolist (n '("a" "b" "c"))
        (bookmark-gt-create-non-file n (function ignore) nil))
      (bookmark-gt-create-sequence "seq" (list "a" "b" "c"))
      (cl-letf (((symbol-function 'bookmark-gt-jump-record)
                 (lambda (record &rest _)
                   (push (bookmark-name-from-full-record record) jumped))))
        (condition-case _err
            (bookmark-gt-handler-sequence-jump
             (assoc "seq" bookmark-alist))
          (no-catch nil)))
      (should (equal (nreverse jumped) '("a" "b" "c"))))))

(ert-deftest bookmark-gt-handlers-test-sequence-members-become-ids ()
  "Members stored as names are converted to ids by the id scan."
  (bookmark-gt-test-with-clean-bookmarks
    (dolist (n '("a" "b"))
      (bookmark-gt-create-non-file n (function ignore) nil))
    (bookmark-gt-create-sequence "seq" (list "a" "b"))
    (let ((seq (assoc "seq" bookmark-alist)))
      ;; Written as names, converted on the next scan.
      (bookmark-prop-set seq 'sequence (list "a" "b"))
      (bookmark-gt-ensure-ids)
      (should (equal (bookmark-prop-get seq 'sequence)
                     (list (bookmark-gt-id-of (bookmark-get-bookmark "a"))
                           (bookmark-gt-id-of (bookmark-get-bookmark "b"))))))))

(ert-deftest bookmark-gt-handlers-test-sequence-member-survives-rename ()
  "A member referenced by id still resolves after the member is renamed."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" (function ignore) nil)
    (bookmark-gt-create-sequence "seq" (list "a"))
    (bookmark-gt-ensure-ids)
    (let ((member (bookmark-get-bookmark "a"))
          (seq (assoc "seq" bookmark-alist)))
      (bookmark-gt-rename-record member "renamed")
      (should (eq (bookmark-gt--resolve
                   (car (bookmark-prop-get seq 'sequence)))
                  member)))))

(ert-deftest bookmark-gt-handlers-test-sequence-classify ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "x" (function ignore) nil)
    (bookmark-gt-create-sequence "seq" '("x"))
    (should (eq (bookmark-gt-handler-type (assoc "seq" bookmark-alist))
                'sequence))))

(provide 'bookmark-gt-handlers-tests)
;;; bookmark-gt-handlers-tests.el ends here
