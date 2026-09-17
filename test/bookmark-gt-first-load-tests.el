;;; bookmark-gt-first-load-tests.el --- Operations before the first load  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Regression tests for the first bookmark operation of a session,
;; run while the file on disk has not been read yet.
;;
;; `bookmark-maybe-load-default-file' loads only while
;; `bookmark-alist' is empty.  An operation that fills the list
;; before asking for the load therefore keeps the file unread for
;; the rest of the session, and the next save writes the short
;; list in place of the file's contents.  The built-in
;; `bookmark-store' loads for this reason;
;; `bookmark-gt--push-record' goes around `bookmark-store', so
;; every path that reaches it has to load on its own.
;;
;; Each test writes a file, returns the session to the unloaded
;; state, runs one operation, and asserts the file still holds
;; what it held.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'bookmark-gt-core)
(require 'bookmark-gt-handlers)
(require 'bookmark-gt-migrate)
(require 'bookmark-gt-auto-update)

(defun bookmark-gt-first-load-test--names-on-disk ()
  "Return the bookmark names in `bookmark-default-file'."
  (let ((bookmark-alist nil))
    (bookmark-load bookmark-default-file t t nil)
    (mapcar #'car bookmark-alist)))

(defmacro bookmark-gt-first-load-test-with-unloaded-file (&rest body)
  "Run BODY with two bookmarks on disk and nothing loaded.
The bookmarks are named \"one\" and \"two\".  BODY runs with the
save filter installed, as `bookmark-gt-mode' installs it."
  (declare (indent 0) (debug t))
  `(bookmark-gt-test-with-clean-bookmarks
     (bookmark-gt-create-non-file "one" 'h nil)
     (bookmark-gt-create-non-file "two" 'h nil)
     (bookmark-write-file bookmark-default-file)
     ;; Return to the state at the start of a session.  Both
     ;; variables are let-bound by the enclosing macro, so this
     ;; mutation does not escape the test.
     (setq bookmark-alist nil
           bookmarks-already-loaded nil)
     (advice-add 'bookmark-save :around #'bookmark-gt--save-filter-advice)
     (unwind-protect
         (progn ,@body)
       (advice-remove 'bookmark-save #'bookmark-gt--save-filter-advice))))

;;;; Save first

(ert-deftest bookmark-gt-first-load-test-save-keeps-alist ()
  "A save as the first operation leaves `bookmark-alist' filled.
Stock `bookmark-save' loads from inside its own body.  With the
filter advice binding a filtered copy first, that load fills the
copy, and on exit the global `bookmark-alist' is empty while the
file counts as read — the state in which the next save writes an
empty file."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-save)
    (should (assoc "one" bookmark-alist))
    (should (assoc "two" bookmark-alist))
    ;; Both records must survive a second save.
    (bookmark-save)
    (should (equal (sort (bookmark-gt-first-load-test--names-on-disk) #'string<)
                   '("one" "two")))))

;;;; Creation first

(ert-deftest bookmark-gt-first-load-test-create-url-keeps-file ()
  "A URL bookmark created first is added to the file, not put in its place.
`bookmark-gt-create-url' reaches `bookmark-gt--create-record',
which has to load before it pushes."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-gt-create-url "https://example.com" "new-url")
    (should (assoc "one" bookmark-alist))
    (should (assoc "two" bookmark-alist))
    (bookmark-save)
    (should (equal (sort (bookmark-gt-first-load-test--names-on-disk) #'string<)
                   '("new-url" "one" "two")))))

(ert-deftest bookmark-gt-first-load-test-create-non-file-keeps-file ()
  "Any non-file creation loads first, whatever its handler.
`bookmark-gt-create-url' is one caller of
`bookmark-gt-create-non-file'; the kmacro, function, sequence and
browser-tab creators are others, and all of them arrive at the
same record builder."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-gt-create-non-file "new-plain" 'h nil)
    (bookmark-save)
    (should (equal (sort (bookmark-gt-first-load-test--names-on-disk) #'string<)
                   '("new-plain" "one" "two")))))

(ert-deftest bookmark-gt-first-load-test-create-temp-keeps-file ()
  "A temporary bookmark created first does not empty the file.
This is the costliest order of the three: the temp record fills
`bookmark-alist' and so keeps the file unread, and the save
filter then removes that record from what gets written, leaving
nothing to write."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-gt-create-non-file "temp" 'h
                                 (list (cons bookmark-gt-temp-key t)))
    (should (assoc "one" bookmark-alist))
    (should (assoc "two" bookmark-alist))
    (bookmark-save)
    ;; The two records stay; the temp one is excluded by the filter.
    (should (equal (sort (bookmark-gt-first-load-test--names-on-disk) #'string<)
                   '("one" "two")))))

;;;; Same-name policy

(ert-deftest bookmark-gt-first-load-test-name-policy-sees-file ()
  "The same-name policy judges a new name against the file's names.
The policy reads `bookmark-alist', so without the load it cannot
see the name it is asked about."
  (bookmark-gt-first-load-test-with-unloaded-file
    (let ((bookmark-gt-allow-same-name-bookmarks nil))
      (should-error (bookmark-gt-create-non-file "one" 'h nil)
                    :type 'user-error))))

;;;; Store first
;;
;; `bookmark-store' loads on its own, so a store arriving first
;; cannot lose records.  What it can lose is the policy: the
;; advice decides what a store onto a name in use does, and it
;; decides from `bookmark-alist' one step before the built-in
;; load fills it.

(defmacro bookmark-gt-first-load-test--with-store-advice (&rest body)
  "Run BODY with `bookmark-gt--store-advice' installed."
  (declare (indent 0) (debug t))
  `(progn
     (advice-add 'bookmark-store :around #'bookmark-gt--store-advice)
     (unwind-protect
         (progn ,@body)
       (advice-remove 'bookmark-store #'bookmark-gt--store-advice))))

(ert-deftest bookmark-gt-first-load-test-store-refuses-name-in-file ()
  "A store onto a name the file holds signals, rather than replacing it.
Under `nil' the setting permits no second record of a name, and
the record is not one the store may replace, so the store is
refused and the record in the file keeps its data."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-gt-first-load-test--with-store-advice
      (let ((bookmark-gt-allow-same-name-bookmarks nil))
        (should-error (bookmark-store "one" (list (cons 'handler 'other)) nil)
                      :type 'user-error)
        (should (eq (bookmark-prop-get (bookmark-get-bookmark "one") 'handler)
                    'h))))))

(ert-deftest bookmark-gt-first-load-test-store-adds-second-record ()
  "Under `always' a store onto a name in the file adds a record.
Without the load the advice sees no record of that name and lets
the built-in overwrite, which leaves the file's record replaced
instead of joined."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-gt-first-load-test--with-store-advice
      (let ((bookmark-gt-allow-same-name-bookmarks 'always))
        (bookmark-store "one" (list (cons 'handler 'other)) nil)
        (should (= (length (bookmark-gt--records-named "one")) 2))
        (should (= (length bookmark-alist) 3))))))

;;;; A file bookmark, for the paths that work from a buffer

(defmacro bookmark-gt-first-load-test-with-unloaded-file-bookmark (&rest body)
  "Run BODY with one file bookmark on disk and nothing loaded.
Binds `target' to a temporary file holding two lines, bookmarked
as \"file-bm\" at position 3."
  (declare (indent 0) (debug t))
  `(bookmark-gt-test-with-clean-bookmarks
     (let ((target (bookmark-gt-test--make-temp-bookmark-file)))
       (write-region "line one\nline two\n" nil target)
       (bookmark-gt-create-non-file "file-bm" 'h
                                    (list (cons 'filename target)
                                          (cons 'position 3)))
       (bookmark-write-file bookmark-default-file)
       (setq bookmark-alist nil
             bookmarks-already-loaded nil)
       ,@body)))

;;;; Following a rename first

(ert-deftest bookmark-gt-first-load-test-rename-follows-file ()
  "A rename as the first operation is followed in the record.
The old path is gone once the rename returns, so a record left
behind here cannot be repaired by any later operation."
  (bookmark-gt-first-load-test-with-unloaded-file-bookmark
    (let ((renamed (concat target "-renamed"))
          (bookmark-gt-track-renames t))
      (advice-add 'rename-file :around #'bookmark-gt--rename-file-advice)
      (unwind-protect
          (progn
            (rename-file target renamed)
            (should (equal (bookmark-gt-filename-of
                            (bookmark-get-bookmark "file-bm"))
                           renamed)))
        (advice-remove 'rename-file #'bookmark-gt--rename-file-advice)
        (when (file-exists-p renamed) (delete-file renamed))))))

;;;; Resolving a name from Lisp first

(ert-deftest bookmark-gt-first-load-test-resolve-finds-name ()
  "A record named in a Lisp call is found before the first load.
The prompting branch of `bookmark-gt--resolve' inherits a load
from `bookmark-completing-read'; a caller passing a name does
not, and used to be told the bookmark does not exist."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-gt-toggle-temp "one")
    (should (bookmark-gt-temp-p (bookmark-get-bookmark "one")))))

;;;; Cycling first

(ert-deftest bookmark-gt-first-load-test-cycle-finds-bookmarks ()
  "Cycling in a buffer finds the file's bookmarks before the first load."
  (bookmark-gt-first-load-test-with-unloaded-file-bookmark
    (with-current-buffer (find-file-noselect target)
      (unwind-protect
          (progn
            (goto-char (point-min))
            (bookmark-gt-cycle-next)
            (should (= (point) 3)))
        (set-buffer-modified-p nil)
        (kill-buffer)))))

;;;; Migrating first

(ert-deftest bookmark-gt-first-load-test-migrate-sees-records ()
  "A migration run first rewrites the records in the file.
Reporting nothing to migrate would read as a finished migration."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "plus" 'bmkp-jump-url-browse
                                 (list (cons 'location "https://example.com")))
    (bookmark-write-file bookmark-default-file)
    (setq bookmark-alist nil
          bookmarks-already-loaded nil)
    (should (= (bookmark-gt-migrate-from-bookmark-plus) 1))
    (should (eq (bookmark-prop-get (bookmark-get-bookmark "plus") 'handler)
                'bookmark-gt-handler-url-jump))))

;;;; Refreshing auto-update bookmarks first

(ert-deftest bookmark-gt-first-load-test-auto-update-now-loads ()
  "`bookmark-gt-auto-update-now' refreshes every record, so it loads.
The idle-timer tick deliberately does not: reading the file from
a timer is a side effect nobody asked for."
  (bookmark-gt-first-load-test-with-unloaded-file
    (bookmark-gt-auto-update-now)
    (should (bookmark-gt--records-named "one"))))

;;;; Highlights drawn before the file was read

(ert-deftest bookmark-gt-first-load-test-highlights-refresh-on-load ()
  "Overlays appear in a buffer opened before the bookmark file was read.
`bookmark-gt-highlight--refresh-buffer' had no records to draw
from at `find-file' time, and nothing asks it again for that
buffer, so the load is what refreshes it."
  (bookmark-gt-first-load-test-with-unloaded-file-bookmark
    (let ((bookmark-gt-highlight-enable t))
      (advice-add 'bookmark-load :after #'bookmark-gt-highlight--on-load)
      (unwind-protect
          (with-current-buffer (find-file-noselect target)
            (bookmark-gt-highlight--refresh-buffer)
            (should (null bookmark-gt-highlight--overlays))
            (bookmark-maybe-load-default-file)
            (should (= (length bookmark-gt-highlight--overlays) 1)))
        (advice-remove 'bookmark-load #'bookmark-gt-highlight--on-load)
        (when-let* ((buf (find-buffer-visiting target)))
          (with-current-buffer buf
            (set-buffer-modified-p nil)
            (kill-buffer)))))))

(provide 'bookmark-gt-first-load-tests)
;;; bookmark-gt-first-load-tests.el ends here
