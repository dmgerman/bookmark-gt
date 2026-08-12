;;; bookmark-gt-jump.el --- Jump reader (consult, marginalia, orderless)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Keywords: convenience, matching, hypermedia
;; URL: https://github.com/dmgerman/bookmark-gt
;; Version: 0.1.0

;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; `bookmark-gt-jump' — a jump reader that uses `consult--read' when
;; consult is loaded, falls back to vanilla `completing-read'
;; otherwise.  When marginalia is loaded, candidates get an
;; annotation column (tags, type, path).  When orderless is loaded,
;; the reader accepts two narrowing particles:
;;
;;   ,@TYPE   — narrow to bookmarks of TYPE (url, eww, file, ...).
;;   ;TAG     — narrow to bookmarks carrying TAG.
;;
;; Both dispatchers work only for the length of one reader call —
;; other consult / vertico invocations are unaffected.  Narrowing
;; charset is derived from `bookmark-gt-handler-alist' at read
;; time, so a user-registered handler type shows up automatically.
;;
;; The reader also supports a mid-read tag filter: `M-t' in the
;; minibuffer reads a tag and re-runs the read with the filter
;; active.  Multiple `M-t' calls compose; `M-d' pops the last
;; filter; abort clears them.
;;
;; See ai/design/registries.org for the handler-registry schema
;; this reader queries.

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'cl-lib)
(require 'bookmark-gt-core)
(require 'bookmark-gt-tags)
(require 'bookmark-gt-handlers)

;; Optional soft-deps.  Each is loaded if present; every use site
;; below guards with `featurep' / `fboundp' so bookmark-gt works
;; without them installed.
(require 'consult nil t)
(require 'marginalia nil t)
(require 'orderless nil t)

;; Compiler-visible declarations for the soft-dep functions we call.
;; `marginalia--fields' is a macro, so it is available to the byte-
;; compiler through the top-level (require 'marginalia nil t) above
;; whenever marginalia is installed; no declare-function is needed
;; (declare-function refuses to verify macros).
(declare-function consult--read "consult")
(declare-function consult--type-narrow "consult")
(declare-function consult--type-group "consult")

(defvar orderless-style-dispatchers)
(defvar marginalia-annotators)

;;;; Customization

(defcustom bookmark-gt-jump-name-max-width 40
  "Maximum width of the bookmark name in a jump candidate."
  :type 'integer
  :group 'bookmark-gt)

;;;; Narrow chars derived from the handler registry
;;
;; `bookmark-gt-handler-alist' is keyed by handler symbol, so many
;; entries share a `:type' (URL has three aliases, browser-tab has
;; three, etc.).  The narrow alist must dedupe by `:type' — otherwise
;; consult would show one narrow row per alias.

(defun bookmark-gt-jump--narrow-alist ()
  "Return (CHAR . NAME) alist for `consult--type-narrow' from the registry.
Dedupes by `:type' so alias handler symbols do not produce
duplicate narrow rows."
  (let ((seen (make-hash-table :test #'eq))
        result)
    (dolist (entry bookmark-gt-handler-alist)
      (let* ((plist (cdr entry))
             (type (plist-get plist :type)))
        (unless (gethash type seen)
          (puthash type t seen)
          (push (cons (plist-get plist :narrow-char)
                      (plist-get plist :name))
                result))))
    (nreverse result)))

(defun bookmark-gt-jump--type-char (record)
  "Return the narrow character for RECORD's type, or ?\\s if unknown."
  (or (plist-get (cdr (bookmark-gt-handler-classify record)) :narrow-char)
      ?\s))

;;;; Candidate construction

(defun bookmark-gt-jump--truncate-name (name)
  "Return NAME truncated to `bookmark-gt-jump-name-max-width'."
  (truncate-string-to-width name bookmark-gt-jump-name-max-width nil nil t))

(defun bookmark-gt-jump--tag-tokens (tags)
  "Return TAGS rendered as space-separated `;tag' tokens."
  (mapconcat (lambda (tag) (concat ";" tag)) tags " "))

(defun bookmark-gt-jump--type-token (record)
  "Return the `@TypeName' particle string for RECORD, or nil if unknown."
  (let ((name (bookmark-gt-handler-name record)))
    (and name (not (string= name "Unknown"))
         (concat "@" name))))

(defun bookmark-gt-jump--make-candidate (record)
  "Build a jump candidate string for RECORD.
The visible content is the bookmark name (truncated).  Text
properties carry:

  `bookmark-gt-name'      — the raw record name (for :lookup).
  `consult--type'         — the narrow char (for consult narrowing).
  `bookmark-gt-particles' — space-separated `@Type ;tag ;tag'
                             tokens matched by the orderless
                             dispatchers.  Stored as a property so
                             `string-width' does not count them
                             \(marginalia's alignment column would
                             otherwise be padded by every
                             candidate's hidden tokens)."
  (let* ((name (bookmark-gt-display-name (car record)))
         (visible (bookmark-gt-jump--truncate-name name))
         (tags (bookmark-gt-tags-of record))
         (type-token (bookmark-gt-jump--type-token record))
         (tag-tokens (and tags (bookmark-gt-jump--tag-tokens tags)))
         (particles (string-join (delq nil (list type-token tag-tokens))
                                 " ")))
    (propertize visible
                'bookmark-gt-name name
                'consult--type (bookmark-gt-jump--type-char record)
                'bookmark-gt-particles
                (and (not (string-empty-p particles)) particles))))

(defun bookmark-gt-jump--candidate-name (candidate)
  "Return the raw bookmark name stored on CANDIDATE, or CANDIDATE itself."
  (or (get-text-property 0 'bookmark-gt-name candidate)
      candidate))

;;;; Orderless dispatchers

(defun bookmark-gt-jump--particle-matcher (prefix-char component)
  "Return an orderless predicate matching the `bookmark-gt-particles' property.
Matches candidates whose particles string contains the
concatenation of PREFIX-CHAR and COMPONENT (case-adjusted).
Candidates without the property are dropped."
  (let* ((needle (concat (string prefix-char) component))
         (case-fold completion-ignore-case)
         (folded (if case-fold (downcase needle) needle)))
    (lambda (str)
      (when-let* ((particles (get-text-property 0 'bookmark-gt-particles str)))
        (string-search folded
                       (if case-fold (downcase particles) particles))))))

(defun bookmark-gt-jump-type-dispatch (component)
  "Orderless matcher for `@'-prefixed COMPONENT."
  (bookmark-gt-jump--particle-matcher ?@ component))

(defun bookmark-gt-jump-tag-dispatch (component)
  "Orderless matcher for `;'-prefixed COMPONENT."
  (bookmark-gt-jump--particle-matcher ?\; component))

(defun bookmark-gt-jump--orderless-dispatcher (component _index _total)
  "Style dispatcher for `bookmark-gt-jump'.
Routes `@'-prefixed COMPONENT to `bookmark-gt-jump-type-dispatch'
and `;'-prefixed COMPONENT to `bookmark-gt-jump-tag-dispatch'.
Returns nil for any other component so orderless falls through
to its default dispatchers and matching styles."
  (when (> (length component) 1)
    (pcase (aref component 0)
      (?@  (cons #'bookmark-gt-jump-type-dispatch (substring component 1)))
      (?\; (cons #'bookmark-gt-jump-tag-dispatch  (substring component 1))))))

;;;; Marginalia annotator

(defun bookmark-gt-jump--tags-column-width ()
  "Return the max width of any `;tag ;tag ...' segment in `bookmark-alist'."
  (apply #'max 0
         (mapcar (lambda (entry)
                   (let ((tags (bookmark-gt-tags-of entry)))
                     (if tags
                         (length (bookmark-gt-jump--tag-tokens tags))
                       0)))
                 bookmark-alist)))

(defun bookmark-gt-jump--type-column-width ()
  "Return the max width of any handler `:name' in `bookmark-gt-handler-alist'."
  (apply #'max 0
         (mapcar (lambda (entry) (length (plist-get (cdr entry) :name)))
                 bookmark-gt-handler-alist)))

(defun bookmark-gt-jump--record-path (record)
  "Return the display path for RECORD (filename, URL, or `location').
Uses the bookmark+-compat helpers so a placeholder filename or a
`location'-only URL both render correctly."
  (or (bookmark-gt-filename-of record)
      (bookmark-gt-url-of record)
      ""))

(defun bookmark-gt-jump-annotate (candidate)
  "Marginalia annotator for a bookmark CANDIDATE.
Returns a three-field annotation: tags, type, path.  Fields use
`marginalia--fields' so widths auto-align across candidates."
  (when (featurep 'marginalia)
    (when-let* ((name (bookmark-gt-jump--candidate-name candidate))
                (record (assoc name bookmark-alist)))
      (let* ((tags (bookmark-gt-tags-of record))
             (tag-seg (if tags (bookmark-gt-jump--tag-tokens tags) ""))
             (tag-w (bookmark-gt-jump--tags-column-width))
             (type (bookmark-gt-handler-name record))
             (type-w (bookmark-gt-jump--type-column-width))
             (filename (bookmark-gt-filename-of record))
             (path (bookmark-gt-jump--record-path record))
             (file-p (stringp filename)))
        (marginalia--fields
         (tag-seg :truncate tag-w              :face 'completions-annotations)
         (type    :truncate type-w             :face 'marginalia-type)
         (path    :truncate (if file-p -0.5 0.5) :face 'marginalia-file-name))))))

;;;; Marginalia install / uninstall

(defun bookmark-gt-jump--install-marginalia ()
  "Register `bookmark-gt-jump-annotate' as a bookmark-category annotator.
No-op when marginalia is not loaded.  Idempotent."
  (when (featurep 'marginalia)
    (let ((entry (assq 'bookmark marginalia-annotators)))
      (if entry
          (unless (memq 'bookmark-gt-jump-annotate entry)
            (setcdr entry (cons #'bookmark-gt-jump-annotate (cdr entry))))
        (push '(bookmark bookmark-gt-jump-annotate builtin none)
              marginalia-annotators)))))

(defun bookmark-gt-jump--uninstall-marginalia ()
  "Remove `bookmark-gt-jump-annotate' from the bookmark annotators.
When our entry was the only annotator in the list, drop the whole
`(bookmark ...)' form so marginalia falls back to its built-in
default.  No-op when marginalia is not loaded."
  (when (featurep 'marginalia)
    (let ((entry (assq 'bookmark marginalia-annotators)))
      (when entry
        (setcdr entry (delq 'bookmark-gt-jump-annotate (cdr entry)))
        (when (null (cdr entry))
          (setq marginalia-annotators
                (assq-delete-all 'bookmark marginalia-annotators)))))))

;;;; Mid-read tag filter machinery
;;
;; A jump call is one or more consult reads composed by a restart
;; loop.  Between reads the caller checks the closure-captured
;; `active-filters' state; if a filter command set the restart
;; flag, the next iteration includes the new filter in the
;; candidate list.  Filter commands throw a quit to abort the
;; current read cleanly.

(defvar bookmark-gt-jump--active-filters nil
  "During a jump read, list of active tag-filter strings.
Bound around the reader; outside a read, always nil.")

(defvar bookmark-gt-jump--restart-p nil
  "During a jump read, set non-nil by a filter command to restart the read.")

(defun bookmark-gt-jump-add-tag-filter ()
  "Add a tag filter to the ongoing `bookmark-gt-jump' read and restart it."
  (interactive)
  (let ((tag (completing-read "Tag filter: "
                              (bookmark-gt-tags-list) nil t)))
    (setq bookmark-gt-jump--active-filters
          (cons tag bookmark-gt-jump--active-filters)
          bookmark-gt-jump--restart-p t))
  (abort-recursive-edit))

(defun bookmark-gt-jump-pop-tag-filter ()
  "Remove the most recent tag filter from the ongoing read and restart."
  (interactive)
  (when bookmark-gt-jump--active-filters
    (setq bookmark-gt-jump--active-filters
          (cdr bookmark-gt-jump--active-filters)
          bookmark-gt-jump--restart-p t)
    (abort-recursive-edit)))

(defun bookmark-gt-jump-clear-tag-filters ()
  "Clear every active tag filter and restart the read."
  (interactive)
  (setq bookmark-gt-jump--active-filters nil
        bookmark-gt-jump--restart-p t)
  (abort-recursive-edit))

(defvar-keymap bookmark-gt-jump-minibuffer-map
  :doc "Additions to the minibuffer keymap during `bookmark-gt-jump'."
  "M-t" #'bookmark-gt-jump-add-tag-filter
  "M-d" #'bookmark-gt-jump-pop-tag-filter
  "M-D" #'bookmark-gt-jump-clear-tag-filters)

(defun bookmark-gt-jump--filter-alist (records)
  "Return RECORDS filtered by `bookmark-gt-jump--active-filters' (AND)."
  (seq-filter
   (lambda (record)
     (seq-every-p (lambda (tag) (bookmark-gt-has-tag-p record tag))
                  bookmark-gt-jump--active-filters))
   records))

(defun bookmark-gt-jump--prompt (base)
  "Return BASE decorated with any active filter chips."
  (if (null bookmark-gt-jump--active-filters)
      base
    (format "%s [%s]"
            base
            (mapconcat (lambda (tag) (concat ";" tag))
                       (reverse bookmark-gt-jump--active-filters) " "))))

;;;; Reader

(defun bookmark-gt-jump--read-with-consult (prompt candidates)
  "Read a CANDIDATES member via `consult--read' under PROMPT."
  (consult--read
   candidates
   :prompt (bookmark-gt-jump--prompt prompt)
   :require-match t
   :sort nil
   :history 'bookmark-history
   :category 'bookmark
   :annotate #'bookmark-gt-jump-annotate
   :narrow (consult--type-narrow (bookmark-gt-jump--narrow-alist))
   :keymap bookmark-gt-jump-minibuffer-map
   :lookup (lambda (selected cands &rest _)
             (bookmark-gt-jump--candidate-name
              (or (car (member selected cands)) selected)))))

(defun bookmark-gt-jump--read-plain (prompt candidates)
  "Read a CANDIDATES member via vanilla `completing-read' under PROMPT.
Used when consult is not loaded.  The `M-t' filter keys still
work because we let-bind `minibuffer-local-completion-map' via
`make-composed-keymap'."
  (let* ((completion-extra-properties
          (list :annotation-function
                (lambda (cand)
                  (or (bookmark-gt-jump-annotate cand) ""))))
         (map (make-composed-keymap
               bookmark-gt-jump-minibuffer-map
               minibuffer-local-completion-map))
         (minibuffer-local-completion-map map))
    (bookmark-gt-jump--candidate-name
     (completing-read (bookmark-gt-jump--prompt prompt)
                      candidates nil t nil 'bookmark-history))))

(defun bookmark-gt-jump--read-once (prompt)
  "One iteration of the jump reader under PROMPT.
Returns the selected bookmark name or throws `quit' on abort."
  (let* ((records (bookmark-gt-jump--filter-alist bookmark-alist))
         (candidates (mapcar #'bookmark-gt-jump--make-candidate records))
         ;; Scope the orderless dispatcher to this read only.
         (orderless-style-dispatchers
          (if (and (featurep 'orderless)
                   (boundp 'orderless-style-dispatchers))
              (cons #'bookmark-gt-jump--orderless-dispatcher
                    orderless-style-dispatchers)
            (and (boundp 'orderless-style-dispatchers)
                 orderless-style-dispatchers))))
    (if (featurep 'consult)
        (bookmark-gt-jump--read-with-consult prompt candidates)
      (bookmark-gt-jump--read-plain prompt candidates))))

(defun bookmark-gt-jump--read (prompt)
  "Read a bookmark name under PROMPT, running the tag-filter restart loop.
Fires `bookmark-gt-ephemeral-refresh-hook' once at the top so
sources with transient records (browser tabs, auto-update
targets) rebuild before the reader shows them."
  (bookmark-gt-refresh-ephemeral)
  (let (result)
    (while (null result)
      (setq bookmark-gt-jump--restart-p nil)
      (condition-case nil
          (setq result (bookmark-gt-jump--read-once prompt))
        (quit
         (unless bookmark-gt-jump--restart-p
           (signal 'quit nil)))))
    result))

;;;###autoload
(defun bookmark-gt-jump ()
  "Jump to a bookmark chosen from the completion reader.
Narrowing particles in the minibuffer:

  `,@TYPE'   — narrow to bookmarks of TYPE (from
              `bookmark-gt-handler-alist').
  `;TAG'     — narrow to bookmarks carrying TAG.

Minibuffer keys:

  `M-t'      — add a tag filter to the read (restarts).
  `M-d'      — pop the most recent tag filter.
  `M-D'      — clear every active tag filter."
  (interactive)
  (bookmark-maybe-load-default-file)
  (let ((bookmark-gt-jump--active-filters nil)
        (bookmark-gt-jump--restart-p nil))
    (let ((name (bookmark-gt-jump--read "Jump to bookmark")))
      (bookmark-jump name))))

;;;###autoload
(defun bookmark-gt-jump-other-window ()
  "Like `bookmark-gt-jump' but display in another window."
  (interactive)
  (bookmark-maybe-load-default-file)
  (let ((bookmark-gt-jump--active-filters nil)
        (bookmark-gt-jump--restart-p nil))
    (let ((name (bookmark-gt-jump--read "Jump (other window)")))
      (bookmark-jump-other-window name))))

;;;###autoload
(defun bookmark-gt-jump-tagged (tag)
  "Jump to a bookmark, prefiltered by TAG."
  (interactive (list (completing-read "Tag: "
                                      (bookmark-gt-tags-list) nil t)))
  (bookmark-maybe-load-default-file)
  (let ((bookmark-gt-jump--active-filters (list tag))
        (bookmark-gt-jump--restart-p nil))
    (let ((name (bookmark-gt-jump--read (format "Jump [;%s]" tag))))
      (bookmark-jump name))))

;;;; Install / uninstall (called from `bookmark-gt-mode')

;;;###autoload
(defun bookmark-gt-jump-enable ()
  "Install the marginalia annotator for bookmark completion.
Orderless dispatcher is installed per-read via let-binding, so
there is nothing to enable globally for it.  Idempotent."
  (bookmark-gt-jump--install-marginalia))

;;;###autoload
(defun bookmark-gt-jump-disable ()
  "Remove the marginalia annotator for bookmark completion."
  (bookmark-gt-jump--uninstall-marginalia))

(provide 'bookmark-gt-jump)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-jump.el ends here
