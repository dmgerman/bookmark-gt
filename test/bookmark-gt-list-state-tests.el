;;; bookmark-gt-list-state-tests.el --- Tests for list-buffer state persistence   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for cross-invocation and cross-session persistence of the
;; list buffer's sort key, `show-temp' toggle, and filters, plus
;; the `bookmark-gt-list-reset-view' command.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-list)

(defmacro bookmark-gt-list-state-test--isolated (&rest body)
  "Run BODY with a fresh, unwritten state file and a clean state cache.
Cleans up the buffer and file on exit."
  (declare (indent 0) (debug t))
  `(bookmark-gt-test-with-clean-bookmarks
     (let* ((tmp (make-temp-name
                  (expand-file-name "bookmark-gt-list-state-"
                                    temporary-file-directory)))
            (bookmark-gt-list-state-file       tmp)
            (bookmark-gt-list-persist-state    nil)
            (bookmark-gt-list--state           nil)
            (bookmark-gt-list--state-loaded    nil))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer bookmark-gt-list-buffer-name)
           (kill-buffer bookmark-gt-list-buffer-name))
         (when (file-exists-p tmp) (delete-file tmp))))))

(defun bookmark-gt-list-state-test--seed-two ()
  "Insert two URL bookmarks so the list buffer has rows."
  (bookmark-gt-set-non-file "alpha" 'bookmark-gt-handler-url-jump
                            '((url . "https://a.example/")))
  (bookmark-gt-set-non-file "beta" 'bookmark-gt-handler-url-jump
                            '((url . "https://b.example/"))))

;;;; Wipe fix: mode not re-entered on re-invocation

(ert-deftest bookmark-gt-list-state-test-reinvoke-preserves-sort ()
  "Repeated `bookmark-gt-list' keeps the buffer's sort key."
  (bookmark-gt-list-state-test--isolated
    (bookmark-gt-list-state-test--seed-two)
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (setq tabulated-list-sort-key (cons "Type" nil))
      (tabulated-list-print t))
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (should (equal tabulated-list-sort-key (cons "Type" nil))))))

(ert-deftest bookmark-gt-list-state-test-reinvoke-preserves-filters ()
  "Repeated `bookmark-gt-list' keeps active filters."
  (bookmark-gt-list-state-test--isolated
    (bookmark-gt-list-state-test--seed-two)
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (setq bookmark-gt-list--filters '((by-tag . "work"))))
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (should (equal bookmark-gt-list--filters '((by-tag . "work")))))))

(ert-deftest bookmark-gt-list-state-test-reinvoke-preserves-show-temp ()
  "Repeated `bookmark-gt-list' keeps the show-temp toggle."
  (bookmark-gt-list-state-test--isolated
    (bookmark-gt-list-state-test--seed-two)
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (setq bookmark-gt-list--show-temp nil))
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (should (null bookmark-gt-list--show-temp)))))

;;;; State-file round-trip (persist-state = t)

(ert-deftest bookmark-gt-list-state-test-state-file-roundtrip ()
  "Sort, show-temp, and filters written to file are re-applied on next open."
  (bookmark-gt-list-state-test--isolated
    (let ((bookmark-gt-list-persist-state t))
      (bookmark-gt-list-state-test--seed-two)
      (bookmark-gt-list)
      (with-current-buffer bookmark-gt-list-buffer-name
        (setq tabulated-list-sort-key (cons "Type" nil))
        (setq bookmark-gt-list--show-temp nil)
        (setq bookmark-gt-list--filters '((by-tag . "work")))
        (bookmark-gt-list--state-changed))
      (should (file-exists-p bookmark-gt-list-state-file))
      ;; Simulate a new Emacs session: kill buffer, wipe caches.
      (kill-buffer bookmark-gt-list-buffer-name)
      (setq bookmark-gt-list--state nil)
      (setq bookmark-gt-list--state-loaded nil)
      (bookmark-gt-list)
      (with-current-buffer bookmark-gt-list-buffer-name
        (should (equal tabulated-list-sort-key (cons "Type" nil)))
        (should (null bookmark-gt-list--show-temp))
        (should (equal bookmark-gt-list--filters '((by-tag . "work"))))))))

;;;; Opt-in gating (persist-state = nil)

(ert-deftest bookmark-gt-list-state-test-persist-off-writes-nothing ()
  "With persist disabled, state changes do not create the file."
  (bookmark-gt-list-state-test--isolated
    (bookmark-gt-list-state-test--seed-two)
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (setq tabulated-list-sort-key (cons "Type" nil))
      (bookmark-gt-list--state-changed))
    (should-not (file-exists-p bookmark-gt-list-state-file))))

(ert-deftest bookmark-gt-list-state-test-persist-off-ignores-file ()
  "With persist disabled, an existing state file is not read on mode entry."
  (bookmark-gt-list-state-test--isolated
    (with-temp-file bookmark-gt-list-state-file
      (prin1 '((sort-key "Type" . nil)
               (show-temp . nil)
               (filters (by-tag . "work")))
             (current-buffer)))
    (bookmark-gt-list-state-test--seed-two)
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (should (equal tabulated-list-sort-key (cons "Name" nil)))
      (should bookmark-gt-list--show-temp)
      (should (null bookmark-gt-list--filters)))))

;;;; Robustness

(ert-deftest bookmark-gt-list-state-test-corrupted-file-uses-defaults ()
  "A garbage state file leaves defaults in place and does not error."
  (bookmark-gt-list-state-test--isolated
    (let ((bookmark-gt-list-persist-state t))
      (with-temp-file bookmark-gt-list-state-file
        (insert "not-a-sexp {"))
      (bookmark-gt-list-state-test--seed-two)
      (bookmark-gt-list)
      (with-current-buffer bookmark-gt-list-buffer-name
        (should (equal tabulated-list-sort-key (cons "Name" nil)))
        (should bookmark-gt-list--show-temp)
        (should (null bookmark-gt-list--filters))))))

(ert-deftest bookmark-gt-list-state-test-missing-file-uses-defaults ()
  "With persist enabled but no file yet, defaults apply and no error signals."
  (bookmark-gt-list-state-test--isolated
    (let ((bookmark-gt-list-persist-state t))
      (bookmark-gt-list-state-test--seed-two)
      (bookmark-gt-list)
      (with-current-buffer bookmark-gt-list-buffer-name
        (should (equal tabulated-list-sort-key (cons "Name" nil)))
        (should bookmark-gt-list--show-temp)
        (should (null bookmark-gt-list--filters))))))

;;;; Reset-view command

(ert-deftest bookmark-gt-list-state-test-reset-view-restores-defaults ()
  "`bookmark-gt-list-reset-view' clears filters, resets sort, resets show-temp."
  (bookmark-gt-list-state-test--isolated
    (bookmark-gt-list-state-test--seed-two)
    (bookmark-gt-list)
    (with-current-buffer bookmark-gt-list-buffer-name
      (setq tabulated-list-sort-key (cons "Type" nil))
      (setq bookmark-gt-list--show-temp nil)
      (setq bookmark-gt-list--filters '((by-tag . "work")))
      (bookmark-gt-list-reset-view)
      (should (equal tabulated-list-sort-key (cons "Name" nil)))
      (should (eq bookmark-gt-list--show-temp
                  bookmark-gt-list-default-show-temp))
      (should (null bookmark-gt-list--filters)))))

(ert-deftest bookmark-gt-list-state-test-reset-view-persists ()
  "`bookmark-gt-list-reset-view' persists the reset when persist is on."
  (bookmark-gt-list-state-test--isolated
    (let ((bookmark-gt-list-persist-state t))
      (bookmark-gt-list-state-test--seed-two)
      (bookmark-gt-list)
      (with-current-buffer bookmark-gt-list-buffer-name
        (setq tabulated-list-sort-key (cons "Type" nil))
        (setq bookmark-gt-list--filters '((by-tag . "work")))
        (bookmark-gt-list-reset-view))
      (kill-buffer bookmark-gt-list-buffer-name)
      (setq bookmark-gt-list--state nil)
      (setq bookmark-gt-list--state-loaded nil)
      (bookmark-gt-list)
      (with-current-buffer bookmark-gt-list-buffer-name
        (should (equal tabulated-list-sort-key (cons "Name" nil)))
        (should (null bookmark-gt-list--filters))))))

(provide 'bookmark-gt-list-state-tests)
;;; bookmark-gt-list-state-tests.el ends here
