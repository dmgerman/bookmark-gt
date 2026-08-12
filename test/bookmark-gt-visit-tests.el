;;; bookmark-gt-visit-tests.el --- Tests for visit tracking   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for `bookmark-gt-record-visit', the after-jump-hook, and
;; the direct calls URL / browser-tab handlers make before their
;; skip-post-handler throw.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-core)
(require 'bookmark-gt-handlers)

;;;; Direct call

(ert-deftest bookmark-gt-visit-test-record-increments-visits ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h nil)
    (should-not (bookmark-prop-get "b" 'visits))
    (bookmark-gt-record-visit "b")
    (should (= (bookmark-prop-get "b" 'visits) 1))
    (bookmark-gt-record-visit "b")
    (should (= (bookmark-prop-get "b" 'visits) 2))))

(ert-deftest bookmark-gt-visit-test-record-sets-last-visited ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h nil)
    (should-not (bookmark-prop-get "b" 'last-visited))
    (bookmark-gt-record-visit "b")
    (should (bookmark-prop-get "b" 'last-visited))))

(ert-deftest bookmark-gt-visit-test-record-accepts-record ()
  "`bookmark-gt-record-visit' also accepts a full record cons."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h nil)
    (bookmark-gt-record-visit (car bookmark-alist))
    (should (= (bookmark-prop-get "b" 'visits) 1))))

;;;; Hook path

(ert-deftest bookmark-gt-visit-test-hook-uses-current-bookmark ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h nil)
    (let ((bookmark-current-bookmark "b"))
      (bookmark-gt--record-visit-hook)
      (should (= (bookmark-prop-get "b" 'visits) 1)))))

(ert-deftest bookmark-gt-visit-test-hook-no-current-is-noop ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h nil)
    (let ((bookmark-current-bookmark nil))
      (bookmark-gt--record-visit-hook))
    (should-not (bookmark-prop-get "b" 'visits))))

;;;; No modification-count bump

(ert-deftest bookmark-gt-visit-test-no-modification-count-bump ()
  "Visit tracking must not trigger auto-save.
`bookmark-alist-modification-count' stays unchanged so
`bookmark-save-flag' numeric thresholds are not crossed per jump."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h nil)
    (let ((before bookmark-alist-modification-count))
      (bookmark-gt-record-visit "b")
      (should (= bookmark-alist-modification-count before)))))

;;;; Install / uninstall

(ert-deftest bookmark-gt-visit-test-install-uninstall ()
  (unwind-protect
      (progn
        (bookmark-gt-install-visit-tracker)
        (should (memq #'bookmark-gt--record-visit-hook
                      bookmark-after-jump-hook))
        (bookmark-gt-uninstall-visit-tracker)
        (should-not (memq #'bookmark-gt--record-visit-hook
                          bookmark-after-jump-hook)))
    (remove-hook 'bookmark-after-jump-hook
                 #'bookmark-gt--record-visit-hook)))

;;;; Handler path — URL

(ert-deftest bookmark-gt-visit-test-url-handler-records-visit ()
  "The URL handler calls `bookmark-gt-record-visit' before its throw."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (cl-letf (((symbol-function 'browse-url) (lambda (&rest _) nil)))
      (bookmark-gt-handler-url-jump (car bookmark-alist)))
    (should (= (bookmark-prop-get "u" 'visits) 1))))

(provide 'bookmark-gt-visit-tests)
;;; bookmark-gt-visit-tests.el ends here
