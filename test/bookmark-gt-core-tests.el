;;; bookmark-gt-core-tests.el --- Tests for bookmark-gt-core   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for `bookmark-gt-set', same-name disambiguation, and the
;; extension-hook contract.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-core)

;;;; Same-name disambiguation
;;
;; bookmark-gt uses vanilla's own "<N>" suffix convention for
;; collisions (see the design note in bookmark-gt-core.el).  The
;; visible name of the second colliding bookmark is NAME<2>, the
;; third is NAME<3>, etc.

(ert-deftest bookmark-gt-test-disambiguate-no-collision ()
  "With no existing bookmarks, disambig is a no-op."
  (bookmark-gt-test-with-clean-bookmarks
    (should (equal (bookmark-gt-disambiguate-name "foo") "foo"))))

(ert-deftest bookmark-gt-test-disambiguate-single-collision ()
  "Second bookmark with the same name is renamed to NAME<2>."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'ignore nil)
    (should (equal (bookmark-gt-disambiguate-name "foo") "foo<2>"))))

(ert-deftest bookmark-gt-test-disambiguate-multiple-collisions ()
  "Third bookmark with the same name is renamed to NAME<3>."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'ignore nil)
    (bookmark-gt-set-non-file "foo" 'ignore nil)
    (should (equal (bookmark-gt-disambiguate-name "foo") "foo<3>"))))

(ert-deftest bookmark-gt-test-disambiguated-names-coexist ()
  "Both same-named bookmarks are present in `bookmark-alist' after store."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'ignore nil)
    (bookmark-gt-set-non-file "foo" 'ignore nil)
    (should (= (length bookmark-alist) 2))
    (should (equal (sort (mapcar #'car bookmark-alist) #'string<)
                   '("foo" "foo<2>")))))

;;;; Hook chain

(ert-deftest bookmark-gt-test-name-reader-hook-refines ()
  "First non-nil return from the name-reader hook chain wins."
  (bookmark-gt-test-with-clean-bookmarks
    (add-hook 'bookmark-gt-set-name-reader-hook
              (lambda (_default _ctx) nil))
    (add-hook 'bookmark-gt-set-name-reader-hook
              (lambda (default _ctx) (concat default "-refined")) 90)
    (let ((result (bookmark-gt-set-non-file "seed" 'ignore nil)))
      (should (equal (bookmark-gt-display-name (car result))
                     "seed-refined")))))

(ert-deftest bookmark-gt-test-tag-reader-hook-folds ()
  "Tag-reader hooks fold: each hook receives the previous hook's output."
  (bookmark-gt-test-with-clean-bookmarks
    (add-hook 'bookmark-gt-set-tag-reader-hook
              (lambda (_rec _seed) (list "one")))
    (add-hook 'bookmark-gt-set-tag-reader-hook
              (lambda (_rec seed) (append seed (list "two"))) 90)
    (let* ((result (bookmark-gt-set-non-file "foo" 'ignore nil))
           (data (cdr result)))
      (should (equal (alist-get 'tags data) '("one" "two"))))))

(ert-deftest bookmark-gt-test-after-hook-receives-stored-pair ()
  "After-hook receives the (NAME . DATA) pair actually stored."
  (bookmark-gt-test-with-clean-bookmarks
    (let (seen)
      (add-hook 'bookmark-gt-set-after-hook
                (lambda (entry) (push entry seen)))
      (let ((result (bookmark-gt-set-non-file "foo" 'ignore nil)))
        (should (= (length seen) 1))
        (should (eq (car seen) result))))))

;;;; Save / load round-trip

(ert-deftest bookmark-gt-test-save-load-plain-record ()
  "A stored non-file bookmark survives `bookmark-save' + `bookmark-load'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'my-handler '((url . "https://example.org")))
    (bookmark-save)
    (let ((bookmark-alist nil))
      (bookmark-load bookmark-default-file t t nil)
      (should (= (length bookmark-alist) 1))
      (should (equal (bookmark-prop-get (car bookmark-alist) 'url)
                     "https://example.org"))
      (should (eq (bookmark-prop-get (car bookmark-alist) 'handler)
                  'my-handler)))))

(ert-deftest bookmark-gt-test-save-load-disambig-names ()
  "Disambiguated `<N>' names survive save/load."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'ignore nil)
    (bookmark-gt-set-non-file "foo" 'ignore nil)
    (bookmark-save)
    (let ((bookmark-alist nil))
      (bookmark-load bookmark-default-file t t nil)
      (should (= (length bookmark-alist) 2))
      (should (equal (sort (mapcar #'car bookmark-alist) #'string<)
                     '("foo" "foo<2>"))))))

(provide 'bookmark-gt-core-tests)
;;; bookmark-gt-core-tests.el ends here
