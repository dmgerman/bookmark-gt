;;; bookmark-gt-migrate-tests.el --- Tests for bookmark-gt-migrate   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Exercises the one-shot migration from bookmark+ record shapes to
;; bookmark-gt equivalents.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-migrate)

(defun bookmark-gt-migrate-test--push (name alist)
  "Push (NAME . ALIST) onto `bookmark-alist' verbatim (no wrappers)."
  (push (cons name alist) bookmark-alist))

;;;; Handler symbol rewrite

(ert-deftest bookmark-gt-migrate-test-dired-handler ()
  "`bmkp-jump-dired' → `bookmark-gt-handler-dired-jump'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "d" '((handler . bmkp-jump-dired)
           (filename . "/tmp/dir/")))
    (should (= (bookmark-gt-migrate-from-bookmark-plus) 1))
    (should (eq (bookmark-prop-get (assoc "d" bookmark-alist) 'handler)
                'bookmark-gt-handler-dired-jump))))

(ert-deftest bookmark-gt-migrate-test-url-handlers ()
  "Both URL variants map to `bookmark-gt-handler-url-jump'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "u1" '((handler . bmkp-jump-url-browse)
            (location . "https://a.example")))
    (bookmark-gt-migrate-test--push
     "u2" '((handler . bmkp-jump-url-browse-other-window)
            (location . "https://b.example")))
    (bookmark-gt-migrate-from-bookmark-plus)
    (dolist (name '("u1" "u2"))
      (should (eq (bookmark-prop-get (assoc name bookmark-alist) 'handler)
                  'bookmark-gt-handler-url-jump)))))

;;;; URL location → url promotion

(ert-deftest bookmark-gt-migrate-test-location-to-url ()
  "`location' is copied to `url' and removed on URL records."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "u" '((handler . bmkp-jump-url-browse)
           (location . "https://example.org")))
    (bookmark-gt-migrate-from-bookmark-plus)
    (let ((rec (assoc "u" bookmark-alist)))
      (should (equal (bookmark-prop-get rec 'url) "https://example.org"))
      (should-not (assq 'location (cdr rec))))))

(ert-deftest bookmark-gt-migrate-test-existing-url-not-overwritten ()
  "When the record already has `url', migration does not touch it."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "u" '((handler . bmkp-jump-url-browse)
           (url . "https://existing.example")
           (location . "https://old.example")))
    (bookmark-gt-migrate-from-bookmark-plus)
    (let ((rec (assoc "u" bookmark-alist)))
      (should (equal (bookmark-prop-get rec 'url) "https://existing.example"))
      (should-not (assq 'location (cdr rec))))))

;;;; Bookkeeping strip

(ert-deftest bookmark-gt-migrate-test-strips-bookmark-plus-props ()
  "Bookmark+ bookkeeping keys are removed from migrated records.
The Dired state keys are preserved — bookmark-gt's Dired handler
consumes them the same way bookmark+ did."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "d" '((handler . bmkp-jump-dired)
           (filename . "/tmp/dir/")
           (bmkp-gt-load-index . 1)
           (buffer-name . "dir")
           (dired-directory . "/tmp/dir/")
           (dired-marked)
           (dired-subdirs)
           (dired-hidden-dirs)
           (dired-switches . "-al")
           (front-context-region-string)
           (rear-context-region-string)))
    (bookmark-gt-migrate-from-bookmark-plus)
    (let ((keys (mapcar #'car (cdr (assoc "d" bookmark-alist)))))
      (dolist (removed '(bmkp-gt-load-index buffer-name
                         front-context-region-string
                         rear-context-region-string))
        (should-not (memq removed keys)))
      (dolist (kept '(dired-directory dired-marked dired-subdirs
                      dired-hidden-dirs dired-switches))
        (should (memq kept keys))))))

(ert-deftest bookmark-gt-migrate-test-strips-empty-annotation-and-tags ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "d" '((handler . bmkp-jump-dired)
           (filename . "/tmp/dir/")
           (annotation)
           (tags)))
    (bookmark-gt-migrate-from-bookmark-plus)
    (let ((keys (mapcar #'car (cdr (assoc "d" bookmark-alist)))))
      (should-not (memq 'annotation keys))
      (should-not (memq 'tags keys)))))

;;;; Preservation

(ert-deftest bookmark-gt-migrate-test-preserves-tracking-fields ()
  "`visits', `last-visited', `created', `last-modified' survive."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "d" '((handler . bmkp-jump-dired)
           (filename . "/tmp/dir/")
           (visits . 7)
           (last-visited 27228 60426 0 0)
           (created 27221 38352 0 0)
           (last-modified 27221 38352 0 0)))
    (bookmark-gt-migrate-from-bookmark-plus)
    (let ((rec (assoc "d" bookmark-alist)))
      (should (= (bookmark-prop-get rec 'visits) 7))
      (should (equal (bookmark-prop-get rec 'last-visited)
                     '(27228 60426 0 0)))
      (should (equal (bookmark-prop-get rec 'created)
                     '(27221 38352 0 0)))
      (should (equal (bookmark-prop-get rec 'last-modified)
                     '(27221 38352 0 0))))))

;;;; No-op on unrelated records

(ert-deftest bookmark-gt-migrate-test-noop-on-native-records ()
  "Records with bookmark-gt or built-in handlers are left alone."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-migrate-test--push
     "n" '((handler . nil)
           (filename . "/tmp/plain.txt")))
    (bookmark-gt-migrate-test--push
     "u" '((handler . bookmark-gt-handler-url-jump)
           (url . "https://x")))
    (should (= (bookmark-gt-migrate-from-bookmark-plus) 0))
    (should (equal (bookmark-prop-get (assoc "n" bookmark-alist) 'handler) nil))
    (should (eq (bookmark-prop-get (assoc "u" bookmark-alist) 'handler)
                'bookmark-gt-handler-url-jump))))

(provide 'bookmark-gt-migrate-tests)
;;; bookmark-gt-migrate-tests.el ends here
