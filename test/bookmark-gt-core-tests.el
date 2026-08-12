;;; bookmark-gt-core-tests.el --- Tests for bookmark-gt-core   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for `bookmark-gt-set', same-name disambiguation, and the
;; extension-hook contract.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-core)

;;;; Same-name disambiguation
;;
;; bookmark-gt uses the same "<N>" suffix convention as `bookmark.el' for
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
  "Third bookmark with the same name is renamed to NAME<3>.
Rebinds both `bookmark-gt-same-name-overwrite' and
`bookmark-gt-allow-duplicate-names' to nil so the store path
runs through the `<N>' disambiguation branch."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-same-name-overwrite nil)
          (bookmark-gt-allow-duplicate-names nil))
      (bookmark-gt-set-non-file "foo" 'ignore nil)
      (bookmark-gt-set-non-file "foo" 'ignore nil)
      (should (equal (bookmark-gt-disambiguate-name "foo") "foo<3>")))))

(ert-deftest bookmark-gt-test-disambiguated-names-coexist ()
  "Both same-named bookmarks are present in `bookmark-alist' after store.
Both overwrite AND allow-duplicate-names are disabled here so
the test exercises the pure `<N>' disambiguation path."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-same-name-overwrite nil)
          (bookmark-gt-allow-duplicate-names nil))
      (bookmark-gt-set-non-file "foo" 'ignore nil)
      (bookmark-gt-set-non-file "foo" 'ignore nil)
      (should (= (length bookmark-alist) 2))
      (should (equal (sort (mapcar #'car bookmark-alist) #'string<)
                     '("foo" "foo<2>"))))))

;;;; Same-name overwrite policy
;;
;; Default: same name + same handler + same filename overwrites in
;; place; anything else (different handler, different file, or the
;; NO-OVERWRITE arg to `bookmark-gt-set') disambiguates.

(ert-deftest bookmark-gt-test-overwrite-same-name-same-handler ()
  "Same-name same-handler collision replaces the existing record."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'my-h '((url . "https://a.example")))
    (bookmark-gt-set-non-file "foo" 'my-h '((url . "https://b.example")))
    (should (= (length bookmark-alist) 1))
    (should (equal (bookmark-prop-get (car bookmark-alist) 'url)
                   "https://b.example"))))

(ert-deftest bookmark-gt-test-overwrite-different-handler-coexists ()
  "Same name but different handler: two literal records coexist by default."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'h-a '((url . "https://a")))
    (bookmark-gt-set-non-file "foo" 'h-b '((url . "https://b")))
    (should (= (length bookmark-alist) 2))
    (should (equal (mapcar #'car bookmark-alist) '("foo" "foo")))))

(ert-deftest bookmark-gt-test-overwrite-different-handler-disambigs-when-off ()
  "With `bookmark-gt-allow-duplicate-names' nil, different-handler collision
still disambiguates with `<N>'."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-duplicate-names nil))
      (bookmark-gt-set-non-file "foo" 'h-a '((url . "https://a")))
      (bookmark-gt-set-non-file "foo" 'h-b '((url . "https://b")))
      (should (equal (sort (mapcar #'car bookmark-alist) #'string<)
                     '("foo" "foo<2>"))))))

(ert-deftest bookmark-gt-test-overwrite-different-filename-coexists ()
  "Same name + same handler but different filenames: both stored literally.
That is the primary use case for `bookmark-gt-allow-duplicate-names'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'h
                              '((filename . "/tmp/a") (position . 1)))
    (bookmark-gt-set-non-file "foo" 'h
                              '((filename . "/tmp/b") (position . 1)))
    (should (= (length bookmark-alist) 2))
    (should (equal (mapcar #'car bookmark-alist) '("foo" "foo")))))

(ert-deftest bookmark-gt-test-overwrite-flag-off-allows-duplicates ()
  "With `bookmark-gt-same-name-overwrite' nil (but allow-duplicate-names
default t), same-file collisions produce two records with the same name."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-same-name-overwrite nil))
      (bookmark-gt-set-non-file "foo" 'my-h '((url . "https://a")))
      (bookmark-gt-set-non-file "foo" 'my-h '((url . "https://b")))
      (should (= (length bookmark-alist) 2))
      (should (equal (mapcar #'car bookmark-alist) '("foo" "foo"))))))

(ert-deftest bookmark-gt-test-no-overwrite-forces-disambig ()
  "The NO-OVERWRITE arg forces `<N>' disambiguation even with the
default policy (both flags on)."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "foo" 'h '((filename . "/tmp/a")))
    ;; Interactive-style: pass NAME + NO-OVERWRITE (non-nil).
    (let ((chosen (bookmark-gt--resolve-collision
                   "foo" '((filename . "/tmp/b") (handler . h)) t)))
      (should (equal chosen "foo<2>")))))

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
  "Disambiguated `<N>' names survive save/load.
Both overwrite and allow-duplicate-names are disabled here so
the pure `<N>' path runs and produces two distinctly-named
records for the round-trip."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-same-name-overwrite nil)
          (bookmark-gt-allow-duplicate-names nil))
      (bookmark-gt-set-non-file "foo" 'ignore nil)
      (bookmark-gt-set-non-file "foo" 'ignore nil)
      (bookmark-save)
      (let ((bookmark-alist nil))
        (bookmark-load bookmark-default-file t t nil)
        (should (= (length bookmark-alist) 2))
        (should (equal (sort (mapcar #'car bookmark-alist) #'string<)
                       '("foo" "foo<2>")))))))

;;;; Relocate

(ert-deftest bookmark-gt-test-relocate-file-updates-filename ()
  "File bookmark relocation swaps `filename' and preserves `position'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "f" nil (list (cons 'filename "/tmp/a.txt") (cons 'position 42)))
    (cl-letf (((symbol-function 'read-file-name)
               (lambda (&rest _) "/tmp/b.txt")))
      (bookmark-gt-relocate "f"))
    (let ((rec (bookmark-get-bookmark "f")))
      (should (equal (bookmark-prop-get rec 'filename) "/tmp/b.txt"))
      (should (= (bookmark-prop-get rec 'position) 42)))))

(ert-deftest bookmark-gt-test-relocate-url-updates-url ()
  "URL bookmark relocation swaps the `url' key."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "u" 'my-h (list (cons 'url "https://old.example")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "https://new.example")))
      (bookmark-gt-relocate "u"))
    (should (equal (bookmark-prop-get (bookmark-get-bookmark "u") 'url)
                   "https://new.example"))))

(ert-deftest bookmark-gt-test-relocate-no-location-errors ()
  "Records with neither `filename' nor `url' signal `user-error'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "x" 'my-h nil)
    (should-error (bookmark-gt-relocate "x") :type 'user-error)))

(ert-deftest bookmark-gt-test-relocate-fires-after-hook ()
  "Relocation fires `bookmark-gt-set-after-hook' with the updated entry."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "f" nil (list (cons 'filename "/tmp/a.txt") (cons 'position 1)))
    (let (seen)
      (add-hook 'bookmark-gt-set-after-hook
                (lambda (entry) (push entry seen)))
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) "/tmp/b.txt")))
        (bookmark-gt-relocate "f"))
      (should (= (length seen) 1))
      (should (equal (bookmark-prop-get (car seen) 'filename)
                     "/tmp/b.txt")))))

(provide 'bookmark-gt-core-tests)
;;; bookmark-gt-core-tests.el ends here
