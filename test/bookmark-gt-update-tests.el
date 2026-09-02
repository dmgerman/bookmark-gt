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

(provide 'bookmark-gt-update-tests)

;;; bookmark-gt-update-tests.el ends here
