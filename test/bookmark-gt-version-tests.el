;;; bookmark-gt-version-tests.el --- Tests for bookmark-gt-version   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the `bookmark-gt-version' command: its return value
;; when called from Lisp, the text it inserts under a prefix
;; argument, and the fact that the defconst it reports actually
;; resolved from the `;; Version:' header rather than falling back
;; to "unknown".

;;; Code:

(require 'ert)
(require 'lisp-mnt)
(require 'find-func)
(require 'test-helper)
(require 'bookmark-gt)

(ert-deftest bookmark-gt-version-test-resolved-from-header ()
  "The defconst holds the version written in bookmark-gt.el's header."
  (let ((header (lm-with-file (find-library-name "bookmark-gt")
                  (lm-header "version"))))
    (should (stringp header))
    (should (equal bookmark-gt-version header))
    (should-not (equal bookmark-gt-version "unknown"))))

(ert-deftest bookmark-gt-version-test-is-the-only-header ()
  "No bookmark-gt file other than bookmark-gt.el carries a version."
  (dolist (feature '(bookmark-gt-core bookmark-gt-handlers
                     bookmark-gt-tags bookmark-gt-list
                     bookmark-gt-jump bookmark-gt-auto-update
                     bookmark-gt-default-tags bookmark-gt-browser-tabs))
    (let ((header (lm-with-file (find-library-name (symbol-name feature))
                    (lm-header "version"))))
      (should-not header))))

(ert-deftest bookmark-gt-version-test-returns-version-string ()
  "Called from Lisp, the command returns the bare version string."
  (should (equal (bookmark-gt-version) bookmark-gt-version))
  (should (stringp (bookmark-gt-version))))

(ert-deftest bookmark-gt-version-test-here-inserts-report-line ()
  "With HERE, the command inserts the package and Emacs versions."
  (with-temp-buffer
    (bookmark-gt-version t)
    (let ((text (buffer-string)))
      (should (string-match-p (regexp-quote bookmark-gt-version) text))
      (should (string-match-p (regexp-quote emacs-version) text))
      (should (string-prefix-p "bookmark-gt " text)))))

(ert-deftest bookmark-gt-version-test-here-inserts-at-point ()
  "Insertion happens at point, leaving surrounding text alone."
  (with-temp-buffer
    (insert "[]")
    (goto-char (1- (point-max)))
    (bookmark-gt-version t)
    (should (string-prefix-p "[bookmark-gt " (buffer-string)))
    (should (string-suffix-p "]" (buffer-string)))))

(provide 'bookmark-gt-version-tests)
;;; bookmark-gt-version-tests.el ends here
