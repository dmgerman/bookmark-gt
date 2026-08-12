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

(ert-deftest bookmark-gt-browsel-test-classify ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t"
                              'bookmark-gt-handler-browser-tab-jump
                              '((url . "https://example.org")
                                (browsel-id . "1")
                                (browsel-browser . "chrome")))
    (let ((record (car bookmark-alist)))
      (should (eq (bookmark-gt-handler-type record) 'browser-tab))
      (should (equal (bookmark-gt-handler-name record) "BrowserTab"))
      (should (eq (plist-get (cdr (bookmark-gt-handler-classify record))
                             :narrow-char)
                  ?b)))))

(ert-deftest bookmark-gt-browsel-test-predicate ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t" 'bookmark-gt-handler-browser-tab-jump nil)
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump nil)
    (should (bookmark-gt-handler-browser-tab-p (assoc "t" bookmark-alist)))
    (should-not (bookmark-gt-handler-browser-tab-p
                 (assoc "u" bookmark-alist)))))

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

(ert-deftest bookmark-gt-browsel-test-clear-removes-only-tabs ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "keep" 'h nil)
    (bookmark-gt-set-non-file "tab"
                              'bookmark-gt-handler-browser-tab-jump nil)
    (bookmark-gt-browsel-tabs--clear)
    (should (= (length bookmark-alist) 1))
    (should (equal (caar bookmark-alist) "keep"))))

;;;; Jump dispatch

(ert-deftest bookmark-gt-browsel-test-jump-focuses-tab ()
  "The handler calls `browsel-focus-tab' with id + browser."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t" 'bookmark-gt-handler-browser-tab-jump
                              '((url . "https://x")
                                (browsel-id . "id-1")
                                (browsel-browser . "chrome")))
    (let (focused)
      (cl-letf (((symbol-function 'featurep)
                 (lambda (feat &rest _) (eq feat 'browsel)))
                ((symbol-function 'browsel-focus-tab)
                 (lambda (tab &rest _) (push tab focused))))
        (bookmark-gt-handler-browser-tab-jump (car bookmark-alist)))
      (should (= (length focused) 1))
      (should (equal (plist-get (car focused) :id) "id-1")))))

(ert-deftest bookmark-gt-browsel-test-jump-falls-back-to-url ()
  "When focus-tab signals `user-error', fall back to `browsel-browse-url'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t" 'bookmark-gt-handler-browser-tab-jump
                              '((url . "https://example.org")
                                (browsel-id . "gone")
                                (browsel-browser . "chrome")))
    (let (opened)
      (cl-letf (((symbol-function 'featurep)
                 (lambda (feat &rest _) (eq feat 'browsel)))
                ((symbol-function 'browsel-focus-tab)
                 (lambda (&rest _) (user-error "closed")))
                ((symbol-function 'browsel-browse-url)
                 (lambda (url &rest _) (push url opened))))
        (bookmark-gt-handler-browser-tab-jump (car bookmark-alist)))
      (should (equal opened '("https://example.org"))))))

(provide 'bookmark-gt-browsel-tabs-tests)
;;; bookmark-gt-browsel-tabs-tests.el ends here
