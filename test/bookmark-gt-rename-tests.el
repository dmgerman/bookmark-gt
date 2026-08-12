;;; bookmark-gt-rename-tests.el --- Tests for the rename-file tracker   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for `bookmark-gt--rename-file-advice': rewrites bookmark
;; filenames on real renames, skips backup renames, respects the
;; `bookmark-gt-track-renames' opt-out.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-core)

(defmacro bookmark-gt-rename-test--with-files (files &rest body)
  "Create FILES as temp files, bind them by name, run BODY, then clean up.
FILES is an alist ((SYMBOL . CONTENT) ...) — each SYMBOL is bound
to the full temp path inside BODY."
  (declare (indent 1) (debug t))
  (let ((paths (mapcar (lambda (f) (cons (car f) (make-symbol
                                                  (format "tmp-%s"
                                                          (car f)))))
                       files)))
    `(let ,(mapcar (lambda (p) `(,(cdr p) (make-temp-file "bookmark-gt-rt-")))
                   paths)
       (let ,(mapcar (lambda (p) `(,(car p) ,(cdr p))) paths)
         (unwind-protect
             (progn
           ,@(mapcar (lambda (f)
                       `(with-temp-file ,(cdr (assq (car f) paths))
                          (insert ,(cdr f))))
                     files)
           ,@body)
           ,@(mapcar (lambda (p)
                       `(when (file-exists-p ,(cdr p))
                          (delete-file ,(cdr p))))
                     paths))))))

;;;; The tracker itself is not installed inside tests; we call the
;;;; advice function directly with a stub ORIG-FN so tests do not
;;;; touch the global `rename-file' advice state.

(defun bookmark-gt-rename-test--simulate-rename (from to)
  "Perform a real `rename-file' plus call our advice."
  (bookmark-gt--rename-file-advice #'rename-file from to t))

;;;; Real rename updates bookmark

(ert-deftest bookmark-gt-rename-test-tracks-real-rename ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-rename-test--with-files ((orig . "hi"))
      (let ((new (make-temp-name
                  (expand-file-name "renamed-"
                                    temporary-file-directory))))
        (unwind-protect
            (progn
              (bookmark-gt-set-non-file
               "b" nil (list (cons 'filename orig)))
              (let ((bookmark-gt-track-renames t))
                (bookmark-gt-rename-test--simulate-rename orig new))
              (should (equal (bookmark-gt-filename-of (car bookmark-alist))
                             (expand-file-name new))))
          (when (file-exists-p new) (delete-file new)))))))

;;;; Backup rename does NOT update bookmark

(ert-deftest bookmark-gt-rename-test-ignores-backup-destination ()
  "The rename that Emacs uses to create ORIG~ must not move the bookmark."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-rename-test--with-files ((orig . "hi"))
      (let ((backup (concat orig "~")))
        (unwind-protect
            (progn
              (bookmark-gt-set-non-file
               "b" nil (list (cons 'filename orig)))
              (let ((bookmark-gt-track-renames t))
                (bookmark-gt-rename-test--simulate-rename orig backup))
              (should (equal (bookmark-gt-filename-of (car bookmark-alist))
                             (expand-file-name orig))))
          (when (file-exists-p backup) (delete-file backup)))))))

;;;; Opt-out flag disables tracking

(ert-deftest bookmark-gt-rename-test-opt-out ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-rename-test--with-files ((orig . "hi"))
      (let ((new (make-temp-name
                  (expand-file-name "renamed-"
                                    temporary-file-directory))))
        (unwind-protect
            (progn
              (bookmark-gt-set-non-file
               "b" nil (list (cons 'filename orig)))
              (let ((bookmark-gt-track-renames nil))
                (bookmark-gt-rename-test--simulate-rename orig new))
              (should (equal (bookmark-gt-filename-of (car bookmark-alist))
                             (expand-file-name orig))))
          (when (file-exists-p new) (delete-file new)))))))

;;;; Non-matching bookmarks unaffected

(ert-deftest bookmark-gt-rename-test-leaves-other-bookmarks-alone ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-rename-test--with-files ((orig . "hi") (other . "ho"))
      (let ((new (make-temp-name
                  (expand-file-name "renamed-"
                                    temporary-file-directory))))
        (unwind-protect
            (progn
              (bookmark-gt-set-non-file
               "target" nil (list (cons 'filename orig)))
              (bookmark-gt-set-non-file
               "keep" nil (list (cons 'filename other)))
              (let ((bookmark-gt-track-renames t))
                (bookmark-gt-rename-test--simulate-rename orig new))
              (should (equal (bookmark-gt-filename-of
                              (assoc "keep" bookmark-alist))
                             (expand-file-name other))))
          (when (file-exists-p new) (delete-file new)))))))

;;;; Install / uninstall

(ert-deftest bookmark-gt-rename-test-install-uninstall ()
  (unwind-protect
      (progn
        (bookmark-gt-install-rename-tracker)
        (should (advice-member-p #'bookmark-gt--rename-file-advice
                                 'rename-file))
        (bookmark-gt-uninstall-rename-tracker)
        (should-not (advice-member-p #'bookmark-gt--rename-file-advice
                                     'rename-file)))
    ;; Defensive cleanup
    (bookmark-gt-uninstall-rename-tracker)))

(provide 'bookmark-gt-rename-tests)
;;; bookmark-gt-rename-tests.el ends here
