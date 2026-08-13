;;; bookmark-gt-highlight-tests.el --- Tests for per-bookmark highlighting  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for `bookmark-gt-highlight--refresh-buffer' and friends.
;; Uses temp files so overlays land in real file-visiting buffers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-core)

(defmacro bookmark-gt-highlight-test--with-file (content &rest body)
  "Run BODY in a live file-visiting buffer containing CONTENT."
  (declare (indent 1) (debug t))
  `(let ((tmp (make-temp-file "bookmark-gt-hl-")))
     (unwind-protect
         (progn
           (with-temp-file tmp (insert ,content))
           (with-current-buffer (find-file-noselect tmp)
             (unwind-protect
                 (progn ,@body)
               (kill-buffer))))
       (delete-file tmp))))

(defun bookmark-gt-highlight-test--overlay-count ()
  "Return the number of bookmark-gt-highlight overlays in the current buffer."
  (length
   (seq-filter (lambda (ov) (overlay-get ov 'bookmark-gt-highlight))
               (overlays-in (point-min) (point-max)))))

;;;; Refresh creates overlays

(ert-deftest bookmark-gt-highlight-test-file-bookmark-highlights ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-highlight-test--with-file "abcdefghij"
      (let ((bookmark-gt-highlight-enable t))
        (bookmark-gt-set-non-file
         "b" nil
         (list (cons 'filename (buffer-file-name)) (cons 'position 3)))
        (bookmark-gt-highlight--refresh-buffer)
        (should (= (bookmark-gt-highlight-test--overlay-count) 1))))))

(ert-deftest bookmark-gt-highlight-test-non-file-does-not-highlight ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (bookmark-gt-highlight-test--with-file "abcdefghij"
      (bookmark-gt-highlight--refresh-buffer)
      (should (= (bookmark-gt-highlight-test--overlay-count) 0)))))

;;;; Flag off = no highlights

(ert-deftest bookmark-gt-highlight-test-flag-off-clears ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-highlight-test--with-file "abcdefghij"
      (bookmark-gt-set-non-file
       "b" nil
       (list (cons 'filename (buffer-file-name)) (cons 'position 3)))
      (let ((bookmark-gt-highlight-enable nil))
        (bookmark-gt-highlight--refresh-buffer)
        (should (= (bookmark-gt-highlight-test--overlay-count) 0))))))

;;;; Clear removes overlays

(ert-deftest bookmark-gt-highlight-test-clear-removes-overlays ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-highlight-test--with-file "abcdefghij"
      (bookmark-gt-set-non-file
       "b" nil
       (list (cons 'filename (buffer-file-name)) (cons 'position 3)))
      (let ((bookmark-gt-highlight-enable t))
        (bookmark-gt-highlight--refresh-buffer))
      (should (>= (bookmark-gt-highlight-test--overlay-count) 1))
      (bookmark-gt-highlight--clear-buffer)
      (should (= (bookmark-gt-highlight-test--overlay-count) 0)))))

;;;; Region bookmark spans multiple lines

(ert-deftest bookmark-gt-highlight-test-region-spans-region ()
  "For records with end-position, overlay spans start-of-line at pos
through end-of-line at end-position."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-highlight-test--with-file "line1\nline2\nline3\n"
      (bookmark-gt-set-non-file
       "b" nil
       (list (cons 'filename (buffer-file-name))
             (cons 'position 3)
             (cons 'end-position 12)))
      (let ((bookmark-gt-highlight-enable t))
        (bookmark-gt-highlight--refresh-buffer))
      (let ((ov (car bookmark-gt-highlight--overlays)))
        (should ov)
        ;; Overlay start ≤ position, end ≥ end-position (line
        ;; expansion at both ends).
        (should (<= (overlay-start ov) 3))
        (should (>= (overlay-end ov) 12))))))

;;;; Post-jump path: records without `position' still get overlays

(ert-deftest bookmark-gt-highlight-test-jump-hook-covers-no-position ()
  "Records with no numeric `position' (e.g. org-heading bookmarks)
get an overlay after `bookmark-gt-highlight--on-jump'
records the landed point."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-highlight-test--with-file "line1\nline2\nline3\n"
      ;; Record without `position' — mimics an org-heading bookmark.
      (bookmark-gt-set-non-file
       "b" nil
       (list (cons 'filename (buffer-file-name))))
      (let ((bookmark-gt-highlight-enable t))
        ;; Pre-jump refresh: no overlay because position is absent.
        (bookmark-gt-highlight--refresh-buffer)
        (should (= (bookmark-gt-highlight-test--overlay-count) 0))
        ;; Simulate a jump landing at position 9 (inside line2).
        (goto-char 9)
        (let ((bookmark-current-bookmark "b"))
          (bookmark-gt-highlight--on-jump))
        (should (= (bookmark-gt-highlight-test--overlay-count) 1))))))

;;;; Mode-on/off wires highlight hooks

(ert-deftest bookmark-gt-highlight-test-mode-wires-hooks ()
  (unwind-protect
      (progn
        (bookmark-gt-mode 1)
        (should (memq #'bookmark-gt-highlight--on-find-file
                      find-file-hook))
        (should (memq #'bookmark-gt-highlight--on-jump
                      bookmark-after-jump-hook))
        (bookmark-gt-mode -1)
        (should-not (memq #'bookmark-gt-highlight--on-find-file
                          find-file-hook))
        (should-not (memq #'bookmark-gt-highlight--on-jump
                          bookmark-after-jump-hook)))
    (bookmark-gt-mode -1)))

(provide 'bookmark-gt-highlight-tests)
;;; bookmark-gt-highlight-tests.el ends here
