;;; bookmark-gt-cycle-tests.el --- Tests for in-buffer cycling   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for `bookmark-gt-cycle-next' / `-prev'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-core)

(defmacro bookmark-gt-cycle-test--with-file (content &rest body)
  "Run BODY in a live file-visiting buffer containing CONTENT."
  (declare (indent 1) (debug t))
  `(let ((tmp (make-temp-file "bookmark-gt-cycle-")))
     (unwind-protect
         (progn
           (with-temp-file tmp (insert ,content))
           (with-current-buffer (find-file-noselect tmp)
             (unwind-protect
                 (progn ,@body)
               (kill-buffer))))
       (delete-file tmp))))

;;;; No bookmarks

(ert-deftest bookmark-gt-cycle-test-empty-signals ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-cycle-test--with-file "abcdefghij"
      (should-error (bookmark-gt-cycle-next) :type 'user-error)
      (should-error (bookmark-gt-cycle-prev) :type 'user-error))))

;;;; Next

(ert-deftest bookmark-gt-cycle-test-next-forward ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-cycle-test--with-file "abcdefghijklmnop"
      (let ((path (buffer-file-name)))
        (bookmark-gt-set-non-file
         "a" nil (list (cons 'filename path) (cons 'position 3)))
        (bookmark-gt-set-non-file
         "b" nil (list (cons 'filename path) (cons 'position 8)))
        (goto-char 1)
        (bookmark-gt-cycle-next)
        (should (= (point) 3))
        (bookmark-gt-cycle-next)
        (should (= (point) 8))))))

(ert-deftest bookmark-gt-cycle-test-next-wraps ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-cycle-test--with-file "abcdefghijklmnop"
      (let ((path (buffer-file-name)))
        (bookmark-gt-set-non-file
         "a" nil (list (cons 'filename path) (cons 'position 3)))
        (bookmark-gt-set-non-file
         "b" nil (list (cons 'filename path) (cons 'position 8)))
        (goto-char 15)  ; past all bookmarks
        (bookmark-gt-cycle-next)
        (should (= (point) 3))))))  ; wrapped to first

;;;; Prev

(ert-deftest bookmark-gt-cycle-test-prev-backward ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-cycle-test--with-file "abcdefghijklmnop"
      (let ((path (buffer-file-name)))
        (bookmark-gt-set-non-file
         "a" nil (list (cons 'filename path) (cons 'position 3)))
        (bookmark-gt-set-non-file
         "b" nil (list (cons 'filename path) (cons 'position 8)))
        (goto-char 10)
        (bookmark-gt-cycle-prev)
        (should (= (point) 8))
        (bookmark-gt-cycle-prev)
        (should (= (point) 3))))))

(ert-deftest bookmark-gt-cycle-test-prev-wraps ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-cycle-test--with-file "abcdefghijklmnop"
      (let ((path (buffer-file-name)))
        (bookmark-gt-set-non-file
         "a" nil (list (cons 'filename path) (cons 'position 3)))
        (bookmark-gt-set-non-file
         "b" nil (list (cons 'filename path) (cons 'position 8)))
        (goto-char 1)  ; before all bookmarks
        (bookmark-gt-cycle-prev)
        (should (= (point) 8))))))  ; wrapped to last

;;;; Ignores bookmarks in other files

(ert-deftest bookmark-gt-cycle-test-ignores-other-files ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-cycle-test--with-file "aaaaaaaaaa"
      (let ((path (buffer-file-name)))
        (bookmark-gt-set-non-file
         "here" nil (list (cons 'filename path) (cons 'position 3)))
        ;; Bookmark for a DIFFERENT file
        (bookmark-gt-set-non-file
         "elsewhere" nil (list (cons 'filename "/tmp/other-file-xyz")
                               (cons 'position 5)))
        (goto-char 1)
        (bookmark-gt-cycle-next)
        (should (= (point) 3))
        ;; Only one bookmark in scope; cycling wraps back to it.
        (bookmark-gt-cycle-next)
        (should (= (point) 3))))))

;;;; Skips non-numeric positions

(ert-deftest bookmark-gt-cycle-test-skips-nil-position ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-cycle-test--with-file "aaaaaaaaaa"
      (let ((path (buffer-file-name)))
        (bookmark-gt-set-non-file
         "no-pos" nil (list (cons 'filename path)))  ; no position
        (bookmark-gt-set-non-file
         "yes-pos" nil (list (cons 'filename path) (cons 'position 4)))
        (goto-char 1)
        (bookmark-gt-cycle-next)
        (should (= (point) 4))))))

(provide 'bookmark-gt-cycle-tests)
;;; bookmark-gt-cycle-tests.el ends here
