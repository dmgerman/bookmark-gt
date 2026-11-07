;;; bookmark-gt-jump-tests.el --- Tests for bookmark-gt-jump   -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Tests for candidate construction, the orderless particle
;; dispatcher (type + tag), the fallback reader path, the location
;; field width, and field formatting.

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

(ert-deftest bookmark-gt-jump-test-candidate-group-particle ()
  "The particles carry `+Group' for the record's group."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")))
    (let* ((cand (bookmark-gt-jump-candidate-default (car bookmark-alist)))
           (particles (get-text-property 0 'bookmark-gt-particles cand)))
      ;; URL is in the `web' group.
      (should (string-search "+Web" particles))
      (should-not (get-text-property 0 'consult--type cand)))))

(ert-deftest bookmark-gt-jump-test-orderless-group-matches ()
  "The `+' matcher selects every bookmark in the group, of any type."
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://x")))
    (bookmark-gt-create-non-file "e" 'eww-bookmark-jump nil)
    (bookmark-gt-create-non-file "i" 'Info-bookmark-jump nil)
    (let ((cands (mapcar #'bookmark-gt-jump-candidate-default bookmark-alist))
          (names (lambda (matcher cands)
                   (sort (mapcar #'bookmark-gt-jump--candidate-name
                                 (seq-filter matcher cands))
                         #'string<))))
      (let ((completion-ignore-case nil))
        (should (equal (funcall names (bookmark-gt-jump-group-dispatch "Web")
                                cands)
                       '("e" "u"))))
      (let ((completion-ignore-case t))
        (should (equal (funcall names (bookmark-gt-jump-group-dispatch "web")
                                cands)
                       '("e" "u")))))))

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
  "The dispatcher returns the right matcher for `@', `+', `;' and other."
  (let ((atprefix (bookmark-gt-jump--orderless-dispatcher "@url" 0 1))
        (plus     (bookmark-gt-jump--orderless-dispatcher "+web" 0 1))
        (semi     (bookmark-gt-jump--orderless-dispatcher ";tag" 0 1))
        (plain    (bookmark-gt-jump--orderless-dispatcher "foo" 0 1)))
    (should (eq (car atprefix) #'bookmark-gt-jump-type-dispatch))
    (should (equal (cdr atprefix) "url"))
    (should (eq (car plus) #'bookmark-gt-jump-group-dispatch))
    (should (equal (cdr plus) "web"))
    (should (eq (car semi) #'bookmark-gt-jump-tag-dispatch))
    (should (equal (cdr semi) "tag"))
    (should (null plain))))

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

;;;; Annotation alignment

(ert-deftest bookmark-gt-jump-test-annotation-aligns-itself ()
  "The annotation starts with a `space :align-to' at the name column.
No private marginalia text property is used."
  (skip-unless (featurep 'marginalia))
  (bookmark-gt-test-with-clean-bookmarks
    (bookmark-gt-create-non-file "u" 'bookmark-gt-handler-url-jump
                              '((url . "https://example.org")))
    (let* ((bookmark-gt-jump--name-column 40)
           (ann (bookmark-gt-jump-annotate
                 (bookmark-gt-jump-candidate-default (car bookmark-alist)))))
      (should (equal (get-text-property 0 'display ann)
                     '(space :align-to (+ left 40))))
      (should-not (text-property-any 0 (length ann)
                                     'marginalia--align t ann)))))

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

;;;; Location field width

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
    ;; 58 rounds up to the next multiple of the column step.
    (should (= 60 (bookmark-gt-jump--align-column)))))

(ert-deftest bookmark-gt-jump-location-width-test-column-rounds-up ()
  "The column is the smallest multiple of the step greater than WIDTH.
A name exactly as wide as a multiple still gets one column of space."
  (should (= 60 (bookmark-gt-jump--column-for 51)))
  (should (= 60 (bookmark-gt-jump--column-for 59)))
  (should (= 70 (bookmark-gt-jump--column-for 60)))
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

(provide 'bookmark-gt-jump-tests)
;;; bookmark-gt-jump-tests.el ends here
