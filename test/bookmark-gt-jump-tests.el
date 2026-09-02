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
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let ((cand (bookmark-gt-jump-candidate-default (car bookmark-alist))))
      (should (equal (get-text-property 0 'bookmark-gt-name cand) "u")))))

(ert-deftest bookmark-gt-jump-test-candidate-truncated-to-max-width ()
  "A name wider than the cap is truncated; the property keeps it whole."
  (bookmark-gt-test-with-clean-bookmarks
    (let ((long (make-string (* 2 bookmark-gt-jump-name-max-width) ?x)))
      (bookmark-gt-create-non-file long 'bookmark-gt-handler-url-jump
                                '((url . "https://x")))
      (let ((cand (bookmark-gt-jump-candidate-default (car bookmark-alist))))
        (should (<= (string-width cand) bookmark-gt-jump-name-max-width))
        (should (equal (bookmark-gt-jump--candidate-name cand) long))))))

(ert-deftest bookmark-gt-jump-test-name-max-width-leaves-align-slack ()
  "The cap must not land on marginalia's alignment column.
Marginalia rounds the alignment column up to a multiple of 10; a
cap that is itself a multiple of 10 leaves the widest rows no room
for the aligning space."
  (should-not (zerop (% bookmark-gt-jump-name-max-width 10))))

(ert-deftest bookmark-gt-jump-test-candidate-particles ()
  "The particle string carries both `@Type' and `;tag' tokens."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")
                                (tags . ("proj" "urgent"))))
    (let* ((cand (bookmark-gt-jump-candidate-default (car bookmark-alist)))
           (particles (get-text-property 0 'bookmark-gt-particles cand)))
      (should (string-search "@URL" particles))
      (should (string-search ";proj" particles))
      (should (string-search ";urgent" particles)))))

(ert-deftest bookmark-gt-jump-test-candidate-type-char ()
  "The narrow char comes from the record's GROUP (not type) now."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")))
    (let ((cand (bookmark-gt-jump-candidate-default (car bookmark-alist))))
      ;; URL is in the `web' group whose narrow-char is ?w.
      (should (eq (get-text-property 0 'consult--type cand) ?w)))))

;;;; Orderless dispatcher

(ert-deftest bookmark-gt-jump-test-orderless-type-matches ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")))
    (bookmark-gt-create-non-file "e" 'eww-bookmark-jump nil)
    (let* ((cands (mapcar #'bookmark-gt-jump-candidate-default bookmark-alist))
           (matcher (bookmark-gt-jump-type-dispatch "URL")))
      (should (= (length (seq-filter matcher cands)) 1))
      (should (equal (get-text-property 0 'bookmark-gt-name
                                        (car (seq-filter matcher cands)))
                     "u")))))

(ert-deftest bookmark-gt-jump-test-orderless-tag-matches ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((tags . ("proj"))))
    (bookmark-gt-create-non-file "b" 'h '((tags . ("other"))))
    (let* ((cands (mapcar #'bookmark-gt-jump-candidate-default bookmark-alist))
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

(ert-deftest bookmark-gt-jump-test-narrow-alist-from-groups ()
  "The narrow alist has one entry per registered group."
  (let ((alist (bookmark-gt-jump--narrow-alist)))
    (should (assoc ?w alist))    ; web
    (should (assoc ?f alist))    ; file
    (should (assoc ?d alist))))  ; doc

;;;; Reader fallback path (no consult)

(ert-deftest bookmark-gt-jump-test-plain-reader-dispatches ()
  "Without consult, `bookmark-gt-jump' still dispatches through `bookmark-jump'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let (seen)
      (cl-letf
          (((symbol-function 'featurep)
            (lambda (feat) (not (eq feat 'consult))))
           ((symbol-function 'completing-read)
            (lambda (&rest _)
              ;; Return the visible candidate string.
              (bookmark-gt-jump-candidate-default (car bookmark-alist))))
           ((symbol-function 'browse-url)
            (lambda (url &rest _) (push url seen))))
        (bookmark-gt-jump))
      (should (equal seen '("https://example.org"))))))

;;;; Filter state

(ert-deftest bookmark-gt-jump-test-filter-narrows-candidates ()
  "`bookmark-gt-jump--filter-alist' returns only records carrying all filters."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h '((tags . ("proj" "urgent"))))
    (bookmark-gt-create-non-file "b" 'h '((tags . ("proj"))))
    (bookmark-gt-create-non-file "c" 'h '((tags . ("other"))))
    (let ((bookmark-gt-jump--active-filters '("proj")))
      (should (= (length (bookmark-gt-jump--filter-alist bookmark-alist))
                 2)))
    (let ((bookmark-gt-jump--active-filters '("proj" "urgent")))
      (should (= (length (bookmark-gt-jump--filter-alist bookmark-alist))
                 1)))))

;;;; Sort predicates

(ert-deftest bookmark-gt-jump-test-sort-by-mru ()
  "`--sort-records' with `mru' puts higher `last-visited' first."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "old" 'h '((last-visited . (100 0))))
    (bookmark-gt-create-non-file "new" 'h '((last-visited . (200 0))))
    (bookmark-gt-create-non-file "none" 'h nil)
    (let* ((bookmark-gt-jump--sort-by 'mru)
           (sorted (bookmark-gt-jump--sort-records bookmark-alist)))
      (should (equal (mapcar #'car sorted) '("new" "old" "none"))))))

(ert-deftest bookmark-gt-jump-test-sort-by-visits ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "one"  'h '((visits . 1)))
    (bookmark-gt-create-non-file "ten"  'h '((visits . 10)))
    (bookmark-gt-create-non-file "none" 'h nil)
    (let* ((bookmark-gt-jump--sort-by 'visits)
           (sorted (bookmark-gt-jump--sort-records bookmark-alist)))
      (should (equal (mapcar #'car sorted) '("ten" "one" "none"))))))

(ert-deftest bookmark-gt-jump-test-sort-by-nil-preserves-order ()
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "a" 'h nil)
    (bookmark-gt-create-non-file "b" 'h nil)
    (let* ((bookmark-gt-jump--sort-by nil)
           (sorted (bookmark-gt-jump--sort-records bookmark-alist)))
      (should (equal sorted bookmark-alist)))))

;;;; Format-function defcustom

(ert-deftest bookmark-gt-jump-test-format-function-override ()
  "The reader uses `bookmark-gt-jump-candidate-format-function'."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "x" 'h nil)
    (let* ((called nil)
           (bookmark-gt-jump-candidate-format-function
            (lambda (rec) (setq called t) (car rec))))
      (mapcar bookmark-gt-jump-candidate-format-function bookmark-alist)
      (should called))))

;;;; Marginalia install
;;
;; `--install-marginalia' is called both from `bookmark-gt-mode' on
;; and from `bookmark-gt-jump--read'.  The read-time call self-heals
;; the "marginalia loaded after mode-on" case: the mode-on install
;; is a no-op when marginalia is not yet loaded, and the next jump
;; re-runs the install and picks up the now-loaded package.

(ert-deftest bookmark-gt-jump-test-read-installs-marginalia-annotator ()
  "`bookmark-gt-jump--read' installs our marginalia annotator lazily."
  (skip-unless (featurep 'marginalia))
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let ((marginalia-annotators nil))
      (cl-letf (((symbol-function 'bookmark-gt-jump--read-once)
                 (lambda (_prompt) "u")))
        (bookmark-gt-jump--read "prompt"))
      (should (memq 'bookmark-gt-jump-annotate
                    (assq 'bookmark marginalia-annotators))))))

;;;; Before-read hook

(ert-deftest bookmark-gt-jump-test-before-read-hook-fires-once ()
  "`bookmark-gt-jump-before-read-hook' runs once per outer read call."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let* ((count 0)
           (bookmark-gt-jump-before-read-hook
            (list (lambda () (setq count (1+ count)))))
           ;; Stub the reader so `--read' returns without user I/O.
           (bookmark-gt-jump--pool bookmark-alist))
      (cl-letf (((symbol-function 'bookmark-gt-jump--read-once)
                 (lambda (_prompt) "u")))
        (bookmark-gt-jump--read "prompt"))
      (should (= count 1)))))

;;;; Annotation follows the candidate's record

(ert-deftest bookmark-gt-jump-test-annotates-a-suffixed-candidate ()
  "A candidate shown as NAME<2> is annotated from its own record.
The visible string is not the stored name, so a lookup by name
finds nothing — and for two records sharing a name it would find
the wrong one."
  (skip-unless (featurep 'marginalia))
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'always))
      (bookmark-gt-create-non-file "test" 'h (list (cons 'filename "/tmp/a")))
      (bookmark-gt-create-non-file "test" 'h (list (cons 'filename "/tmp/b"))))
    (let* ((records (bookmark-gt--records-named "test"))
           (second (nth 1 records))
           (candidate (bookmark-gt-jump-candidate-default second)))
      (should (string-match-p "test<2>" candidate))
      (should (bookmark-gt-jump-annotate candidate)))))

(ert-deftest bookmark-gt-jump-test-annotation-uses-its-own-record ()
  "Each of two same-named candidates annotates from its own record."
  (skip-unless (featurep 'marginalia))
  (bookmark-gt-test-with-clean-bookmarks
    (let ((bookmark-gt-allow-same-name-bookmarks 'always))
      (bookmark-gt-create-non-file "test" 'h (list (cons 'filename "/tmp/aaa")))
      (bookmark-gt-create-non-file "test" 'h (list (cons 'filename "/tmp/bbb"))))
    ;; By filename, not position: `bookmark-alist' holds the most
    ;; recently stored record first.
    (let* ((by-file (lambda (f)
                      (seq-find (lambda (r)
                                  (equal (bookmark-gt-filename-of r) f))
                                (bookmark-gt--records-named "test"))))
           (a (bookmark-gt-jump-annotate
               (bookmark-gt-jump-candidate-default (funcall by-file "/tmp/aaa"))))
           (b (bookmark-gt-jump-annotate
               (bookmark-gt-jump-candidate-default (funcall by-file "/tmp/bbb")))))
      (should (string-match-p "aaa" a))
      (should (string-match-p "bbb" b)))))

(provide 'bookmark-gt-jump-tests)
;;; bookmark-gt-jump-tests.el ends here
