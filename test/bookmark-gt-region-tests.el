;;; bookmark-gt-region-tests.el --- Tests for region bookmarks   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for region-bookmark capture on `bookmark-gt-set' and
;; region restoration via `bookmark-gt--on-jump-restore-region'.
;; Each test uses a temp file — built-in `bookmark-make-record'
;; refuses to run in a buffer with no `buffer-file-name'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-core)

(defmacro bookmark-gt-region-test--with-file (content &rest body)
  "Run BODY in a live file-visiting buffer containing CONTENT.
The file is created via `make-temp-file' and deleted on exit,
so `bookmark-make-record' has a real `buffer-file-name' to use."
  (declare (indent 1) (debug t))
  `(let ((tmp (make-temp-file "bookmark-gt-region-")))
     (unwind-protect
         (progn
           (with-temp-file tmp (insert ,content))
           (with-current-buffer (find-file-noselect tmp)
             (unwind-protect
                 (progn ,@body)
               (kill-buffer))))
       (delete-file tmp))))

;;;; Capture

(ert-deftest bookmark-gt-region-test-capture-on-active-region ()
  "With use-region t and an active region, set captures end-position."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-region-test--with-file "abcdefghijklmnopqrstuvwxyz"
      (goto-char 5)
      (set-mark 15)
      (activate-mark)
      (let ((bookmark-gt-use-region t))
        (bookmark-gt-set "sel")))
    (let ((rec (car bookmark-alist)))
      (should (= (bookmark-prop-get rec 'position) 5))
      (should (= (bookmark-prop-get rec 'end-position) 15))
      (should (bookmark-prop-get rec 'front-context-region-string))
      (should (bookmark-prop-get rec 'rear-context-region-string)))))

(ert-deftest bookmark-gt-region-test-no-capture-when-flag-off ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-region-test--with-file "abcdefghij"
      (goto-char 3)
      (set-mark 7)
      (activate-mark)
      (let ((bookmark-gt-use-region nil))
        (bookmark-gt-set "no-flag")))
    (should-not (bookmark-prop-get (car bookmark-alist) 'end-position))))

(ert-deftest bookmark-gt-region-test-no-capture-without-region ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-region-test--with-file "abcdefghij"
      (goto-char 3)
      (deactivate-mark)
      (let ((bookmark-gt-use-region t))
        (bookmark-gt-set "no-region")))
    (should-not (bookmark-prop-get (car bookmark-alist) 'end-position))))

;;;; Restore

(ert-deftest bookmark-gt-region-test-restore-pushes-mark ()
  "The hook pushes an active mark at `end-position' when set."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-region-test--with-file "abcdefghijklmnopqrstuvwxyz"
      (goto-char 5)
      (set-mark 15)
      (activate-mark)
      (bookmark-gt-set "sel"))
    (with-temp-buffer
      (insert "abcdefghijklmnopqrstuvwxyz")
      (goto-char 5)
      (deactivate-mark)
      (let ((bookmark-current-bookmark (caar bookmark-alist))
            (bookmark-gt-use-region t))
        (bookmark-gt--on-jump-restore-region))
      (should (mark))
      (should (= (mark) 15))
      (should mark-active))))

(ert-deftest bookmark-gt-region-test-restore-noop-without-end-position ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "plain" 'ignore nil)
    (with-temp-buffer
      (deactivate-mark)
      (let ((bookmark-current-bookmark "plain")
            (bookmark-gt-use-region t))
        (bookmark-gt--on-jump-restore-region))
      (should-not mark-active))))

(ert-deftest bookmark-gt-region-test-restore-noop-when-flag-off ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-region-test--with-file "abcdefghij"
      (goto-char 3)
      (set-mark 7)
      (activate-mark)
      (bookmark-gt-set "sel"))
    (with-temp-buffer
      (insert "abcdefghij")
      (goto-char 3)
      (deactivate-mark)
      (let ((bookmark-current-bookmark (caar bookmark-alist))
            (bookmark-gt-use-region nil))
        (bookmark-gt--on-jump-restore-region))
      (should-not mark-active))))

;;;; Install / uninstall

(ert-deftest bookmark-gt-region-test-install-uninstall ()
  (unwind-protect
      (progn
        (add-hook (quote bookmark-after-jump-hook) (function bookmark-gt--on-jump-restore-region))
        (should (memq #'bookmark-gt--on-jump-restore-region
                      bookmark-after-jump-hook))
        (remove-hook (quote bookmark-after-jump-hook) (function bookmark-gt--on-jump-restore-region))
        (should-not (memq #'bookmark-gt--on-jump-restore-region
                          bookmark-after-jump-hook)))
    (remove-hook 'bookmark-after-jump-hook
                 #'bookmark-gt--on-jump-restore-region)))

;;;; Delta correction

(ert-deftest bookmark-gt-region-test-restore-with-delta ()
  "When context re-anchoring moves the start, the end moves by the same delta."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-region-test--with-file "abcdefghijklmnopqrstuvwxyz"
      (goto-char 5)
      (set-mark 15)
      (activate-mark)
      (bookmark-gt-set "sel"))
    (with-temp-buffer
      (insert "abcdefghijklmnopqrstuvwxyz")
      (goto-char 8)  ; simulate re-anchor shifted start by +3
      (deactivate-mark)
      (let ((bookmark-current-bookmark (caar bookmark-alist))
            (bookmark-gt-use-region t))
        (bookmark-gt--on-jump-restore-region))
      (should (= (mark) 18)))))

;;;; Save / load round-trip

(ert-deftest bookmark-gt-region-test-region-survives-save-load ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-region-test--with-file "abcdefghijklmnopqrstuvwxyz"
      (goto-char 5)
      (set-mark 15)
      (activate-mark)
      (bookmark-gt-set "sel"))
    (bookmark-save)
    (let ((bookmark-alist nil))
      (bookmark-load bookmark-default-file t t nil)
      (should (= (bookmark-prop-get (car bookmark-alist) 'end-position)
                 15))
      (should (bookmark-prop-get (car bookmark-alist)
                                 'front-context-region-string)))))

(provide 'bookmark-gt-region-tests)
;;; bookmark-gt-region-tests.el ends here
