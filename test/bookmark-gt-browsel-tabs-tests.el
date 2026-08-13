;;; bookmark-gt-browsel-tabs-tests.el --- Tests for browser-tab handler   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the browser-tab handler classify + jump dispatch, the
;; store helper (record shape), the accept-filter DSL, and the
;; clear helper.  browsel is mocked via `cl-letf' so these tests
;; run without the real websocket bridge.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-browsel-tabs)

;;;; Registry classification
;;
;; Records stored by this module use the URL handler; they classify
;; as type `url'.  External browser-tab handlers registered as
;; aliases (`browsel-tab-manager-bookmark-jump' etc.) still
;; classify as `browser-tab' for records that carry those handlers.

(ert-deftest bookmark-gt-browsel-test-own-records-classify-as-url ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browsel-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "1"
           :browsel-browser "chrome"))
    (let ((record (car bookmark-alist)))
      (should (eq (bookmark-gt-handler-type record) 'url))
      (should (bookmark-gt-browsel-tabs--own-record-p record)))))

(ert-deftest bookmark-gt-browsel-test-predicate ()
  "External browser-tab handlers still classify as `browser-tab'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "external" 'browsel-tab-manager-bookmark-jump nil)
    (bookmark-gt-set-non-file "url"      'bookmark-gt-handler-url-jump nil)
    (should (bookmark-gt-handler-browser-tab-p
             (assoc "external" bookmark-alist)))
    (should-not (bookmark-gt-handler-browser-tab-p
                 (assoc "url" bookmark-alist)))))

;;;; Store shape

(ert-deftest bookmark-gt-browsel-test-store-shape ()
  "The store helper builds a temp record with the expected props."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browsel-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "42"
           :browsel-browser "chrome"))
    (let ((record (car bookmark-alist)))
      (should (equal (car record) "Example"))
      (should (equal (bookmark-prop-get record 'url) "https://example.org"))
      (should (equal (bookmark-prop-get record 'browsel-id) "42"))
      (should (equal (bookmark-prop-get record 'browsel-browser) "chrome"))
      (should (bookmark-gt-temp-p record))
      (should (equal (bookmark-gt-tags-of record) '("chrome"))))))

(ert-deftest bookmark-gt-browsel-test-store-empty-title-uses-url ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browsel-tabs--store
     (list :url "https://example.org"
           :title ""
           :id "1"
           :browsel-browser "firefox"))
    (should (equal (caar bookmark-alist) "https://example.org"))))

;;;; Accept filter

(ert-deftest bookmark-gt-browsel-test-filter-nil-accepts-all ()
  (let ((bookmark-gt-browsel-tabs-filter nil))
    (should (bookmark-gt-browsel-tabs--accept-p
             (list :url "https://example.org")))))

(ert-deftest bookmark-gt-browsel-test-filter-regexp ()
  (let ((bookmark-gt-browsel-tabs-filter "example\\.org"))
    (should (bookmark-gt-browsel-tabs--accept-p
             (list :url "https://example.org/page")))
    (should-not (bookmark-gt-browsel-tabs--accept-p
                 (list :url "https://other.com")))))

(ert-deftest bookmark-gt-browsel-test-filter-function ()
  (let ((bookmark-gt-browsel-tabs-filter
         (lambda (tab)
           (string= (plist-get tab :browsel-browser) "chrome"))))
    (should (bookmark-gt-browsel-tabs--accept-p
             (list :url "x" :browsel-browser "chrome")))
    (should-not (bookmark-gt-browsel-tabs--accept-p
                 (list :url "x" :browsel-browser "firefox")))))

;;;; Clear

(ert-deftest bookmark-gt-browsel-test-clear-removes-only-marked ()
  "`--clear' removes only records carrying the module's marker."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "keep" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (bookmark-gt-browsel-tabs--store
     (list :url "https://tab.example"
           :title "Tab"
           :id "1"
           :browsel-browser "chrome"))
    (bookmark-gt-browsel-tabs--clear)
    (should (= (length bookmark-alist) 1))
    (should (equal (caar bookmark-alist) "keep"))))

(provide 'bookmark-gt-browsel-tabs-tests)
;;; bookmark-gt-browsel-tabs-tests.el ends here
