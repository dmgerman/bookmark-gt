;;; bookmark-gt-id-tests.el --- Record identity  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for `bookmark-gt-id': its shape, when it is assigned,
;; what assigning must not disturb, and the four-way resolver
;; built on it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'test-helper)
(require 'bookmark-gt-core)

(defmacro bookmark-gt-id-test--with-counter (&rest body)
  "Run BODY with a deterministic id generator."
  (declare (indent 0) (debug t))
  `(let* ((n 0)
          (bookmark-gt-id-generator-function
           (lambda () (intern (format "bgt-test-%d" (cl-incf n))))))
     ,@body))

;;;; Shape

(ert-deftest bookmark-gt-id-test-is-a-symbol ()
  "An id is an interned symbol, so it cannot be mistaken for a name."
  (let ((id (bookmark-gt--generate-id)))
    (should (symbolp id))
    (should-not (stringp id))
    (should (eq id (intern (symbol-name id))))))

(ert-deftest bookmark-gt-id-test-prefix-keeps-it-a-symbol ()
  "The printed form reads back as a symbol, not a number."
  (let ((printed (symbol-name (bookmark-gt--generate-id))))
    (should (string-prefix-p "bgt-" printed))
    (should (symbolp (car (read-from-string printed))))))

(ert-deftest bookmark-gt-id-test-generates-distinct-ids ()
  (let ((ids (mapcar (lambda (_) (bookmark-gt--generate-id))
                     (number-sequence 1 50))))
    (should (= 50 (length (seq-uniq ids))))))

;;;; Assignment

(ert-deftest bookmark-gt-id-test-assigned-on-create ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (should (bookmark-gt-id-of (bookmark-get-bookmark "a")))))

(ert-deftest bookmark-gt-id-test-scan-fills-missing ()
  "Records arriving without an id get one on the next scan."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (let ((record (bookmark-get-bookmark "a")))
      (bookmark-prop-set record 'bookmark-gt-id nil)
      (should-not (bookmark-gt-id-of record))
      (should (= 1 (bookmark-gt-ensure-ids)))
      (should (bookmark-gt-id-of record)))))

(ert-deftest bookmark-gt-id-test-scan-is-idempotent ()
  "A second scan assigns nothing and leaves ids unchanged."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (bookmark-gt-ensure-ids)
    (let ((before (bookmark-gt-id-of (bookmark-get-bookmark "a"))))
      (should (= 0 (bookmark-gt-ensure-ids)))
      (should (eq before (bookmark-gt-id-of (bookmark-get-bookmark "a")))))))

(ert-deftest bookmark-gt-id-test-scan-avoids-collisions ()
  "A generator returning a duplicate is called again."
  (bookmark-gt-test-with-clean-bookmarks
    (let* ((ids '(dup dup dup fresh))
           (bookmark-gt-id-generator-function (lambda () (pop ids))))
      (bookmark-gt-set-non-file "a" 'h nil)   ; takes `dup'
      (bookmark-gt-set-non-file "b" 'h nil)   ; takes `dup' again
      (let ((a (bookmark-get-bookmark "a"))
            (b (seq-find (lambda (r) (equal (car r) "b")) bookmark-alist)))
        ;; Creation does not check, so both hold `dup' here.
        (should (eq (bookmark-gt-id-of a) (bookmark-gt-id-of b)))
        ;; The scan does check: clear one and it gets a distinct id.
        (bookmark-prop-set b 'bookmark-gt-id nil)
        (bookmark-gt-ensure-ids)
        (should-not (eq (bookmark-gt-id-of a) (bookmark-gt-id-of b)))))))

;;;; What assignment must not disturb

(ert-deftest bookmark-gt-id-test-scan-preserves-last-modified ()
  "Assigning ids must not restamp records: it would erase their history."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (let* ((record (bookmark-get-bookmark "a"))
           (stamp '(100 200 0 0)))
      (bookmark-prop-set record 'bookmark-gt-id nil)
      (bookmark-prop-set record 'last-modified stamp)
      (bookmark-gt-ensure-ids)
      (should (equal (bookmark-prop-get record 'last-modified) stamp)))))

(ert-deftest bookmark-gt-id-test-scan-does-not-run-observers ()
  "The scan must not run the change hook once per record."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (let ((calls 0))
      (bookmark-prop-set (bookmark-get-bookmark "a") 'bookmark-gt-id nil)
      (let ((bookmark-gt-set-after-hook
             (list (lambda (&rest _) (cl-incf calls)))))
        (bookmark-gt-ensure-ids))
      (should (= calls 0)))))

(ert-deftest bookmark-gt-id-test-temp-records-do-not-count ()
  "Ids on temporary records do not mark the bookmark file as changed."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t" 'h (list (cons bookmark-gt-temp-key t)))
    (bookmark-prop-set (bookmark-get-bookmark "t") 'bookmark-gt-id nil)
    (let ((bookmark-alist-modification-count 0))
      (bookmark-gt-ensure-ids)
      (should (= bookmark-alist-modification-count 0)))))

(ert-deftest bookmark-gt-id-test-persistent-records-count-once ()
  "Assigning ids to several records counts one change, not one each."
  (bookmark-gt-test-with-clean-bookmarks
    (dolist (n '("a" "b" "c"))
      (bookmark-gt-set-non-file n 'h nil)
      (bookmark-prop-set (bookmark-get-bookmark n) 'bookmark-gt-id nil))
    (let ((bookmark-alist-modification-count 0))
      (bookmark-gt-ensure-ids)
      (should (= bookmark-alist-modification-count 1)))))

;;;; Resolver

(ert-deftest bookmark-gt-id-test-resolve-record ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (let ((record (bookmark-get-bookmark "a")))
      (should (eq (bookmark-gt--resolve record) record)))))

(ert-deftest bookmark-gt-id-test-resolve-unique-name ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (should (eq (bookmark-gt--resolve "a") (bookmark-get-bookmark "a")))))

(ert-deftest bookmark-gt-id-test-resolve-id ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (let* ((record (bookmark-get-bookmark "a"))
           (id (bookmark-gt-id-of record)))
      (should (eq (bookmark-gt--resolve id) record)))))

(ert-deftest bookmark-gt-id-test-resolve-ambiguous-name-signals ()
  "Two records sharing a name is not an answer; batch mode cannot ask."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "dup" 'h-a nil)
    (bookmark-gt-set-non-file "dup" 'h-b nil)
    (should-error (bookmark-gt--resolve "dup"))))

(ert-deftest bookmark-gt-id-test-resolve-unknown-signals ()
  (bookmark-gt-test-with-clean-bookmarks
    (should-error (bookmark-gt--resolve "nope"))
    (should-error (bookmark-gt--resolve 'bgt-nothing))))

(ert-deftest bookmark-gt-id-test-resolve-duplicate-id-signals ()
  "Two records carrying one id is a broken reference, not a match."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "a" 'h nil)
    (bookmark-gt-set-non-file "b" 'h nil)
    (let ((id (bookmark-gt-id-of (bookmark-get-bookmark "a"))))
      (bookmark-prop-set (bookmark-get-bookmark "b") 'bookmark-gt-id id)
      (should-error (bookmark-gt--resolve id)))))

(ert-deftest bookmark-gt-id-test-resolve-nil-signals-in-batch ()
  "Nil means no bookmark given; batch mode cannot prompt for one."
  (bookmark-gt-test-with-clean-bookmarks
    (should-error (bookmark-gt--resolve nil))))

;;;; Display names

(ert-deftest bookmark-gt-id-test-display-name-plain-when-unique ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "solo" 'h nil)
    (should (equal (bookmark-gt-display-name-of (bookmark-get-bookmark "solo"))
                   "solo"))))

(ert-deftest bookmark-gt-id-test-display-name-suffixes-namesakes ()
  "Records sharing a name get distinct display names; nothing is stored."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "dup" 'h-a nil)
    (bookmark-gt-set-non-file "dup" 'h-b nil)
    (let* ((records (bookmark-gt--records-named "dup"))
           (shown (mapcar #'bookmark-gt-display-name-of records)))
      (should (equal shown '("dup" "dup<2>")))
      ;; The suffix is computed: the stored names are untouched.
      (should (equal (mapcar #'bookmark-name-from-full-record records)
                     '("dup" "dup"))))))

(provide 'bookmark-gt-id-tests)

;;; bookmark-gt-id-tests.el ends here
