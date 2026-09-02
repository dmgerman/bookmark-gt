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
    (let ((bookmark-gt-current-bookmark (bookmark-get-bookmark "b")))
      (bookmark-gt--on-jump-record-visit)
      (should (= (bookmark-prop-get "b" 'visits) 1)))))

(ert-deftest bookmark-gt-visit-test-hook-no-current-is-noop ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "b" 'h nil)
    (let ((bookmark-gt-current-bookmark nil))
      (bookmark-gt--on-jump-record-visit))
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
        (add-hook (quote bookmark-after-jump-hook) (function bookmark-gt--on-jump-record-visit))
        (should (memq #'bookmark-gt--on-jump-record-visit
                      bookmark-after-jump-hook))
        (remove-hook (quote bookmark-after-jump-hook) (function bookmark-gt--on-jump-record-visit))
        (should-not (memq #'bookmark-gt--on-jump-record-visit
                          bookmark-after-jump-hook)))
    (remove-hook 'bookmark-after-jump-hook
                 #'bookmark-gt--on-jump-record-visit)))

;;;; Handler path — URL

(ert-deftest bookmark-gt-visit-test-url-handler-records-visit ()
  "URL bookmarks get their visit counted on jump.
Verifies the after-jump-hook path: with `bookmark-gt-mode' on,
`bookmark--jump-via' is overridden so
`bookmark-after-jump-hook' runs even when the URL handler
throws `bookmark-gt-skip-post-handler'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "u" 'bookmark-gt-handler-url-jump
     '((url . "https://example.org")))
    (let ((was-enabled bookmark-gt-mode))
      (unwind-protect
          (progn
            (unless was-enabled (bookmark-gt-mode 1))
            (cl-letf (((symbol-function 'browse-url) (lambda (&rest _) nil)))
              (bookmark-jump "u"))
            (should (= (bookmark-prop-get "u" 'visits) 1)))
        (unless was-enabled (bookmark-gt-mode -1))))))

(provide 'bookmark-gt-visit-tests)
;;; bookmark-gt-visit-tests.el ends here
