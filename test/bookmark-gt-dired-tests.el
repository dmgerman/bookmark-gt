;;; bookmark-gt-dired-tests.el --- Tests for the Dired bookmark handler   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Covers the Dired-specific setter and jump paths:
;;   - state capture (dired-directory, marks, subdirs, hidden dirs,
;;     switches) when `bookmark-gt-set' fires in a Dired buffer;
;;   - state restoration on jump (marks re-applied, subdirs inserted);
;;   - wildcard and explicit-file-list forms of `dired-directory'
;;     round-trip;
;;   - virtual-dired listing inlined under `dired-listing' with a
;;     size cap that signals `user-error' when exceeded.
;;
;; Every test creates a fresh sandbox directory via
;; `make-temp-file' and deletes it in an `unwind-protect' so no
;; state leaks between tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dired)
(require 'dired-x)
(require 'test-helper)
(require 'bookmark-gt-handlers)

(defmacro bookmark-gt-dired-test--with-sandbox (bindings &rest body)
  "Create a sandbox dir with files, run BODY, delete the sandbox.
BINDINGS is ((DIR-VAR FILES) ...) where FILES is a list of
relative filenames created (empty) inside a freshly made temp
directory bound to DIR-VAR.  DIR-VAR ends with a slash."
  (declare (indent 1) (debug ((&rest (symbolp form)) body)))
  (let ((sandbox (make-symbol "sandbox")))
    `(let* ((,sandbox (file-name-as-directory
                       (make-temp-file "bookmark-gt-dired-" t))))
       (unwind-protect
           (let ,(mapcar (lambda (b) `(,(car b) ,sandbox)) bindings)
             ,@(mapcar
                (lambda (b)
                  `(dolist (rel ,(cadr b))
                     (let ((p (expand-file-name rel ,(car b))))
                       (make-directory (file-name-directory p) t)
                       (unless (file-exists-p p)
                         (with-temp-file p (insert ""))))))
                bindings)
             ,@body)
         (delete-directory ,sandbox t)))))

(defun bookmark-gt-dired-test--kill-dired-buffers (dir)
  "Kill any Dired buffers visiting DIR or its subdirectories."
  (dolist (b (buffer-list))
    (when (and (buffer-live-p b)
               (with-current-buffer b
                 (and (derived-mode-p 'dired-mode)
                      (or (equal default-directory dir)
                          (string-prefix-p dir default-directory)))))
      (kill-buffer b))))

;;;; State capture

(ert-deftest bookmark-gt-dired-test-set-captures-directory-and-switches ()
  "Setting a bookmark from Dired records `dired-directory' and switches."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox ((dir '("a.txt" "b.txt")))
      (unwind-protect
          (let ((buf (dired dir)))
            (with-current-buffer buf
              (bookmark-gt-set "d1"))
            (let ((rec (car bookmark-alist)))
              (should (equal (bookmark-prop-get rec 'handler)
                             'bookmark-gt-handler-dired-jump))
              (should (bookmark-prop-get rec 'dired-directory))
              (should (bookmark-prop-get rec 'dired-switches))))
        (bookmark-gt-dired-test--kill-dired-buffers dir)))))

(ert-deftest bookmark-gt-dired-test-set-captures-marks ()
  "Setting a bookmark from Dired records marked files."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox ((dir '("a.txt" "b.txt" "c.txt")))
      (unwind-protect
          (let ((buf (dired dir)))
            (with-current-buffer buf
              (dired-goto-file (expand-file-name "a.txt" dir))
              (dired-mark 1)
              (dired-goto-file (expand-file-name "c.txt" dir))
              (dired-mark 1)
              (bookmark-gt-set "d2"))
            (let* ((rec (car bookmark-alist))
                   (marks (bookmark-prop-get rec 'dired-marked))
                   (files (mapcar #'car marks)))
              (should (member (expand-file-name "a.txt" dir) files))
              (should (member (expand-file-name "c.txt" dir) files))
              (should-not (member (expand-file-name "b.txt" dir) files))))
        (bookmark-gt-dired-test--kill-dired-buffers dir)))))

(ert-deftest bookmark-gt-dired-test-set-captures-inserted-subdirs ()
  "Setting a bookmark records subdirectories inserted with `i'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox
        ((dir '("top.txt" "sub/inner.txt")))
      (unwind-protect
          (let ((buf (dired dir)))
            (with-current-buffer buf
              (dired-maybe-insert-subdir
               (expand-file-name "sub" dir))
              (bookmark-gt-set "d3"))
            (let* ((rec (car bookmark-alist))
                   (subs (bookmark-prop-get rec 'dired-subdirs)))
              ;; Shape is ((DIR) (DIR) ...) — same as bookmark+ and
              ;; what `dired-insert-old-subdirs' expects.
              (should (cl-some (lambda (entry)
                                 (and (consp entry)
                                      (string-suffix-p
                                       "sub/"
                                       (file-name-as-directory (car entry)))))
                               subs))))
        (bookmark-gt-dired-test--kill-dired-buffers dir)))))

(ert-deftest bookmark-gt-dired-test-set-wildcard-preserves-form ()
  "Wildcard `dired-directory' round-trips verbatim through the record."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox ((dir '("one.el" "two.el" "keep.txt")))
      (unwind-protect
          (let* ((pattern (concat dir "*.el"))
                 (buf (dired pattern)))
            (with-current-buffer buf
              (bookmark-gt-set "d4"))
            (let ((rec (car bookmark-alist)))
              ;; `dired-noselect' normalizes its input with
              ;; `abbreviate-file-name' + `expand-file-name'
              ;; before setting `dired-directory', so mirror that
              ;; here rather than compare against the raw input.
              (should (equal (bookmark-prop-get rec 'dired-directory)
                             (abbreviate-file-name
                              (expand-file-name pattern))))))
        (bookmark-gt-dired-test--kill-dired-buffers dir)))))

(ert-deftest bookmark-gt-dired-test-set-explicit-file-list-preserves-form ()
  "Explicit-file-list `dired-directory' round-trips verbatim."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox ((dir '("x" "y" "z")))
      (unwind-protect
          (let* ((files (list (expand-file-name "x" dir)
                              (expand-file-name "y" dir)))
                 (buf (dired files)))
            (with-current-buffer buf
              (bookmark-gt-set "d5"))
            (let ((rec (car bookmark-alist)))
              (should (consp (bookmark-prop-get rec 'dired-directory)))
              (should (equal (cdr (bookmark-prop-get rec 'dired-directory))
                             (cdr files)))))
        (bookmark-gt-dired-test--kill-dired-buffers dir)))))

;;;; Restoration on jump

(ert-deftest bookmark-gt-dired-test-jump-restores-marks ()
  "Jumping a Dired bookmark reapplies the recorded marks."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox
        ((dir '("a.txt" "b.txt" "c.txt")))
      (unwind-protect
          (progn
            (let ((buf (dired dir)))
              (with-current-buffer buf
                (dired-goto-file (expand-file-name "b.txt" dir))
                (dired-mark 1)
                (bookmark-gt-set "d-marks-jump"))
              (kill-buffer buf))
            (bookmark-jump "d-marks-jump")
            (let ((remembered (dired-remember-marks (point-min) (point-max))))
              (should (equal remembered
                             `((,(expand-file-name "b.txt" dir) . ?*))))))
        (bookmark-gt-dired-test--kill-dired-buffers dir)))))

(ert-deftest bookmark-gt-dired-test-jump-restores-inserted-subdirs ()
  "Jumping a Dired bookmark re-inserts the recorded subdirectories."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox
        ((dir '("top.txt" "sub/inner.txt")))
      (unwind-protect
          (progn
            (let ((buf (dired dir)))
              (with-current-buffer buf
                (dired-maybe-insert-subdir
                 (expand-file-name "sub" dir))
                (bookmark-gt-set "d-sub-jump"))
              (kill-buffer buf))
            (bookmark-jump "d-sub-jump")
            (let ((sub (file-name-as-directory
                        (expand-file-name "sub" dir))))
              (should (assoc sub dired-subdir-alist))))
        (bookmark-gt-dired-test--kill-dired-buffers dir)))))

;;;; Virtual dired

(ert-deftest bookmark-gt-dired-test-set-virtual-captures-listing ()
  "Setting from a virtual-dired buffer inlines the listing."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox ((dir '("a.txt")))
      (let ((buf (get-buffer-create "*bg-dired-virt-test*")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (erase-buffer)
                ;; Minimal virtual-dired-compatible listing.
                (insert (format "  %s:\n" dir)
                        "  total used in directory 0\n"
                        "  -rw-r--r-- 1 u g 0 Jan  1 00:00 a.txt\n")
                (dired-virtual dir)
                (bookmark-gt-set "d-virt"))
              (let ((rec (car bookmark-alist)))
                (should (eq (bookmark-prop-get rec 'dired-virtual) t))
                (should (stringp (bookmark-prop-get rec 'dired-listing)))
                (should (string-match-p
                         "a\\.txt"
                         (bookmark-prop-get rec 'dired-listing)))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest bookmark-gt-dired-test-set-virtual-cap-errors ()
  "Setting a too-large virtual-dired buffer signals user-error."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox ((dir '("a.txt")))
      (let ((buf (get-buffer-create "*bg-dired-virt-cap*"))
            (bookmark-gt-dired-virtual-max-size 64))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (erase-buffer)
                (insert (format "  %s:\n" dir)
                        "  total used in directory 0\n"
                        (make-string 200 ?x) "\n")
                (dired-virtual dir)
                (should-error (bookmark-gt-set "d-virt-big")
                              :type 'user-error)))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest bookmark-gt-dired-test-jump-virtual-restores-listing ()
  "Jumping a virtual-dired bookmark rebuilds the buffer from `dired-listing'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-dired-test--with-sandbox ((dir '("a.txt")))
      (let ((buf (get-buffer-create "*bg-dired-virt-restore*")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (erase-buffer)
                (insert (format "  %s:\n" dir)
                        "  total used in directory 0\n"
                        "  -rw-r--r-- 1 u g 0 Jan  1 00:00 unique-marker.txt\n")
                (dired-virtual dir)
                (bookmark-gt-set "d-virt-restore"))
              (kill-buffer buf)
              (bookmark-jump "d-virt-restore")
              (should (derived-mode-p 'dired-mode))
              (should (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "unique-marker\\.txt" nil t))))
          (dolist (b (buffer-list))
            (when (and (buffer-live-p b)
                       (string-match-p "\\*Dired-virtual: "
                                       (buffer-name b)))
              (kill-buffer b))))))))

(provide 'bookmark-gt-dired-tests)
;;; bookmark-gt-dired-tests.el ends here
