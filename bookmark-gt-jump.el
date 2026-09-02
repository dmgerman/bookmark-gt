;;; bookmark-gt-jump.el --- Jump reader (consult, marginalia, orderless)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Keywords: convenience, matching, hypermedia
;; URL: https://github.com/dmgerman/bookmark-gt

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
;; consult is loaded, falls back to built-in `completing-read'
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

(defcustom bookmark-gt-jump-name-max-width 58
  "Width at which the jump reader truncates a bookmark name.
Caps the candidate column so that a long name does not push the
marginalia annotation columns off the right edge of the window.
This matters most for names bookmark-gt does not choose itself —
browser tabs stored by `bookmark-gt-browser-tabs-mode' carry the
page title, which is often long enough to fill the window on its
own.

Marginalia places its annotation at the width of the widest
candidate rounded up to a multiple of 10.  A value that is itself
a multiple of 10 therefore leaves the widest rows no room for the
aligning space, and those rows render one column right of the
others.  Pick a value that is not a multiple of 10."
  :type 'integer
  :group 'bookmark-gt)

(defcustom bookmark-gt-jump-default-sort 'mru
  "Default sort order for `bookmark-gt-jump' and its variants.
Consulted when the entry point's `:SORT-BY' keyword is not
supplied.  Valid values match `bookmark-gt-jump--sort-records':

  `mru'     Sort by `last-visited' descending — recently
            visited records appear first.
  `visits'  Sort by `visits' descending.
  nil       Leave the candidate pool in its original order."
  :type '(choice (const :tag "Most recently used" mru)
                 (const :tag "Most visited"       visits)
                 (const :tag "Pool order"         nil))
  :group 'bookmark-gt)

(defvar bookmark-gt-jump-before-read-hook nil
  "Hook run once inside the jump readers before the reader displays.
Runs at the top of `bookmark-gt-jump', `bookmark-gt-jump-other-window',
and `bookmark-gt-jump-tagged', immediately before the candidate pool
is computed — but only when the entry point is going to prompt the
user (i.e. `:BOOKMARK' was not supplied).  Not run again on tag-filter
restart within a single call.

Called with no arguments.  Contributors typically refresh a pool
that grows stale between reads.  `bookmark-gt-browser-tabs-mode'
registers `bookmark-gt-browser-tabs-refresh' here so live browser
tabs are current whenever the jump reader opens.  Third parties
may add their own refreshers (auto-update sweep, remote-tab
poll, etc.) — each is called synchronously in the order added.")

(defcustom bookmark-gt-jump-candidate-format-function
  #'bookmark-gt-jump-candidate-default
  "Function that builds one `consult--read' candidate string for the jump reader.

Called with one argument, the bookmark RECORD (a `(NAME . DATA)'
cons from `bookmark-alist').  Must return a propertized string
whose text properties carry:

  `bookmark-gt-name'       — the bare bookmark name (string).
  `consult--type'          — the narrow char (fixnum).
  `bookmark-gt-particles'  — optional space-separated
                             `@Type ;tag ;tag' tokens for the
                             orderless particle dispatcher.

Customize this to control the visible row layout (e.g. add
DOMAIN / KIND / TITLE columns).  See
`bookmark-gt-jump-candidate-default' for the default
implementation and the token contract."
  :type 'function
  :group 'bookmark-gt)

;;;; Narrow chars derived from the handler registry
;;
;; `bookmark-gt-handler-alist' is keyed by handler symbol, so many
;; entries share a `:type' (URL has three aliases, browser-tab has
;; three, etc.).  The narrow alist must dedupe by `:type' — otherwise
;; consult would show one narrow row per alias.

(defun bookmark-gt-jump--narrow-alist ()
  "Return (CHAR . NAME) alist for `consult--type-narrow' by GROUP.
Now driven by `bookmark-gt-group-alist' rather than the handler
registry — narrowing at the group level (web / file / doc /
code / media / other) is coarser and matches how users think
about categories.  Per-type filtering is still available via the
orderless `,@Type' particle."
  (mapcar (lambda (entry)
            (cons (plist-get (cdr entry) :narrow-char)
                  (plist-get (cdr entry) :name)))
          bookmark-gt-group-alist))

(defun bookmark-gt-jump--type-char (record)
  "Return the narrow character for RECORD's group, or ?\\s if unknown.
Consult's narrow menu operates at the group level, so each
candidate's `consult--type' property is the GROUP's narrow
char rather than the type's."
  (bookmark-gt-group-narrow-char (bookmark-gt-handler-group record)))

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

(defun bookmark-gt-jump-candidate-default (record)
  "Default candidate formatter for RECORD in `bookmark-gt-jump'.
Returns a propertized string with:
  `bookmark-gt-name'      — the raw record name.
  `consult--type'         — the narrow char.
  `bookmark-gt-particles' — the `@Type ;tag' tokens for the
                             orderless dispatcher."
  (let* ((name (bookmark-gt-display-name-of record))
         (visible (bookmark-gt-jump--truncate-name name))
         (tags (bookmark-gt-tags-of record))
         (type-token (bookmark-gt-jump--type-token record))
         (tag-tokens (and tags (bookmark-gt-jump--tag-tokens tags)))
         (particles (string-join (delq nil (list type-token tag-tokens))
                                 " ")))
    (propertize visible
                'bookmark-gt-name name
                'bookmark-gt-record record
                'consult--type (bookmark-gt-jump--type-char record)
                'bookmark-gt-particles
                (and (not (string-empty-p particles)) particles))))

(defun bookmark-gt-jump--candidate-name (candidate)
  "Return the raw bookmark name stored on CANDIDATE, or CANDIDATE itself."
  (or (get-text-property 0 'bookmark-gt-name candidate)
      candidate))

(defun bookmark-gt-jump--candidate-record (candidate records)
  "Return the record CANDIDATE stands for, from RECORDS.
Prefers the `bookmark-gt-record' text property, which survives
the consult path.  Text properties do not survive every
`completing-read' return value, so falls back to matching
CANDIDATE's name against RECORDS.

The fallback resolves to the first record of that name when
several share one; making candidate strings unique is what
removes that residual ambiguity."
  (or (get-text-property 0 'bookmark-gt-record candidate)
      (let ((name (bookmark-gt-jump--candidate-name candidate)))
        (seq-find (lambda (r)
                    (equal (substring-no-properties
                            (bookmark-name-from-full-record r))
                           (substring-no-properties name)))
                  records))))

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
No-op when marginalia is not loaded.  Idempotent, so it is safe to
call from every jump read as well as from `bookmark-gt-mode' on."
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
             ;; Return the candidate itself, not its name: the
             ;; record is stored in its text properties.
             (or (car (member selected cands)) selected))))

(defun bookmark-gt-jump--read-plain (prompt candidates)
  "Read a CANDIDATES member via built-in `completing-read' under PROMPT.
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
    (completing-read (bookmark-gt-jump--prompt prompt)
                     candidates nil t nil 'bookmark-history)))

(defvar bookmark-gt-jump--pool nil
  "Dynamic override for the candidate pool during `bookmark-gt-jump--read'.
When non-nil, `--read-once' iterates this alist instead of the
full `bookmark-alist'.  Bound by the entry points so the elisp
caller can restrict what the reader sees via
`:bookmarks-list' / `:bookmarks-filter'.")

(defvar bookmark-gt-jump--sort-by nil
  "Dynamic sort order during `bookmark-gt-jump--read'.
Values: `mru' (by `last-visited' descending), `visits' (by
`visits' descending), or nil (leave records in the pool's
order).  Bound by the entry points via the `:sort-by' keyword.")

(defvar bookmark-gt-jump--preselect nil
  "Dynamic preselect index during `bookmark-gt-jump--read'.
When a positive integer, the reader positions the cursor on the
N-th candidate by installing a one-shot `minibuffer-setup-hook'
that calls `vertico-next' N times after a small delay.  No-op
when vertico is not loaded or when the pool has fewer candidates
than the requested index.  Bound by the entry points via the
`:preselect' keyword.")

(defun bookmark-gt-jump--sort-records (records)
  "Return RECORDS sorted per `bookmark-gt-jump--sort-by'.
The original list is not mutated."
  (pcase bookmark-gt-jump--sort-by
    ('mru
     (sort (copy-sequence records)
           (lambda (a b)
             (time-less-p
              (or (bookmark-prop-get b 'last-visited) '(0 0))
              (or (bookmark-prop-get a 'last-visited) '(0 0))))))
    ('visits
     (sort (copy-sequence records)
           (lambda (a b)
             (> (or (bookmark-prop-get a 'visits) 0)
                (or (bookmark-prop-get b 'visits) 0)))))
    (_ records)))

(declare-function vertico-next "ext:vertico")
(declare-function vertico--exhibit "ext:vertico")

(defun bookmark-gt-jump--preselect-advance ()
  "Advance vertico's cursor `bookmark-gt-jump--preselect' rows down.
Called from a small-delay timer inside the minibuffer.  No-op when
vertico is not loaded — completion frameworks other than vertico
have no equivalent primitive we can call from here."
  (let ((n bookmark-gt-jump--preselect))
    (when (and (integerp n) (> n 0)
               (fboundp 'vertico-next)
               (active-minibuffer-window))
      (with-selected-window (active-minibuffer-window)
        (ignore-errors
          (dotimes (_ n) (vertico-next))
          (when (fboundp 'vertico--exhibit)
            (vertico--exhibit)))))))

(defun bookmark-gt-jump--preselect-arm ()
  "Install a one-shot `minibuffer-setup-hook' that advances by preselect."
  (let ((setup-fn nil))
    (setq setup-fn
          (lambda ()
            (remove-hook 'minibuffer-setup-hook setup-fn)
            (run-at-time 0 nil #'bookmark-gt-jump--preselect-advance)))
    (add-hook 'minibuffer-setup-hook setup-fn t)))

(defun bookmark-gt-jump--read-once (prompt)
  "One iteration of the jump reader under PROMPT.
Returns the selected bookmark record, or throws `quit' on abort.
Consults `bookmark-gt-jump--pool' when non-nil, otherwise
scans `bookmark-alist'."
  (let* ((source (or bookmark-gt-jump--pool bookmark-alist))
         (records (bookmark-gt-jump--filter-alist source))
         (records (bookmark-gt-jump--sort-records records))
         (candidates (bookmark-gt-with-name-index
                       (mapcar bookmark-gt-jump-candidate-format-function
                               records)))
         ;; Scope the orderless dispatcher to this read only.
         (orderless-style-dispatchers
          (if (and (featurep 'orderless)
                   (boundp 'orderless-style-dispatchers))
              (cons #'bookmark-gt-jump--orderless-dispatcher
                    orderless-style-dispatchers)
            (and (boundp 'orderless-style-dispatchers)
                 orderless-style-dispatchers))))
    (bookmark-gt-jump--candidate-record
     (if (featurep 'consult)
         (bookmark-gt-jump--read-with-consult prompt candidates)
       (bookmark-gt-jump--read-plain prompt candidates))
     records)))

(defun bookmark-gt-jump--read (prompt)
  "Read a bookmark record under PROMPT, running the tag-filter restart loop.
Runs `bookmark-gt-jump-before-read-hook' exactly once, before the
first reader iteration, so pool-refresh contributors fire per jump
rather than per tag-filter restart.  Also re-runs
`bookmark-gt-jump--install-marginalia' at the top so a marginalia
that loaded after `bookmark-gt-mode' still gets our annotator —
the mode-on install is a no-op in that case."
  (bookmark-gt-jump--install-marginalia)
  (bookmark-gt-enforce-same-name-policy)
  (bookmark-gt-ensure-ids)
  (run-hooks 'bookmark-gt-jump-before-read-hook)
  (let (result)
    (while (null result)
      (setq bookmark-gt-jump--restart-p nil)
      (condition-case nil
          (setq result (bookmark-gt-jump--read-once prompt))
        (quit
         (unless bookmark-gt-jump--restart-p
           (signal 'quit nil)))))
    result))

(defun bookmark-gt-jump--resolve-pool (bookmarks-list bookmarks-filter group)
  "Return the candidate pool, or nil when nothing narrows it.
BOOKMARKS-LIST defaults to `bookmark-alist'; BOOKMARKS-FILTER
and GROUP compose as an AND when both are supplied."
  (let* ((list (or bookmarks-list bookmark-alist))
         (predicate
          (cond
           ((and bookmarks-filter group)
            (lambda (r)
              (and (funcall bookmarks-filter r)
                   (eq (bookmark-gt-handler-group r) group))))
           (bookmarks-filter bookmarks-filter)
           (group (lambda (r) (eq (bookmark-gt-handler-group r) group)))
           (t nil))))
    (cond
     (predicate      (seq-filter predicate list))
     (bookmarks-list list)
     (t              nil))))

(defmacro bookmark-gt-jump--with-read-state
    (pool sort-by preselect &rest body)
  "Bind the jump reader's dynamic state around BODY.
POOL, SORT-BY, and PRESELECT are let-bound into the respective
`bookmark-gt-jump--pool' / `--sort-by' / `--preselect' dynamic
variables so the reader picks them up.  Also arms the preselect
minibuffer-setup hook when PRESELECT is a positive integer."
  (declare (indent 3) (debug t))
  `(let ((bookmark-gt-jump--pool ,pool)
         (bookmark-gt-jump--sort-by ,sort-by)
         (bookmark-gt-jump--preselect ,preselect)
         (bookmark-gt-jump--active-filters nil)
         (bookmark-gt-jump--restart-p nil))
     (when (and (integerp bookmark-gt-jump--preselect)
                (> bookmark-gt-jump--preselect 0))
       (bookmark-gt-jump--preselect-arm))
     ,@body))

;;;###autoload
(cl-defun bookmark-gt-jump
    (&key bookmark display-function bookmarks-list bookmarks-filter
          group (sort-by bookmark-gt-jump-default-sort) preselect)
  "Jump to BOOKMARK, reading via consult (or `completing-read') when nil.

All arguments are keyword.  Interactively, none are supplied —
the reader prompts for the bookmark.

- :BOOKMARK — bookmark name or record.  When nil, prompt.
- :DISPLAY-FUNCTION — passed to `bookmark-jump' as its optional
  DISPLAY-FUNC (a fn of one argument, a buffer).  Defaults to
  the built-in same-window handler.
- :BOOKMARKS-LIST — alist in the shape of `bookmark-alist' to
  use as the candidate pool.  Defaults to `bookmark-alist'.
  Ignored when :BOOKMARK is supplied.
- :BOOKMARKS-FILTER — predicate on a record; a candidate is kept
  when the predicate returns non-nil.  Ignored when :BOOKMARK
  is supplied.
- :GROUP — group symbol from `bookmark-gt-group-alist' (e.g.
  `web', `file', `doc').  Only records whose
  `bookmark-gt-handler-group' matches survive.  Composes AND
  with :BOOKMARKS-FILTER when both are supplied.  Ignored when
  :BOOKMARK is supplied.
- :SORT-BY — sort order for the candidate pool.  `mru' sorts by
  the record's `last-visited' prop descending; `visits' sorts by
  the `visits' prop descending; nil leaves the pool's original
  order.  Defaults to `bookmark-gt-jump-default-sort' (\\='mru
  out of the box).
- :PRESELECT — positive integer.  When set (and vertico is
  loaded), the reader positions the cursor on the N-th candidate
  via a one-shot `minibuffer-setup-hook'.

Narrowing particles in the minibuffer (requires `orderless'):
  `,@TYPE'   — narrow to bookmarks of TYPE.
  `;TAG'     — narrow to bookmarks carrying TAG.

Minibuffer keys:
  `M-t'  add a tag filter (restart).
  `M-d'  pop the most recent tag filter.
  `M-D'  clear every active tag filter."
  (interactive)
  (bookmark-maybe-load-default-file)
  (let* ((pool (bookmark-gt-jump--resolve-pool bookmarks-list
                                               bookmarks-filter
                                               group))
         (record (bookmark-gt--resolve
                  (or bookmark
                      (bookmark-gt-jump--with-read-state pool sort-by preselect
                        (bookmark-gt-jump--read "Jump to bookmark: ")))
                  "Jump to bookmark")))
    (bookmark-gt-jump-record record display-function)))

;;;###autoload
(cl-defun bookmark-gt-jump-other-window
    (&key bookmark bookmarks-list bookmarks-filter group
          (sort-by bookmark-gt-jump-default-sort) preselect)
  "Like `bookmark-gt-jump' but display in another window.
:BOOKMARK, :BOOKMARKS-LIST, :BOOKMARKS-FILTER, :GROUP,
:SORT-BY, and :PRESELECT have the same meaning as in
`bookmark-gt-jump'.  :DISPLAY-FUNCTION is not accepted here —
the display function is fixed to another window."
  (interactive)
  (bookmark-maybe-load-default-file)
  (let* ((pool (bookmark-gt-jump--resolve-pool bookmarks-list
                                               bookmarks-filter
                                               group))
         (record (bookmark-gt--resolve
                  (or bookmark
                      (bookmark-gt-jump--with-read-state pool sort-by preselect
                        (bookmark-gt-jump--read "Jump (other window)")))
                  "Jump (other window)")))
    (bookmark-gt-jump-record record #'switch-to-buffer-other-window)))

;;;###autoload
(cl-defun bookmark-gt-jump-tagged
    (&key tag bookmark bookmarks-list bookmarks-filter group
          (sort-by bookmark-gt-jump-default-sort) preselect)
  "Jump to a bookmark, prefiltered by TAG.
:TAG (required, a string) seeds the reader's active tag filter.
:BOOKMARK, :BOOKMARKS-LIST, :BOOKMARKS-FILTER, :GROUP,
:SORT-BY, and :PRESELECT have the same meaning as in
`bookmark-gt-jump'.

Interactively, :TAG is prompted for from the set of known tags."
  (interactive (list :tag (completing-read
                           "Tag: " (bookmark-gt-tags-list) nil t)))
  (unless (stringp tag)
    (user-error "bookmark-gt-jump-tagged: :TAG must be a string"))
  (bookmark-maybe-load-default-file)
  (let* ((pool (bookmark-gt-jump--resolve-pool bookmarks-list
                                               bookmarks-filter
                                               group))
         (record (or bookmark
                     (let ((bookmark-gt-jump--pool pool)
                         (bookmark-gt-jump--sort-by sort-by)
                         (bookmark-gt-jump--preselect preselect)
                         (bookmark-gt-jump--active-filters (list tag))
                         (bookmark-gt-jump--restart-p nil))
                     (when (and (integerp preselect) (> preselect 0))
                       (bookmark-gt-jump--preselect-arm))
                     (bookmark-gt-jump--read (format "Jump [;%s]" tag))))))
    (bookmark-gt-jump-record (bookmark-gt--resolve record "Jump"))))

(provide 'bookmark-gt-jump)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-jump.el ends here
