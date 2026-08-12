;;; bookmark-gt-default-tags.el --- Context-based default tags  -*- lexical-binding: t; -*-

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
;; A hook into `bookmark-gt-set-tag-reader-hook' that computes
;; context-appropriate default tags on `bookmark-gt-set'.  The
;; interactive tag reader (registered at hook depth 90 by
;; `bookmark-gt-tags-enable') uses the return value as the seed;
;; the user is free to accept, edit, or clear.
;;
;; The defaults live in `bookmark-gt-default-tags', a small DSL:
;;
;;   nil                — no default tags (feature off).
;;   \"tag\"              — one tag, always applied.
;;   (\"a\" \"b\")          — a list of tags, always applied.
;;   (lambda (record))  — called at set time with the record's
;;                        data alist; must return any of the above
;;                        shapes.  Errors are caught and demoted
;;                        to a warning; nothing is applied.
;;
;; Context-sensitive rules (per-mode, per-file, per-URL) are
;; expressed by writing a function that inspects the record and
;; returns the right tag list.  The DSL intentionally stops there;
;; a richer rule engine would only be a thin cover over the same
;; function form.
;;
;; The feature is off until `bookmark-gt-default-tags-mode' is
;; enabled (or the parent `bookmark-gt-mode' turns it on).

;;; Code:

(require 'seq)
(require 'bookmark-gt-core)
(require 'bookmark-gt-tags)

;;;; Customization

(defcustom bookmark-gt-default-tags nil
  "Default tag list to seed the tag reader on `bookmark-gt-set'.

Value shape:

  nil               — no defaults (feature off).
  a string          — one tag.
  a list of strings — multiple tags.
  a function        — called with one argument, the record's data
                      alist.  Must return one of the above shapes.
                      Errors are caught and demoted to a warning.

The value is a seed the user can accept or override in the tag
reader.  Nothing is forced onto the record — see
`bookmark-gt-default-tags--hook' for the composition contract."
  :type '(choice (const  :tag "None"          nil)
                 (string :tag "Single tag")
                 (repeat :tag "List of tags"  string)
                 (function :tag "Function returning any of the above"))
  :group 'bookmark-gt)

;;;; Shape classifier

(defun bookmark-gt-default-tags--kind (val)
  "Classify VAL as one of the DSL shapes.
Returns `empty', `bare', `flat', `function', or `unknown'."
  (cond
   ((null val)                          'empty)
   ((stringp val)                       'bare)
   ((functionp val)                     'function)
   ((and (listp val)
         (seq-every-p #'stringp val))   'flat)
   (t                                   'unknown)))

;;;; Resolver

(defun bookmark-gt-default-tags--warn (fmt &rest args)
  "Show a warning built from FMT + ARGS under this feature's warning class."
  (display-warning 'bookmark-gt-default-tags
                   (apply #'format fmt args) :warning))

(defun bookmark-gt-default-tags--resolve (val record)
  "Return a normalized tag list from VAL, given RECORD.
VAL follows the shape described in `bookmark-gt-default-tags'.
Returns nil for the empty shape or on any resolution error;
never signals."
  (pcase (bookmark-gt-default-tags--kind val)
    ('empty nil)
    ('bare  (list val))
    ('flat  val)
    ('function
     (condition-case err
         (let ((computed (funcall val record)))
           (pcase (bookmark-gt-default-tags--kind computed)
             ('empty nil)
             ('bare  (list computed))
             ('flat  computed)
             (_
              (bookmark-gt-default-tags--warn
               "`bookmark-gt-default-tags' function returned %S, \
which is not a recognized shape.  No tags applied."
               computed)
              nil)))
       (error
        (bookmark-gt-default-tags--warn
         "`bookmark-gt-default-tags' function signaled: %s.  \
No tags applied."
         (error-message-string err))
        nil)))
    (_
     (bookmark-gt-default-tags--warn
      "`bookmark-gt-default-tags' value %S is not a recognized \
shape.  No tags applied." val)
     nil)))

;;;; Hook

(defun bookmark-gt-default-tags--hook (record seed-tags)
  "Return SEED-TAGS augmented with `bookmark-gt-default-tags' for RECORD.
Tag-reader hook: the returned list is the union of SEED-TAGS and
the resolved defaults, in that order, deduped by
`bookmark-gt--normalize-tags'."
  (let ((defaults (bookmark-gt-default-tags--resolve
                   bookmark-gt-default-tags record)))
    (bookmark-gt--normalize-tags (append seed-tags defaults))))

;;;; Enable / disable

;;;###autoload
(defun bookmark-gt-default-tags-enable ()
  "Register the default-tags seed into `bookmark-gt-set-tag-reader-hook'.
Depth 0 so it runs before the interactive reader (registered at
depth 90 by `bookmark-gt-tags-enable'), letting the reader use
the seed as initial input."
  (add-hook 'bookmark-gt-set-tag-reader-hook
            #'bookmark-gt-default-tags--hook))

;;;###autoload
(defun bookmark-gt-default-tags-disable ()
  "Remove `bookmark-gt-default-tags--hook' from the tag-reader hook."
  (remove-hook 'bookmark-gt-set-tag-reader-hook
               #'bookmark-gt-default-tags--hook))

;;;###autoload
(define-minor-mode bookmark-gt-default-tags-mode
  "Global minor mode that applies `bookmark-gt-default-tags' on set."
  :global t
  :group 'bookmark-gt
  (if bookmark-gt-default-tags-mode
      (bookmark-gt-default-tags-enable)
    (bookmark-gt-default-tags-disable)))

(provide 'bookmark-gt-default-tags)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-default-tags.el ends here
