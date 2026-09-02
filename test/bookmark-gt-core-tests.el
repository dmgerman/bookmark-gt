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
      (should (equal (car result)
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

;;;; File-type handler dispatch

(ert-deftest bookmark-gt-file-type-handler-test-dispatches-on-match ()
  "On regexp match, the mapped function is called with the record."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "f" nil (list (cons 'filename "/tmp/report.pdf")))
    (let* ((called nil)
           (bookmark-gt-file-type-handlers
            `(("\\.pdf\\'" . ,(lambda (bmk) (setq called bmk))))))
      (bookmark-gt--file-type-handler-advice
       (lambda (&rest _) (error "orig-fn should not be called"))
       (assoc "f" bookmark-alist))
      (should called)
      (should (equal (bookmark-prop-get called 'filename)
                     "/tmp/report.pdf")))))

(ert-deftest bookmark-gt-file-type-handler-test-delegates-when-no-match ()
  "When no regexp matches, the original handler is invoked."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "f" nil (list (cons 'filename "/tmp/report.txt")))
    (let* ((delegated nil)
           (bookmark-gt-file-type-handlers
            '(("\\.pdf\\'" . ignore))))
      (bookmark-gt--file-type-handler-advice
       (lambda (bmk &rest _) (setq delegated bmk))
       (assoc "f" bookmark-alist))
      (should delegated)
      (should (equal (bookmark-prop-get delegated 'filename)
                     "/tmp/report.txt")))))

(ert-deftest bookmark-gt-file-type-handler-test-empty-list-delegates ()
  "With `bookmark-gt-file-type-handlers' nil, the advice is a no-op."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "f" nil (list (cons 'filename "/tmp/anything")))
    (let* ((delegated nil)
           (bookmark-gt-file-type-handlers nil))
      (bookmark-gt--file-type-handler-advice
       (lambda (bmk &rest _) (setq delegated bmk))
       (assoc "f" bookmark-alist))
      (should delegated))))

(ert-deftest bookmark-gt-file-type-handler-test-first-match-wins ()
  "Regexps are tried in list order; earlier entry wins."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "f" nil (list (cons 'filename "/tmp/report.pdf")))
    (let* ((first-called nil)
           (second-called nil)
           (bookmark-gt-file-type-handlers
            `(("\\.pdf\\'" . ,(lambda (_bmk) (setq first-called t)))
              ("\\.pdf\\'" . ,(lambda (_bmk) (setq second-called t))))))
      (bookmark-gt--file-type-handler-advice
       (lambda (&rest _) nil)
       (assoc "f" bookmark-alist))
      (should first-called)
      (should-not second-called))))

;;;; Timestamps: created + last-modified

(ert-deftest bookmark-gt-timestamps-test-created-set-on-store ()
  "`created' and `last-modified' are stamped on the initial store."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t" 'ignore nil)
    (let ((rec (assoc "t" bookmark-alist)))
      (should (bookmark-prop-get rec 'created))
      (should (bookmark-prop-get rec 'last-modified)))))

(ert-deftest bookmark-gt-timestamps-test-created-preserved-on-migration-shape ()
  "Callers that pass their own `created' keep it (migration case)."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((preserved '(27221 38352 0 0)))
      (bookmark-gt-set-non-file
       "t" 'ignore (list (cons 'created preserved)))
      (should (equal (bookmark-prop-get (assoc "t" bookmark-alist) 'created)
                     preserved)))))

(ert-deftest bookmark-gt-timestamps-test-last-modified-bumped-on-mutation ()
  "`last-modified' advances when a mutation fires `--after-mutation'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file "t" 'ignore nil)
    (let* ((rec (assoc "t" bookmark-alist))
           (initial (bookmark-prop-get rec 'last-modified)))
      ;; Ensure a distinguishable time delta by sleeping briefly.
      (sleep-for 0.01)
      (bookmark-gt-tags-set rec '("tag"))
      (let ((updated (bookmark-prop-get rec 'last-modified)))
        (should (time-less-p initial updated))))))

;;;; Auto-temp on store

(ert-deftest bookmark-gt-auto-temp-test-marks-matching-name ()
  "Names matching `bookmark-gt-auto-temp-names' are marked temp on store."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-auto-temp-names '("\\`org-capture-last-stored\\'")))
      (advice-add 'bookmark-store :after #'bookmark-gt--auto-temp-advice)
      (unwind-protect
          (progn
            (bookmark-store "org-capture-last-stored"
                            '((filename . "/tmp/x") (position . 1))
                            nil)
            (should (bookmark-gt-temp-p
                     (bookmark-get-bookmark "org-capture-last-stored"))))
        (advice-remove 'bookmark-store #'bookmark-gt--auto-temp-advice)))))

(ert-deftest bookmark-gt-auto-temp-test-leaves-nonmatching-alone ()
  "Records whose name does not match are not marked temp."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-auto-temp-names '("\\`org-capture-last-stored\\'")))
      (advice-add 'bookmark-store :after #'bookmark-gt--auto-temp-advice)
      (unwind-protect
          (progn
            (bookmark-store "regular"
                            '((filename . "/tmp/x") (position . 1))
                            nil)
            (should-not (bookmark-gt-temp-p
                         (bookmark-get-bookmark "regular"))))
        (advice-remove 'bookmark-store #'bookmark-gt--auto-temp-advice)))))

(ert-deftest bookmark-gt-auto-temp-test-empty-list-is-no-op ()
  "An empty `bookmark-gt-auto-temp-names' marks nothing."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-auto-temp-names nil))
      (advice-add 'bookmark-store :after #'bookmark-gt--auto-temp-advice)
      (unwind-protect
          (progn
            (bookmark-store "org-capture-last-stored"
                            '((filename . "/tmp/x") (position . 1))
                            nil)
            (should-not (bookmark-gt-temp-p
                         (bookmark-get-bookmark "org-capture-last-stored"))))
        (advice-remove 'bookmark-store #'bookmark-gt--auto-temp-advice)))))

;;;; jump-via override: skip only annotation, not display

(defun bookmark-gt-core-tests--handler-that-opens-buffer (_bookmark)
  "Test handler: switch to a fresh buffer, then throw skip-post-handler.
Emulates the shape of the kmacro / function handlers: they leave
`current-buffer' pointing at their target, then throw.  The
override must still call the display-function on that target
after the throw."
  (let ((buf (generate-new-buffer " *bg-target-test*")))
    (switch-to-buffer buf)
    (insert "target")
    (bookmark-gt-skip-post-handler 'test)))

(ert-deftest bookmark-gt-jump-via-override-displays-buffer-after-throw ()
  "The override's throw must not skip the display step.
Regression test for the reported bug where a kmacro bookmark
that ran `find-file' did open the target Dired buffer but the
buffer was never displayed because the throw jumped out of
`bookmark--jump-via' before `funcall display-function' ran."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "bg-throw" 'bookmark-gt-core-tests--handler-that-opens-buffer nil)
    (let ((was-enabled bookmark-gt-mode))
      (unwind-protect
          (progn
            (unless was-enabled (bookmark-gt-mode 1))
            (bookmark-jump "bg-throw")
            (let ((buf (get-buffer " *bg-target-test*")))
              (unwind-protect
                  (progn
                    (should (buffer-live-p buf))
                    (should (eq (window-buffer (selected-window)) buf)))
                (when (buffer-live-p buf) (kill-buffer buf)))))
        (unless was-enabled (bookmark-gt-mode -1))))))

(ert-deftest bookmark-gt-jump-via-override-runs-after-jump-hook-after-throw ()
  "The override's throw must not skip `bookmark-after-jump-hook'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-set-non-file
     "bg-throw-hook"
     'bookmark-gt-core-tests--handler-that-opens-buffer nil)
    (let ((was-enabled bookmark-gt-mode)
          (ran nil))
      (unwind-protect
          (progn
            (unless was-enabled (bookmark-gt-mode 1))
            (add-hook 'bookmark-after-jump-hook
                      (lambda () (setq ran t)))
            (bookmark-jump "bg-throw-hook")
            (should ran))
        (let ((buf (get-buffer " *bg-target-test*")))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (unless was-enabled (bookmark-gt-mode -1))))))

;;;; Suggested name is independent of `bookmark-current-bookmark'

(ert-deftest bookmark-gt-test-set-ignores-current-bookmark-for-name ()
  "The suggested name comes from the location, not the last bookmark.
`bookmark-make-record' falls back to `bookmark-current-bookmark'
for the record name, which is buffer-local and holds whatever
was jumped to or stored in this buffer last."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((tmp (make-temp-file "bookmark-gt-name-" nil ".txt" "hello\n")))
      (unwind-protect
          (with-current-buffer (find-file-noselect tmp)
            (setq-local bookmark-current-bookmark "Some Browser Tab Title")
            (let ((stored (bookmark-gt-set nil)))
              (should (equal (car stored)
                             (file-name-nondirectory tmp))))
            (kill-buffer))
        (delete-file tmp)))))

(ert-deftest bookmark-gt-test-set-still-updates-current-bookmark ()
  "Storing the record sets `bookmark-current-bookmark' to the new name."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((tmp (make-temp-file "bookmark-gt-name-" nil ".txt" "hello\n")))
      (unwind-protect
          (with-current-buffer (find-file-noselect tmp)
            (setq-local bookmark-current-bookmark "stale")
            (bookmark-gt-set "fresh")
            (should (equal bookmark-current-bookmark "fresh"))
            (kill-buffer))
        (delete-file tmp)))))

(ert-deftest bookmark-gt-test-set-non-file-no-current-leaves-it-alone ()
  "NO-CURRENT keeps `bookmark-current-bookmark' unchanged."
  (bookmark-gt-test-with-clean-bookmarks
    (with-temp-buffer
      (setq-local bookmark-current-bookmark "untouched")
      (bookmark-gt-set-non-file "batch" 'ignore nil t t)
      (should (equal bookmark-current-bookmark "untouched"))
      (bookmark-gt-set-non-file "single" 'ignore nil)
      (should (equal bookmark-current-bookmark "single")))))

(ert-deftest bookmark-gt-test-set-prompt-offers-editable-name ()
  "The interactive prompt inserts the suggestion as initial input."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((tmp (make-temp-file "bookmark-gt-name-" nil ".txt" "hello\n"))
          (initial nil))
      (unwind-protect
          (with-current-buffer (find-file-noselect tmp)
            (cl-letf (((symbol-function 'read-from-minibuffer)
                       (lambda (_prompt &optional init &rest _)
                         (setq initial init)
                         "typed")))
              (bookmark-gt-set bookmark-gt--prompt-name))
            (should (equal initial (file-name-nondirectory tmp)))
            (should (assoc "typed" bookmark-alist))
            (kill-buffer))
        (delete-file tmp)))))

(provide 'bookmark-gt-core-tests)
;;; bookmark-gt-core-tests.el ends here
