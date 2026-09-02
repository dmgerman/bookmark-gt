;;; bookmark-gt-temp-tests.el --- Tests for temp bookmarks (core)   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the `bmkp-temp' alist key predicate, the toggle
;; mutator, and the `bookmark-save' filter that excludes temp
;; records from the on-disk file.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-core)

;;;; Predicate + toggle

(ert-deftest bookmark-gt-temp-test-p ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "plain" 'h nil)
    (bookmark-gt-create-non-file "temp"  'h (list (cons bookmark-gt-temp-key t)))
    (should-not (bookmark-gt-temp-p (assoc "plain" bookmark-alist)))
    (should     (bookmark-gt-temp-p (assoc "temp" bookmark-alist)))))

(ert-deftest bookmark-gt-temp-test-toggle-adds-and-removes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h nil)
    (bookmark-gt-toggle-temp "b")
    (should (bookmark-gt-temp-p (assoc "b" bookmark-alist)))
    (bookmark-gt-toggle-temp "b")
    (should-not (bookmark-gt-temp-p (assoc "b" bookmark-alist)))))

(ert-deftest bookmark-gt-temp-test-toggle-fires-after-hook ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h nil)
    (let (seen)
      (add-hook 'bookmark-gt-record-changed-hook
                (lambda (entry &optional _op) (push entry seen)))
      (bookmark-gt-toggle-temp "b")
      (should (= (length seen) 1)))))

;;;; Modification accounting
;;
;; A change confined to temp records never reaches the bookmark
;; file, so it must not raise
;; `bookmark-alist-modification-count' — that count is what makes
;; `kill-emacs-hook' write the file on exit.

(ert-deftest bookmark-gt-temp-test-store-does-not-count ()
  "Storing a temp record leaves the modification count alone."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((before bookmark-alist-modification-count))
      (bookmark-gt-create-non-file "temp" 'h
                                (list (cons bookmark-gt-temp-key t)))
      (should (= bookmark-alist-modification-count before)))))

(ert-deftest bookmark-gt-temp-test-store-non-temp-counts ()
  "Storing an ordinary record still raises the modification count."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((before bookmark-alist-modification-count))
      (bookmark-gt-create-non-file "plain" 'h nil)
      (should (= bookmark-alist-modification-count (1+ before))))))

(ert-deftest bookmark-gt-temp-test-toggle-counts-both-directions ()
  "Setting and clearing the temp flag each count as one change."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h nil)
    (let ((before bookmark-alist-modification-count))
      (bookmark-gt-toggle-temp "b")
      (should (= bookmark-alist-modification-count (1+ before)))
      (bookmark-gt-toggle-temp "b")
      (should (= bookmark-alist-modification-count (+ 2 before))))))

(ert-deftest bookmark-gt-temp-test-set-temp-no-op-does-not-count ()
  "Setting the flag on a record that already carries it is not a change."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "temp" 'h
                              (list (cons bookmark-gt-temp-key t)))
    (let ((before bookmark-alist-modification-count))
      (bookmark-gt-temp-set (assoc "temp" bookmark-alist) t)
      (should (= bookmark-alist-modification-count before)))))

;;;; Save filter

(ert-deftest bookmark-gt-temp-test-save-filter-drops-temp ()
  "With the filter installed, `bookmark-save' omits temp records."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "keep" 'h nil)
    (bookmark-gt-create-non-file "temp" 'h (list (cons bookmark-gt-temp-key t)))
    (advice-add (quote bookmark-save) :around (function bookmark-gt--save-filter-advice))
    (unwind-protect
        (progn
          (bookmark-save)
          (let ((bookmark-alist nil))
            (bookmark-load bookmark-default-file t t nil)
            (should (= (length bookmark-alist) 1))
            (should (equal (caar bookmark-alist) "keep"))))
      (advice-remove (quote bookmark-save) (function bookmark-gt--save-filter-advice)))))

(ert-deftest bookmark-gt-temp-test-save-filter-preserves-live-alist ()
  "The filter must not mutate the live `bookmark-alist' after save."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "keep" 'h nil)
    (bookmark-gt-create-non-file "temp" 'h (list (cons bookmark-gt-temp-key t)))
    (advice-add (quote bookmark-save) :around (function bookmark-gt--save-filter-advice))
    (unwind-protect
        (progn
          (bookmark-save)
          (should (= (length bookmark-alist) 2))
          (should (bookmark-gt-temp-p (assoc "temp" bookmark-alist))))
      (advice-remove (quote bookmark-save) (function bookmark-gt--save-filter-advice)))))

(ert-deftest bookmark-gt-temp-test-uninstall-restores-built-in ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "keep" 'h nil)
    (bookmark-gt-create-non-file "temp" 'h (list (cons bookmark-gt-temp-key t)))
    (advice-add (quote bookmark-save) :around (function bookmark-gt--save-filter-advice))
    (advice-remove (quote bookmark-save) (function bookmark-gt--save-filter-advice))
    (bookmark-save)
    (let ((bookmark-alist nil))
      (bookmark-load bookmark-default-file t t nil)
      (should (= (length bookmark-alist) 2)))))

(provide 'bookmark-gt-temp-tests)
;;; bookmark-gt-temp-tests.el ends here
