;;; bookmark-gt-kmacro-tests.el --- Tests for keyboard-macro bookmarks   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Covers the setter, jump handler, predicate, and registry
;; classification for `kmacro' bookmarks.  bookmark-gt keeps
;; kmacros as a distinct type from function bookmarks; records
;; are NOT interchangeable with bookmark+'s macro records (which
;; overload the function-bookmark handler).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt-handlers)

;;;; Registry classification

(ert-deftest bookmark-gt-kmacro-test-classifies-as-kmacro ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file
     "km" 'bookmark-gt-handler-kmacro-jump
     '((kmacro . [?a])))
    (should (eq (bookmark-gt-handler-type (car bookmark-alist)) 'kmacro))
    (should (bookmark-gt-handler-kmacro-p (car bookmark-alist)))
    (should (equal (bookmark-gt-handler-name (car bookmark-alist))
                   "Kmacro"))))

;;;; Setter stores a vector under `kmacro'

(ert-deftest bookmark-gt-kmacro-test-set-stores-vector ()
  "Passing a vector directly writes it under the `kmacro' key."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-kmacro "km-vec" [?x ?y])
    (let ((rec (car bookmark-alist)))
      (should (equal (bookmark-prop-get rec 'handler)
                     'bookmark-gt-handler-kmacro-jump))
      (should (equal (bookmark-prop-get rec 'kmacro) [?x ?y])))))

(ert-deftest bookmark-gt-kmacro-test-set-converts-string ()
  "A string macro is normalized to a vector via `read-kbd-macro'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-kmacro "km-str" "abc")
    (let ((v (bookmark-prop-get (car bookmark-alist) 'kmacro)))
      (should (vectorp v))
      (should (equal v (read-kbd-macro "abc" 'need-vector))))))

;;;; Jump replays the macro

(ert-deftest bookmark-gt-kmacro-test-jump-executes-macro ()
  "Jumping runs `execute-kbd-macro' on the stored vector.
Observable via the text the macro inserts."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-kmacro "km-run" [?h ?i])
    (with-temp-buffer
      (bookmark-jump "km-run")
      (should (equal (buffer-string) "hi")))))

;;;; Interactive read: errors only when there is nothing to pick

(ert-deftest bookmark-gt-kmacro-test-read-errors-with-nothing-available ()
  "`bookmark-gt--kmacro-read' errors when no macro source exists.
Rebinds `obarray' to a fresh one so no ambient named kmacros
leak into the test."
  (let ((last-kbd-macro nil)
        (obarray (obarray-make 1)))
    (should-error (bookmark-gt--kmacro-read) :type 'user-error)))

;;;; Named-kmacro helper

(ert-deftest bookmark-gt-kmacro-test-named-p-recognizes-symbol-function ()
  "A symbol whose `symbol-function' is a vector qualifies as a named kmacro."
  (let ((sym (make-symbol "bg-test-legacy-kmacro")))
    (fset sym [?q])
    (should (bookmark-gt--kmacro-named-p sym))))

(provide 'bookmark-gt-kmacro-tests)
;;; bookmark-gt-kmacro-tests.el ends here
