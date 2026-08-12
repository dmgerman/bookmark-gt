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
(require 'test-helper)
(require 'bookmark-gt-handlers)

;;;; Registry classification — direct handler symbols

(ert-deftest bookmark-gt-test-classify-url ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "example" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (let ((record (car bookmark-alist)))
      (should (eq (bookmark-gt-handler-type record) 'url))
      (should (equal (bookmark-gt-handler-name record) "URL")))))

(ert-deftest bookmark-gt-test-classify-file-null-handler ()
  "A record with no `handler' classifies as file."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "vanilla" nil
                              '((filename . "/tmp/foo")
                                (position . 1)))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'file))))

(ert-deftest bookmark-gt-test-classify-file-explicit-default ()
  "`bookmark-default-handler' also classifies as file (alias)."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "vanilla" 'bookmark-default-handler
     '((filename . "/tmp/foo") (position . 1)))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'file))))

(ert-deftest bookmark-gt-test-classify-eww ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "page" 'eww-bookmark-jump nil)
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'eww))))

;;;; Registry classification — alias handler symbols share a type

(ert-deftest bookmark-gt-test-classify-bookmark-plus-url-alias ()
  "bookmark+'s `bmkp-jump-url-browse' classifies as :type url."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bmkp-jump-url-browse
                              '((location . "https://example.org")))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'url))
    (should (bookmark-gt-handler-url-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-test-classify-bookmark-plus-dired-alias ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "d" 'bmkp-jump-dired nil)
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'dired))
    (should (bookmark-gt-handler-dired-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-test-classify-browsel-tab-manager-alias ()
  "`browsel-tab-manager-bookmark-jump' classifies as browser-tab."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t" 'browsel-tab-manager-bookmark-jump nil)
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
    (bookmark-gt-set-non-file "x" 'brand-new-bookmark-jump nil)
    (should (equal (bookmark-gt-handler-name (car bookmark-alist))
                   "Brand"))))

;;;; Type-based predicates

(ert-deftest bookmark-gt-test-url-p-recognizes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (should (bookmark-gt-handler-url-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-test-file-p-recognizes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "f" nil
                              '((filename . "/tmp/f") (position . 1)))
    (should (bookmark-gt-handler-file-p (car bookmark-alist)))))

;;;; URL handler

(ert-deftest bookmark-gt-test-url-jump-invokes-browse-url ()
  "The URL handler calls `browse-url' with the record's URL."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
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
    (bookmark-gt-set-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((location . "https://legacy.example")))
    (let (seen)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url seen))))
        (bookmark-gt-handler-url-jump (car bookmark-alist)))
      (should (equal seen '("https://legacy.example"))))))

(ert-deftest bookmark-gt-test-url-jump-missing-url-errors ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump nil)
    (should-error (bookmark-gt-handler-url-jump (car bookmark-alist))
                  :type 'user-error)))

;;;; Save / load round-trip

(ert-deftest bookmark-gt-test-url-survives-save-load ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
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
    (bookmark-gt-set-non-file
     "legacy" 'bmkp-jump-url-browse
     `((filename . ,bookmark-gt-non-file-placeholder)
       (location . "https://example.org")))
    (should (null (bookmark-gt-filename-of (car bookmark-alist))))
    (should (equal (bookmark-gt-url-of (car bookmark-alist))
                   "https://example.org"))))

(provide 'bookmark-gt-handlers-tests)
;;; bookmark-gt-handlers-tests.el ends here
