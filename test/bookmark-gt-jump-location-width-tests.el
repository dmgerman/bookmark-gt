;;; bookmark-gt-jump-location-width-tests.el --- location field width  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The location field takes the space the candidate, tag and type
;; columns leave free.  These tests drive the arithmetic directly:
;; no minibuffer, no marginalia annotation pass, no frame.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-jump)

(defmacro bookmark-gt-jump-location-width-test-with (width name-column &rest body)
  "Run BODY with a WIDTH-column window and NAME-COLUMN alignment."
  (declare (indent 2) (debug t))
  `(let ((bookmark-gt-jump--name-column ,name-column)
         (marginalia-separator "  ")
         (marginalia-field-width 80))
     (cl-letf (((symbol-function 'bookmark-gt-jump--window-width)
                (lambda () ,width)))
       ,@body)))

(ert-deftest bookmark-gt-jump-location-width-test-uses-free-space ()
  "A wide window yields a wide field, not a fraction of 80."
  (bookmark-gt-jump-location-width-test-with 230 60
    (let ((bookmark-gt-jump-location-max-width nil))
      ;; 230 - 60 alignment - 26 used - 6 separators - 1 margin
      (should (= 137 (bookmark-gt-jump--location-width 26))))))

(ert-deftest bookmark-gt-jump-location-width-test-narrow-window-shrinks ()
  "A small window yields a small field."
  (bookmark-gt-jump-location-width-test-with 100 60
    (let ((bookmark-gt-jump-location-max-width nil))
      (should (= 7 (- 100 60 26 6 1)))
      (should (= 20 (bookmark-gt-jump--location-width 26))))))

(ert-deftest bookmark-gt-jump-location-width-test-keeps-a-minimum ()
  "The field never falls below the minimum, even with no space free."
  (bookmark-gt-jump-location-width-test-with 60 60
    (let ((bookmark-gt-jump-location-max-width nil))
      (should (= bookmark-gt-jump--location-min-width
                 (bookmark-gt-jump--location-width 26))))))

(ert-deftest bookmark-gt-jump-location-width-test-integer-bound-applies ()
  "An integer bound is a column count."
  (bookmark-gt-jump-location-width-test-with 230 60
    (let ((bookmark-gt-jump-location-max-width 100))
      (should (= 100 (bookmark-gt-jump--location-width 26))))))

(ert-deftest bookmark-gt-jump-location-width-test-float-bound-is-a-fraction ()
  "A float bound is a fraction of `marginalia-field-width'."
  (bookmark-gt-jump-location-width-test-with 230 60
    (let ((bookmark-gt-jump-location-max-width 0.5))
      (should (= 40 (bookmark-gt-jump--location-width 26))))))

(ert-deftest bookmark-gt-jump-location-width-test-bound-never-raises ()
  "A bound wider than the free space does not widen the field."
  (bookmark-gt-jump-location-width-test-with 120 60
    (let ((bookmark-gt-jump-location-max-width 500))
      (should (= 27 (bookmark-gt-jump--location-width 26))))))

(ert-deftest bookmark-gt-jump-location-width-test-tags-cost-the-location ()
  "Wider tag and type fields leave the location less room."
  (bookmark-gt-jump-location-width-test-with 230 60
    (let ((bookmark-gt-jump-location-max-width nil))
      (should (> (bookmark-gt-jump--location-width 10)
                 (bookmark-gt-jump--location-width 40))))))

(ert-deftest bookmark-gt-jump-location-width-test-falls-back-outside-a-read ()
  "With no read in progress, the name column comes from the defcustom."
  (let ((bookmark-gt-jump--name-column nil)
        (bookmark-gt-jump-name-max-width 58))
    ;; 58 rounds up to marginalia's next candidate-width step.
    (should (= 60 (bookmark-gt-jump--align-column)))))

(ert-deftest bookmark-gt-jump-location-width-test-column-rounds-up ()
  "The alignment column is a multiple of marginalia's step."
  (should (= 60 (bookmark-gt-jump--column-for 51)))
  (should (= 60 (bookmark-gt-jump--column-for 60)))
  (should (= 70 (bookmark-gt-jump--column-for 61))))

;;;; Field formatting

(ert-deftest bookmark-gt-jump-field-test-pads-short-string ()
  "A string narrower than WIDTH is padded with spaces to WIDTH."
  (should (equal "ab   "
                 (substring-no-properties
                  (bookmark-gt-jump--field "ab" 5 'bold)))))

(ert-deftest bookmark-gt-jump-field-test-positive-width-keeps-start ()
  "A positive WIDTH keeps the start of a long string."
  (let ((truncate-string-ellipsis "…"))
    (should (equal "abcd…"
                   (substring-no-properties
                    (bookmark-gt-jump--field "abcdefgh" 5 'bold))))))

(ert-deftest bookmark-gt-jump-field-test-negative-width-keeps-end ()
  "A negative WIDTH keeps the end of a long string."
  (let ((truncate-string-ellipsis "…"))
    (should (equal "…efgh"
                   (substring-no-properties
                    (bookmark-gt-jump--field "abcdefgh" -5 'bold))))))

(ert-deftest bookmark-gt-jump-field-test-uses-first-line ()
  "Only the first line of a multi-line string is shown."
  (should (equal "ab   "
                 (substring-no-properties
                  (bookmark-gt-jump--field "ab\ncd" 5 'bold)))))

(ert-deftest bookmark-gt-jump-field-test-face-and-help-echo ()
  "The field carries FACE; a cut field carries the full string as help-echo."
  (let ((cut (bookmark-gt-jump--field "abcdefgh" 5 'bold))
        (whole (bookmark-gt-jump--field "ab" 5 'bold)))
    (should (eq 'bold (get-text-property 0 'face cut)))
    (should (equal "abcdefgh" (get-text-property 0 'help-echo cut)))
    (should-not (get-text-property 0 'help-echo whole))))

(provide 'bookmark-gt-jump-location-width-tests)

;;; bookmark-gt-jump-location-width-tests.el ends here
