;;; test-helper.el --- Shared helpers for bookmark-gt tests   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Every test wraps its body in `bookmark-gt-test-with-clean-bookmarks',
;; which rebinds `bookmark-alist' to nil and points
;; `bookmark-default-file' at a temp file so the user's real
;; bookmarks are never touched.

;;; Code:

(require 'ert)
(require 'bookmark)
(require 'bookmark-gt)

(defvar bookmark-gt-test--temp-files nil
  "Temp bookmark files created in the current test run, for cleanup.")

(defun bookmark-gt-test--make-temp-bookmark-file ()
  "Return a unique bookmark-file path; the file does not exist yet.
Registered for cleanup."
  (let ((f (make-temp-name
            (expand-file-name "bookmark-gt-test-" temporary-file-directory))))
    (push f bookmark-gt-test--temp-files)
    f))

(defmacro bookmark-gt-test-with-clean-bookmarks (&rest body)
  "Run BODY with a fresh, isolated bookmark environment.
Inside BODY: `bookmark-alist' starts nil,
`bookmark-default-file' is a fresh temp file, no auto-save."
  (declare (indent 0) (debug t))
  `(let* ((bookmark-gt-test--temp-files      nil)
          (tmp                               (bookmark-gt-test--make-temp-bookmark-file))
          (bookmark-alist                    nil)
          (bookmark-default-file             tmp)
          (bookmark-save-flag                nil)
          (bookmark-current-file             tmp)
          (bookmark-watch-bookmark-file      nil)
          (bookmark-bookmarks-timestamp      nil)
          (bookmarks-already-loaded          nil)
          (bookmark-gt-set-name-reader-hook  nil)
          (bookmark-gt-set-tag-reader-hook   nil)
          (bookmark-gt-set-after-hook        nil))
     (unwind-protect
         (progn ,@body)
       (dolist (f bookmark-gt-test--temp-files)
         (when (file-exists-p f)
           (delete-file f))))))

(provide 'test-helper)
;;; test-helper.el ends here
