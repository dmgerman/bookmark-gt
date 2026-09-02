;;; bookmark-gt-update-tests.el --- create/update split  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for the commands that replaced `bookmark-gt-set':
;; `bookmark-gt-update', `bookmark-gt-delete', `bookmark-gt-rename',
;; and for the advice that keeps bookmark-gt's properties across an
;; overwrite performed by the built-in `bookmark-store'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'bookmark-gt)

(defmacro bookmark-gt-update-test--in-file (contents &rest body)
  "Run BODY in a live file-visiting buffer holding CONTENTS.
A real file, so `bookmark-make-record' has a `buffer-file-name'."
  (declare (indent 1) (debug t))
  `(let ((tmp (make-temp-file "bookmark-gt-update-")))
     (unwind-protect
         (progn
           (with-temp-file tmp (insert ,contents))
           (with-current-buffer (find-file-noselect tmp)
             (unwind-protect (progn ,@body) (kill-buffer))))
       (delete-file tmp))))

;;;; Update

(ert-deftest bookmark-gt-update-test-moves-to-point ()
  "Update re-points the bookmark at the current position."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--in-file "abcdefghij\n"
      (goto-char 2)
      (let ((record (bookmark-gt-create "here")))
        (goto-char 8)
        (bookmark-gt-update record)
        (should (= (bookmark-prop-get record 'position) 8))))))

(ert-deftest bookmark-gt-update-test-keeps-identity-and-tags ()
  "Update preserves the name, id, tags, creation time and visits."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--in-file "abcdefghij\n"
      (goto-char 2)
      (let* ((record (bookmark-gt-create "here"))
             (id (bookmark-gt-id-of record))
             (created (bookmark-prop-get record 'created)))
        (bookmark-gt-tags-set record '("alpha"))
        (bookmark-set-annotation record "note")
        (bookmark-prop-set record 'visits 4)
        (goto-char 8)
        (bookmark-gt-update record)
        (should (eq (bookmark-gt-id-of record) id))
        (should (equal (bookmark-gt-tags-of record) '("alpha")))
        (should (equal (bookmark-get-annotation record) "note"))
        (should (equal (bookmark-prop-get record 'created) created))
        (should (= (bookmark-prop-get record 'visits) 4))
        (should (equal (bookmark-name-from-full-record record) "here"))))))

(ert-deftest bookmark-gt-update-test-does-not-add-a-record ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--in-file "abcdefghij\n"
      (goto-char 2)
      (let ((record (bookmark-gt-create "here")))
        (goto-char 8)
        (bookmark-gt-update record)
        (should (= 1 (length bookmark-alist)))))))

(ert-deftest bookmark-gt-update-test-refuses-non-buffer-types ()
  "A URL bookmark has no position to capture; update says so."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--in-file "abc\n"
      (bookmark-gt-create-non-file "site" 'bookmark-gt-handler-url-jump
                                   (list (cons 'url "https://example.org")))
      (should-error (bookmark-gt-update (bookmark-get-bookmark "site"))
                    :type 'user-error))))

;;;; Delete

(ert-deftest bookmark-gt-delete-test-removes-the-record-given ()
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'always))
      (bookmark-gt-create-non-file "dup" 'h nil)
      (bookmark-gt-create-non-file "dup" 'h nil))
    (let* ((records (bookmark-gt--records-named "dup"))
           (second (nth 1 records)))
      (bookmark-gt-delete second)
      (should-not (memq second bookmark-alist))
      (should (memq (car records) bookmark-alist)))))

(ert-deftest bookmark-gt-delete-test-reports-sequence-referrers ()
  "Deleting a sequence member reports the sequences that referenced it."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "member" 'ignore nil)
    (bookmark-gt-create-sequence "seq" (list "member"))
    (bookmark-gt-ensure-ids)
    (let* ((member (bookmark-get-bookmark "member"))
           (reported nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq reported (apply #'format fmt args)))))
        (bookmark-gt-delete member))
      (should (string-match-p "seq" (or reported ""))))))

;;;; Rename

(ert-deftest bookmark-gt-rename-test-renames-that-record ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (let ((record (bookmark-get-bookmark "a")))
      (bookmark-gt-rename record "b")
      (should (equal (bookmark-name-from-full-record record) "b")))))

(ert-deftest bookmark-gt-rename-test-applies-the-same-name-policy ()
  "Renaming onto a name in use is refused, as creating one would be."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'never))
      (bookmark-gt-create-non-file "a" 'h nil)
      (bookmark-gt-create-non-file "b" 'h nil)
      (should-error (bookmark-gt-rename (bookmark-get-bookmark "b") "a")
                    :type 'user-error))))

;;;; The built-in store keeps our properties

(ert-deftest bookmark-gt-update-test-store-overwrite-preserves-props ()
  "`bookmark-store' overwriting a name keeps the id, tags and history.
This is the path `org-capture' and `org-refile' take on every
capture: they store onto a fixed name, and the built-in replaces
the record wholesale."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-mode 1)
    (unwind-protect
        (progn
          (bookmark-gt-create-non-file "org-capture-last-stored" 'h
                                       (list (cons 'filename "/tmp/a")))
          (let* ((record (bookmark-get-bookmark "org-capture-last-stored"))
                 (id (bookmark-gt-id-of record)))
            (bookmark-gt-tags-set record '("kept"))
            (bookmark-prop-set record 'visits 3)
            ;; What org does: store onto the same name again.
            (bookmark-store "org-capture-last-stored"
                            (list (cons 'filename "/tmp/b")) nil)
            (let ((after (bookmark-get-bookmark "org-capture-last-stored")))
              (should (equal (bookmark-gt-filename-of after) "/tmp/b"))
              (should (eq (bookmark-gt-id-of after) id))
              (should (equal (bookmark-gt-tags-of after) '("kept")))
              (should (= (bookmark-prop-get after 'visits) 3)))))
      (bookmark-gt-mode -1))))

;;;; Loading a file the policy forbids

(defun bookmark-gt-update-test--load-with (policy records)
  "Save RECORDS, reload under POLICY, return the resulting alist."
  (let ((bookmark-gt-allow-same-name-bookmarks 'always))
    (dolist (spec records)
      (bookmark-gt-create-non-file (car spec) 'h
                                   (list (cons 'filename (cdr spec))))))
  (bookmark-save)
  (let ((bookmark-alist nil)
        (bookmark-gt-allow-same-name-bookmarks policy))
    (bookmark-load bookmark-default-file t t nil)
    (bookmark-gt-enforce-same-name-policy)
    bookmark-alist))

(ert-deftest bookmark-gt-update-test-load-never-keeps-first ()
  "Under `never', a file with repeated names loads only the first of each."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((loaded (bookmark-gt-update-test--load-with
                   'never '(("todo" . "/tmp/a") ("todo" . "/tmp/b")))))
      (should (= 1 (length loaded))))))

(ert-deftest bookmark-gt-update-test-load-always-keeps-all ()
  (bookmark-gt-test-with-clean-bookmarks
    (let ((loaded (bookmark-gt-update-test--load-with
                   'always '(("todo" . "/tmp/a") ("todo" . "/tmp/b")))))
      (should (= 2 (length loaded))))))

(ert-deftest bookmark-gt-update-test-load-keeps-different-destinations ()
  "The default keeps repeated names that point at different files."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((loaded (bookmark-gt-update-test--load-with
                   'different-destination
                   '(("todo" . "/tmp/a") ("todo" . "/tmp/b")))))
      (should (= 2 (length loaded))))))

(ert-deftest bookmark-gt-update-test-load-drops-same-destination ()
  "The default drops a repeat that points where a kept record points."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((loaded (bookmark-gt-update-test--load-with
                   'different-destination
                   '(("todo" . "/tmp/a") ("todo" . "/tmp/a")))))
      (should (= 1 (length loaded))))))

(ert-deftest bookmark-gt-update-test-load-drop-does-not-schedule-a-write ()
  "Dropping must not count as a change: that would make the loss permanent."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'always))
      (bookmark-gt-create-non-file "todo" 'h (list (cons 'filename "/tmp/a")))
      (bookmark-gt-create-non-file "todo" 'h (list (cons 'filename "/tmp/a"))))
    (let ((bookmark-gt-allow-same-name-bookmarks 'never)
          (bookmark-alist-modification-count 0))
      (bookmark-gt--drop-same-name-violations)
      (should (= bookmark-alist-modification-count 0)))))

(ert-deftest bookmark-gt-update-test-scan-drops-a-stray-store ()
  "A duplicate made by the built-in store is dropped by the next scan.
`bookmark-set' is left alone for Lisp callers, so it can put a
record into the alist that `bookmark-gt-create' would refuse.
The id scan is where that is caught."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'never))
      (bookmark-gt-create-non-file "todo" 'h (list (cons 'filename "/tmp/a")))
      ;; NO-OVERWRITE: the built-in pushes a second record.
      (bookmark-store "todo" (list (cons 'filename "/tmp/b")) t)
      (should (= 2 (length (bookmark-gt--records-named "todo"))))
      (bookmark-gt-enforce-same-name-policy)
      (should (= 1 (length (bookmark-gt--records-named "todo")))))))

(ert-deftest bookmark-gt-update-test-scan-keeps-legitimate-namesakes ()
  "The scan leaves alone what the setting permits."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'different-destination))
      (bookmark-gt-create-non-file "todo" 'h (list (cons 'filename "/tmp/a")))
      (bookmark-gt-create-non-file "todo" 'h (list (cons 'filename "/tmp/b")))
      (bookmark-gt-enforce-same-name-policy)
      (should (= 2 (length (bookmark-gt--records-named "todo")))))))

;;;; Broken sequence members

(ert-deftest bookmark-gt-update-test-scan-reports-broken-sequence ()
  "Deleting a member makes the scan report the sequence that used it."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "member" 'ignore nil)
    (bookmark-gt-create-sequence "seq" (list "member"))
    (bookmark-gt-ensure-ids)
    (bookmark-gt-delete-record (bookmark-get-bookmark "member"))
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) reported))))
        (bookmark-gt-enforce-same-name-policy))
      (should (seq-find (lambda (m) (string-match-p "no longer resolve" m))
                        reported)))))

(ert-deftest bookmark-gt-update-test-scan-quiet-when-members-resolve ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "member" 'ignore nil)
    (bookmark-gt-create-sequence "seq" (list "member"))
    (bookmark-gt-ensure-ids)
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) reported))))
        (bookmark-gt-enforce-same-name-policy))
      (should-not (seq-find (lambda (m) (string-match-p "no longer resolve" m))
                            reported)))))

;;;; Drawing the list buffer must not delete anything

(ert-deftest bookmark-gt-update-test-render-does-not-enforce ()
  "The id scan assigns ids; it does not remove records.
`bookmark-gt-list--entries' runs on every redraw, and a redraw
follows every change, so enforcing there would let a change to
one bookmark delete another."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'never))
      (bookmark-gt-create-non-file "todo" 'h (list (cons 'filename "/tmp/a")))
      (bookmark-store "todo" (list (cons 'filename "/tmp/b")) t)
      (should (= 2 (length (bookmark-gt--records-named "todo"))))
      (bookmark-gt-ensure-ids)
      (should (= 2 (length (bookmark-gt--records-named "todo"))))
      ;; Both have ids, so the scan did its own work.
      (should (seq-every-p #'bookmark-gt-id-of
                           (bookmark-gt--records-named "todo"))))))

;;;; bookmark-store under the same-name policy
;;
;; burly asks the user for a name and stores with `bookmark-store',
;; so without this a saved window layout replaces whatever bookmark
;; already had that name.

(defmacro bookmark-gt-update-test--with-mode (&rest body)
  "Run BODY with `bookmark-gt-mode' on."
  (declare (indent 0) (debug t))
  `(progn
     (bookmark-gt-mode 1)
     (unwind-protect (progn ,@body) (bookmark-gt-mode -1))))

(defun bookmark-gt-update-test--burly (url)
  "Return a burly-shaped record alist for URL."
  (list (cons 'url url) (cons 'handler 'burly-bookmark-handler)))

(ert-deftest bookmark-gt-store-test-collision-keeps-both-when-permitted ()
  "A burly save onto a file bookmark's name does not replace it."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--with-mode
      (let ((bookmark-gt-allow-same-name-bookmarks 'always))
        (bookmark-gt-create-non-file "notes" 'h
                                     (list (cons 'filename "/tmp/important.org")))
        (bookmark-store "notes" (bookmark-gt-update-test--burly "burly:a") nil)
        (let ((records (bookmark-gt--records-named "notes")))
          (should (= 2 (length records)))
          (should (seq-find (lambda (r)
                              (equal (bookmark-gt-filename-of r)
                                     "/tmp/important.org"))
                            records)))))))

(ert-deftest bookmark-gt-store-test-collision-signals-when-refused ()
  "With `never', the same save is refused rather than replacing."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--with-mode
      (let ((bookmark-gt-allow-same-name-bookmarks 'never))
        (bookmark-gt-create-non-file "notes" 'h
                                     (list (cons 'filename "/tmp/important.org")))
        (should-error
         (bookmark-store "notes" (bookmark-gt-update-test--burly "burly:a") nil)
         :type 'user-error)
        (should (equal (bookmark-gt-filename-of (bookmark-get-bookmark "notes"))
                       "/tmp/important.org"))))))

(ert-deftest bookmark-gt-store-test-resave-replaces-its-own ()
  "Re-saving a burly bookmark updates it instead of adding another.
Its URL changes on every save, so the same-name policy alone
would keep making new records."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--with-mode
      (let ((bookmark-gt-allow-same-name-bookmarks 'always))
        (bookmark-store "layout" (bookmark-gt-update-test--burly "burly:a") nil)
        (bookmark-store "layout" (bookmark-gt-update-test--burly "burly:b") nil)
        (let ((records (bookmark-gt--records-named "layout")))
          (should (= 1 (length records)))
          (should (equal (bookmark-gt-url-of (car records)) "burly:b")))))))

(ert-deftest bookmark-gt-store-test-resave-keeps-properties ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--with-mode
      (bookmark-store "layout" (bookmark-gt-update-test--burly "burly:a") nil)
      (let* ((record (bookmark-get-bookmark "layout"))
             (id (bookmark-gt-id-of record)))
        (bookmark-gt-tags-set record '("kept"))
        (bookmark-store "layout" (bookmark-gt-update-test--burly "burly:b") nil)
        (let ((after (bookmark-get-bookmark "layout")))
          (should (eq (bookmark-gt-id-of after) id))
          (should (equal (bookmark-gt-tags-of after) '("kept"))))))))

(ert-deftest bookmark-gt-store-test-same-type-not-listed-is-not-replaced ()
  "Only handlers in `bookmark-gt-unique-name-handlers' replace on re-store.
Two ordinary file bookmarks of one name are what `always' asks
for, and must not be collapsed into one."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--with-mode
      (let ((bookmark-gt-allow-same-name-bookmarks 'always))
        (bookmark-store "notes" (list (cons 'filename "/tmp/a")) nil)
        (bookmark-store "notes" (list (cons 'filename "/tmp/b")) nil)
        (should (= 2 (length (bookmark-gt--records-named "notes"))))))))

(ert-deftest bookmark-gt-store-test-resave-with-a-namesake-of-another-kind ()
  "A re-save replaces its own record, not whichever comes first.
Several bookmarks may share a name, so the record to replace is
the one of the incoming kind — `bookmark-get-bookmark' would
return the first, which may be someone else's."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-update-test--with-mode
      (let ((bookmark-gt-allow-same-name-bookmarks 'always))
        (bookmark-store "test" (bookmark-gt-update-test--burly "burly:v1") nil)
        (bookmark-gt-create-non-file "test" 'h
                                     (list (cons 'filename "/tmp/notes.org")))
        (bookmark-store "test" (bookmark-gt-update-test--burly "burly:v2") nil)
        (let ((records (bookmark-gt--records-named "test")))
          (should (= 2 (length records)))
          ;; The file bookmark is untouched.
          (should (seq-find (lambda (r)
                              (equal (bookmark-gt-filename-of r) "/tmp/notes.org"))
                            records))
          ;; One burly record, updated in place.
          (let ((burly (seq-filter
                        (lambda (r)
                          (eq (bookmark-prop-get r 'handler)
                              'burly-bookmark-handler))
                        records)))
            (should (= 1 (length burly)))
            (should (equal (bookmark-gt-url-of (car burly)) "burly:v2"))))))))

(provide 'bookmark-gt-update-tests)

;;; bookmark-gt-update-tests.el ends here
