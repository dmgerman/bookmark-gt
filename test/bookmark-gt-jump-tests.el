;;; bookmark-gt-jump-tests.el --- Tests for bookmark-gt-jump   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for candidate construction, the orderless particle
;; dispatcher (type + tag), and the fallback reader path.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-jump)

;;;; Candidate construction

(ert-deftest bookmark-gt-jump-test-candidate-name-property ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let ((cand (bookmark-gt-jump--make-candidate (car bookmark-alist))))
      (should (equal (get-text-property 0 'bookmark-gt-name cand) "u")))))

(ert-deftest bookmark-gt-jump-test-candidate-particles ()
  "The particle string carries both `@Type' and `;tag' tokens."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")
                                (tags . ("proj" "urgent"))))
    (let* ((cand (bookmark-gt-jump--make-candidate (car bookmark-alist)))
           (particles (get-text-property 0 'bookmark-gt-particles cand)))
      (should (string-search "@URL" particles))
      (should (string-search ";proj" particles))
      (should (string-search ";urgent" particles)))))

(ert-deftest bookmark-gt-jump-test-candidate-type-char ()
  "The narrow char comes from the handler entry's :name (first char lowercased)."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")))
    (let ((cand (bookmark-gt-jump--make-candidate (car bookmark-alist))))
      (should (eq (get-text-property 0 'consult--type cand) ?u)))))

;;;; Orderless dispatcher

(ert-deftest bookmark-gt-jump-test-orderless-type-matches ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")))
    (bookmark-gt-set-non-file "e" 'eww-bookmark-jump nil)
    (let* ((cands (mapcar #'bookmark-gt-jump--make-candidate bookmark-alist))
           (matcher (bookmark-gt-jump-type-dispatch "URL")))
      (should (= (length (seq-filter matcher cands)) 1))
      (should (equal (get-text-property 0 'bookmark-gt-name
                                        (car (seq-filter matcher cands)))
                     "u")))))

(ert-deftest bookmark-gt-jump-test-orderless-tag-matches ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h '((tags . ("proj"))))
    (bookmark-gt-set-non-file "b" 'h '((tags . ("other"))))
    (let* ((cands (mapcar #'bookmark-gt-jump--make-candidate bookmark-alist))
           (matcher (bookmark-gt-jump-tag-dispatch "proj")))
      (should (= (length (seq-filter matcher cands)) 1)))))

(ert-deftest bookmark-gt-jump-test-orderless-dispatcher-routes ()
  "The dispatcher returns the right matcher for `@' vs `;' vs other."
  (let ((atprefix (bookmark-gt-jump--orderless-dispatcher "@url" 0 1))
        (semi     (bookmark-gt-jump--orderless-dispatcher ";tag" 0 1))
        (plain    (bookmark-gt-jump--orderless-dispatcher "foo" 0 1)))
    (should (eq (car atprefix) #'bookmark-gt-jump-type-dispatch))
    (should (equal (cdr atprefix) "url"))
    (should (eq (car semi) #'bookmark-gt-jump-tag-dispatch))
    (should (equal (cdr semi) "tag"))
    (should (null plain))))

;;;; Narrow-char registry derivation

(ert-deftest bookmark-gt-jump-test-narrow-alist-from-registry ()
  "The narrow alist has one entry per registered handler."
  (let ((alist (bookmark-gt-jump--narrow-alist)))
    (should (assoc ?u alist))    ; URL
    (should (assoc ?f alist))))  ; File

;;;; Reader fallback path (no consult)

(ert-deftest bookmark-gt-jump-test-plain-reader-dispatches ()
  "Without consult, `bookmark-gt-jump' still dispatches through `bookmark-jump'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let (seen)
      (cl-letf
          (((symbol-function 'featurep)
            (lambda (feat) (not (eq feat 'consult))))
           ((symbol-function 'completing-read)
            (lambda (&rest _)
              ;; Return the visible candidate string.
              (bookmark-gt-jump--make-candidate (car bookmark-alist))))
           ((symbol-function 'browse-url)
            (lambda (url &rest _) (push url seen))))
        (bookmark-gt-jump))
      (should (equal seen '("https://example.org"))))))

;;;; Filter state

(ert-deftest bookmark-gt-jump-test-filter-narrows-candidates ()
  "`bookmark-gt-jump--filter-alist' returns only records carrying all filters."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h '((tags . ("proj" "urgent"))))
    (bookmark-gt-set-non-file "b" 'h '((tags . ("proj"))))
    (bookmark-gt-set-non-file "c" 'h '((tags . ("other"))))
    (let ((bookmark-gt-jump--active-filters '("proj")))
      (should (= (length (bookmark-gt-jump--filter-alist bookmark-alist))
                 2)))
    (let ((bookmark-gt-jump--active-filters '("proj" "urgent")))
      (should (= (length (bookmark-gt-jump--filter-alist bookmark-alist))
                 1)))))

(provide 'bookmark-gt-jump-tests)
;;; bookmark-gt-jump-tests.el ends here
