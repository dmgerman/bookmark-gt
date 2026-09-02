;;; bookmark-gt-auto-update-tests.el --- Tests for auto-update  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the auto-update property, refresh logic, timer arm /
;; disarm via `bookmark-gt-auto-update-mode', and list-buffer
;; column integration.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-auto-update)
(require 'bookmark-gt-list)

;;;; Toggle

(ert-deftest bookmark-gt-auto-update-test-toggle-adds-and-removes ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h nil)
    (should-not (bookmark-gt-auto-update-p (car bookmark-alist)))
    (bookmark-gt-auto-update-toggle "b")
    (should (bookmark-gt-auto-update-p (car bookmark-alist)))
    (bookmark-gt-auto-update-toggle "b")
    (should-not (bookmark-gt-auto-update-p (car bookmark-alist)))))

(ert-deftest bookmark-gt-auto-update-test-toggle-fires-after-hook ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "b" 'h nil)
    (let (seen)
      (add-hook 'bookmark-gt-record-changed-hook
                (lambda (entry &optional _op) (push entry seen)))
      (bookmark-gt-auto-update-toggle "b")
      (should (= (length seen) 1))
      (should (bookmark-gt-auto-update-p (car seen))))))

;;;; Refresh

(ert-deftest bookmark-gt-auto-update-test-refresh-updates-position ()
  "A fresh record from the buffer's `bookmark-make-record-function' is applied."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((tmp (make-temp-file "bookmark-gt-au-" nil ".txt"
                               "line one\nline two\nline three\n")))
      (unwind-protect
          (with-current-buffer (find-file-noselect tmp)
            (goto-char (point-min))
            (bookmark-gt-create "orig")
            (let ((record (assoc "orig" bookmark-alist)))
              (bookmark-gt-auto-update-toggle "orig")
              (goto-char (point-max))
              (bookmark-gt-auto-update--refresh record (current-buffer))
              (should (= (bookmark-prop-get record 'position)
                         (point-max))))
            (kill-buffer))
        (delete-file tmp)))))

(ert-deftest bookmark-gt-auto-update-test-refresh-preserves-tags ()
  "Refresh does not clobber preserved fields (tags, annotation)."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((tmp (make-temp-file "bookmark-gt-au-" nil ".txt" "hello\n")))
      (unwind-protect
          (with-current-buffer (find-file-noselect tmp)
            (bookmark-gt-create "orig")
            (bookmark-gt-tags-set "orig" '("keep"))
            (let ((record (assoc "orig" bookmark-alist)))
              (bookmark-gt-auto-update-toggle "orig")
              (goto-char (point-max))
              (bookmark-gt-auto-update--refresh record (current-buffer))
              (should (equal (bookmark-gt-tags-of record) '("keep")))
              (should (bookmark-gt-auto-update-p record)))
            (kill-buffer))
        (delete-file tmp)))))

(ert-deftest bookmark-gt-auto-update-test-tick-skips-untracked ()
  "`bookmark-gt-auto-update-tick' does not touch bookmarks lacking the prop."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((tmp (make-temp-file "bookmark-gt-au-" nil ".txt" "hello\n")))
      (unwind-protect
          (with-current-buffer (find-file-noselect tmp)
            (bookmark-gt-create "no-au")
            (let* ((record (assoc "no-au" bookmark-alist))
                   (orig-pos (bookmark-prop-get record 'position)))
              (goto-char (point-max))
              (bookmark-gt-auto-update-tick)
              (should (= (bookmark-prop-get record 'position) orig-pos)))
            (kill-buffer))
        (delete-file tmp)))))

;;;; Mode arm / disarm

(ert-deftest bookmark-gt-auto-update-test-mode-arms-timer ()
  (unwind-protect
      (progn
        (bookmark-gt-auto-update-mode 1)
        (should (timerp bookmark-gt-auto-update--timer))
        (bookmark-gt-auto-update-mode -1)
        (should (null bookmark-gt-auto-update--timer)))
    (when bookmark-gt-auto-update--timer
      (cancel-timer bookmark-gt-auto-update--timer)
      (setq bookmark-gt-auto-update--timer nil))))

;;;; List-buffer column integration

(defmacro bookmark-gt-au-test--in-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (bookmark-gt-list)
         (with-current-buffer bookmark-gt-list-buffer-name ,@body))
     (when (get-buffer bookmark-gt-list-buffer-name)
       (kill-buffer bookmark-gt-list-buffer-name))))

(ert-deftest bookmark-gt-auto-update-test-list-column-shows-caret ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "au"  'h '((auto-update . t)))
    (bookmark-gt-create-non-file "off" 'h nil)
    (bookmark-gt-au-test--in-buffer
      (goto-char (point-min))
      (let (caret-count)
        (setq caret-count 0)
        (while (not (eobp))
          (when (tabulated-list-get-id)
            (when (equal (aref (tabulated-list-get-entry) 1) "^")
              (setq caret-count (1+ caret-count))))
          (forward-line 1))
        (should (= caret-count 1))))))

(provide 'bookmark-gt-auto-update-tests)
;;; bookmark-gt-auto-update-tests.el ends here
