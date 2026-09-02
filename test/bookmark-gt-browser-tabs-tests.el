;;; bookmark-gt-browser-tabs-tests.el --- Tests for browser-tab handler   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the browser-tab handler classify + jump dispatch, the
;; store helper (record shape), the accept-filter DSL, and the
;; clear helper.  browser-gt is mocked via `cl-letf' so these tests
;; run without the real websocket bridge.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-browser-tabs)

;;;; Registry classification
;;
;; Records stored by this module use the URL handler; they classify
;; as type `url'.  External browser-tab handlers registered as
;; aliases (`browser-gt-tab-manager-bookmark-jump' etc.) still
;; classify as `browser-tab' for records that carry those handlers.

(ert-deftest bookmark-gt-browser-gt-test-own-records-classify-as-url ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browser-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "1"
           :browser-gt-browser "chrome"))
    (let ((record (car bookmark-alist)))
      (should (eq (bookmark-gt-handler-type record) 'url))
      (should (bookmark-gt-browser-tabs--own-record-p record)))))

(ert-deftest bookmark-gt-browser-gt-test-predicate ()
  "External browser-tab handlers still classify as `browser-tab'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "external" 'browser-gt-tab-manager-bookmark-jump nil)
    (bookmark-gt-create-non-file "url"      'bookmark-gt-handler-url-jump nil)
    (should (bookmark-gt-handler-browser-tab-p
             (assoc "external" bookmark-alist)))
    (should-not (bookmark-gt-handler-browser-tab-p
                 (assoc "url" bookmark-alist)))))

;;;; Store shape

(ert-deftest bookmark-gt-browser-gt-test-store-shape ()
  "The store helper builds a temp record with the expected props."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browser-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "42"
           :browser-gt-browser "chrome"))
    (let ((record (car bookmark-alist)))
      (should (equal (car record) "Example"))
      (should (equal (bookmark-prop-get record 'url) "https://example.org"))
      (should (equal (bookmark-prop-get record 'browser-gt-id) "42"))
      (should (equal (bookmark-prop-get record 'browser-gt-browser) "chrome"))
      (should (bookmark-gt-temp-p record))
      (should (equal (bookmark-gt-tags-of record) '("chrome"))))))

(ert-deftest bookmark-gt-browser-gt-test-store-seeds-last-visited-from-accessed ()
  "The tab's `:lastAccessed' (ms) becomes the record's `last-visited'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browser-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "1"
           :browser-gt-browser "chrome"
           :lastAccessed 1785939461849.99))
    (let* ((record (car bookmark-alist))
           (lv (bookmark-prop-get record 'last-visited)))
      (should lv)
      (should (equal (time-convert lv 'integer) 1785939461)))))

(ert-deftest bookmark-gt-browser-gt-test-store-omits-last-visited-when-absent ()
  "A tab plist without `:lastAccessed' produces a record without `last-visited'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browser-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "1"
           :browser-gt-browser "chrome"))
    (should-not (bookmark-prop-get (car bookmark-alist) 'last-visited))))

(ert-deftest bookmark-gt-browser-gt-test-store-empty-title-uses-url ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browser-tabs--store
     (list :url "https://example.org"
           :title ""
           :id "1"
           :browser-gt-browser "firefox"))
    (should (equal (caar bookmark-alist) "https://example.org"))))

;;;; Accept filter

(ert-deftest bookmark-gt-browser-gt-test-filter-nil-accepts-all ()
  (let ((bookmark-gt-browser-tabs-filter nil))
    (should (bookmark-gt-browser-tabs--accept-p
             (list :url "https://example.org")))))

(ert-deftest bookmark-gt-browser-gt-test-filter-regexp ()
  (let ((bookmark-gt-browser-tabs-filter "example\\.org"))
    (should (bookmark-gt-browser-tabs--accept-p
             (list :url "https://example.org/page")))
    (should-not (bookmark-gt-browser-tabs--accept-p
                 (list :url "https://other.com")))))

(ert-deftest bookmark-gt-browser-gt-test-filter-function ()
  (let ((bookmark-gt-browser-tabs-filter
         (lambda (tab)
           (string= (plist-get tab :browser-gt-browser) "chrome"))))
    (should (bookmark-gt-browser-tabs--accept-p
             (list :url "x" :browser-gt-browser "chrome")))
    (should-not (bookmark-gt-browser-tabs--accept-p
                 (list :url "x" :browser-gt-browser "firefox")))))

;;;; Clear

(ert-deftest bookmark-gt-browser-gt-test-clear-removes-only-marked ()
  "`--clear' removes only records carrying the module's marker."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "keep" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (bookmark-gt-browser-tabs--store
     (list :url "https://tab.example"
           :title "Tab"
           :id "1"
           :browser-gt-browser "chrome"))
    (bookmark-gt-browser-tabs--clear)
    (should (= (length bookmark-alist) 1))
    (should (equal (caar bookmark-alist) "keep"))))

;;;; browser-gt keys are not written to the bookmark file
;;
;; A tab record carries three keys valid only for the session that
;; produced it: the tab id, the name of its client, and the marker
;; `--clear' uses to delete the record on the next refresh.

(ert-deftest bookmark-gt-browser-gt-test-props-registered-session-only ()
  "Loading this module registers its keys as session-only."
  (dolist (key '(browser-gt-id browser-gt-browser bookmark-gt-browser-tab))
    (should (memq key bookmark-gt-session-only-props))))

(ert-deftest bookmark-gt-browser-gt-test-made-permanent-converts-to-url ()
  "Making a tab bookmark permanent converts it into a URL bookmark.
The module's marker must be removed too: `--clear' runs on every
refresh and deletes every record that still carries it."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browser-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "42"
           :browser-gt-browser "chrome"))
    (bookmark-gt-toggle-temp "Example")
    (let ((record (assoc "Example" bookmark-alist)))
      (should-not (bookmark-gt-temp-p record))
      (should-not (bookmark-prop-get record 'browser-gt-id))
      (should-not (bookmark-prop-get record 'browser-gt-browser))
      (should-not (bookmark-gt-browser-tabs--own-record-p record))
      ;; What a URL bookmark needs is still there.
      (should (equal (bookmark-gt-url-of record) "https://example.org"))
      (should (eq (bookmark-prop-get record 'handler)
                  'bookmark-gt-handler-url-jump)))
    (bookmark-gt-browser-tabs--clear)
    (should (assoc "Example" bookmark-alist))))

(ert-deftest bookmark-gt-browser-gt-test-made-permanent-saves-as-url ()
  "A tab bookmark made permanent is written to the file as a URL bookmark."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-browser-tabs--store
     (list :url "https://example.org"
           :title "Example"
           :id "42"
           :browser-gt-browser "chrome"))
    (bookmark-gt-toggle-temp "Example")
    (let ((was-enabled bookmark-gt-mode))
      (unwind-protect
          (progn
            (unless was-enabled (bookmark-gt-mode 1))
            (bookmark-save nil bookmark-default-file t))
        (unless was-enabled (bookmark-gt-mode -1))))
    (with-temp-buffer
      (insert-file-contents bookmark-default-file)
      (should-not (search-forward "browser-gt" nil t))
      (goto-char (point-min))
      (should (search-forward "https://example.org" nil t)))))

(provide 'bookmark-gt-browser-tabs-tests)
;;; bookmark-gt-browser-tabs-tests.el ends here
