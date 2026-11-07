;;; bookmark-gt.el --- Records-only bookmark manager  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Keywords: convenience, matching, hypermedia
;; URL: https://github.com/dmgerman/bookmark-gt
;; Version: 0.9.1
;; Package-Requires: ((emacs "30.1"))

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
;; bookmark-gt is a bookmark manager layered on built-in `bookmark.el'
;; with tags, non-file bookmark types (URL, EWW, Dired, Info, Org
;; heading, PDF), a `tabulated-list-mode' buffer, and integration
;; with consult / marginalia / orderless when they are available.
;;
;; Design principles: records are the only persistent mutable
;; state, one registry per axis (handlers, filters, sorts), and
;; bookmark files round-trip with built-in bookmark.el.
;; Architectural notes for maintainers live under
;; `ai/architecture.md' in the source repository.
;;
;; This file is the entry point.  It provides the master switch
;; `bookmark-gt-mode', the commands that capture the current
;; location (`bookmark-gt-create', `bookmark-gt-update'), and the
;; `bookmark-store' advice.

;;; Acknowledgements:
;;
;; bookmark-gt takes design and features from bookmark+ by Drew
;; Adams — tags, non-file bookmark types, temporary bookmarks,
;; visit tracking, and the on-disk alist schema all originate
;; there.  See the Acknowledgements section of readme.org for
;; details.

;;; Code:

(defconst bookmark-gt-version
  (eval-when-compile
    (require 'lisp-mnt)
    (or (lm-with-file (or (bound-and-true-p byte-compile-current-file)
                          load-file-name
                          buffer-file-name)
          (lm-header "version"))
        "unknown"))
  "Version of bookmark-gt, as a string.
Read from the `;; Version:' header of this file, which is the
only place the version is written.  The value is resolved when
this file is compiled, or when it is loaded as source.  The
other bookmark-gt files carry no version header: they are
secondary files of one multi-file package, declared as such by
the `package-lint-main-file' file-local variable each one sets.")

;;;###autoload
(defun bookmark-gt-version (&optional here)
  "Return the bookmark-gt version as a string.
Interactively, display it in the echo area together with the
Emacs version, which is the form to paste into a bug report.
With a prefix argument HERE, insert that same text at point
instead.

Named after the `bookmark-gt-version' variable it reports,
which is the relation the command `emacs-version' has to its
own variable."
  (interactive "P")
  (let ((text (format "bookmark-gt %s (GNU Emacs %s)"
                      bookmark-gt-version emacs-version)))
    (cond (here    (insert text))
          ((called-interactively-p 'interactive) (message "%s" text))
          (t       bookmark-gt-version))))

(defgroup bookmark-gt nil
  "Records-only bookmark manager built on `bookmark.el'."
  :group 'bookmark
  :prefix "bookmark-gt-")

(require 'bookmark-gt-core)
(require 'bookmark-gt-tags)
(require 'bookmark-gt-handlers)
(require 'bookmark-gt-list)
(require 'bookmark-gt-jump)
(require 'bookmark-gt-auto-update)
(require 'bookmark-gt-browser-tabs)

;;;; Storing through `bookmark-store'

(defun bookmark-gt--store-advice (orig-fn name alist no-overwrite)
  "Apply bookmark-gt\='s policies to `bookmark-store'.
ORIG-FN is `bookmark-store'; NAME, ALIST and NO-OVERWRITE are its
arguments.

The built-in replaces any record of the same name.  That is
right when a package re-stores its own bookmark, and wrong when
the name came from the user: burly asks for a name, so storing a
window layout under one an existing bookmark uses would replace
that bookmark, whatever
`bookmark-gt-allow-same-name-bookmarks\=' says.

A store onto a name already in use therefore either replaces the
record of its own kind (`bookmark-gt--store-replaceable-record\='),
adds a second record when the setting permits one, or signals
when it does not.  Storing under an unused name is untouched, as
is a caller that already passed NO-OVERWRITE."
  ;; The decision below reads `bookmark-alist', while ORIG-FN's own
  ;; load runs a step later, so a store arriving before anything
  ;; has read the file would be judged against an empty list and
  ;; take the unused-name branch whatever the file holds.
  (bookmark-maybe-load-default-file)
  (let ((records (and (not no-overwrite)
                      (stringp name)
                      (bookmark-gt--records-named name))))
    (cond
     ((null records) (funcall orig-fn name alist no-overwrite))
     ((bookmark-gt--store-replaceable-record name alist)
      (bookmark-gt--store-replace
       (bookmark-gt--store-replaceable-record name alist) name alist))
     ((bookmark-gt-name-available-p name alist)
      ;; The setting permits another bookmark of this name, so the
      ;; existing ones are left alone.
      (funcall orig-fn name alist 'no-overwrite))
     (t
      (user-error
       "A %s bookmark named `%s' exists; storing a %s bookmark under that name would replace it"
       (bookmark-gt-handler-name (car records)) name
       (bookmark-gt-handler-name (cons name alist)))))))

;;;; Public: interactive entry point

;; NAME's sentinel distinguishes an interactive call from a Lisp
;; call passing nil.  `called-interactively-p' cannot do this
;; reliably here: invoking `bookmark-gt-create' as a transient suffix
;; (as in a `transient-define-prefix' menu) makes it return nil
;; even though the user invoked the command interactively.
;; `bookmark-gt-tags.el' hit the same issue with its tag reader
;; and moved off `called-interactively-p'; this sentinel is the
;; equivalent fix for the name prompt.
(defconst bookmark-gt--prompt-name (make-symbol "bookmark-gt--prompt-name")
  "Sentinel NAME value that requests the interactive name prompt.
`bookmark-gt-create' produces this value from its `interactive'
spec.  Lisp callers should pass a name string, or nil to accept
the suggested name without prompting.")

(defun bookmark-gt--capture-here ()
  "Return (DATA . SUGGESTED-NAME) describing the current location.
DATA is a record alist; SUGGESTED-NAME is the name the location
suggests for itself.  Shared by `bookmark-gt-create', which
stores DATA as a new record, and `bookmark-gt-update', which
puts it onto an existing one."
  (let* ((region-active (and bookmark-gt-use-region (use-region-p)))
         ;; `bookmark-make-record' names the record after
         ;; `bookmark-current-bookmark' when the buffer's
         ;; `bookmark-make-record-function' supplies no name, and
         ;; lists it first under `defaults'.  That variable holds
         ;; the last bookmark jumped to or stored in this buffer,
         ;; which has nothing to do with the location being
         ;; bookmarked now, so it is bound to nil over the record
         ;; construction.
         (raw-record (let ((bookmark-current-bookmark nil))
                       (if region-active
                           ;; Capture context around region-start (not
                           ;; wherever point happens to be within the
                           ;; region) so the built-in front/rear
                           ;; context strings anchor to the region's
                           ;; beginning.
                           (save-excursion
                             (goto-char (region-beginning))
                             (bookmark-make-record))
                         (bookmark-make-record))))
         (data (if (stringp (car raw-record)) (cdr raw-record) raw-record))
         (data (bookmark-gt--record-with-region data))
         ;; bookmark-gt owns the Dired handler; when capturing from
         ;; a Dired buffer, force our handler so the record is
         ;; unambiguous on disk regardless of what Dired's
         ;; `bookmark-make-record-function' produced.  Also splice
         ;; in the dired state (marks, inserted/hidden subdirs, ls
         ;; switches, `dired-directory') so jumps restore what the
         ;; user saw.  Existing keys with the same name are removed
         ;; first, so re-capturing refreshes the state instead of
         ;; accumulating stale copies.
         (data
          (if (derived-mode-p 'dired-mode)
              (let* ((state (bookmark-gt--dired-collect-state))
                     (state-keys (mapcar #'car state))
                     (stripped (seq-remove
                                (lambda (cell)
                                  (memq (car-safe cell) state-keys))
                                data))
                     (rehandled (cons (cons 'handler
                                            'bookmark-gt-handler-dired-jump)
                                      (assq-delete-all 'handler stripped))))
                (append rehandled state))
            data)))
    (cons data
          (or (and (stringp (car raw-record)) (car raw-record))
              (car (bookmark-prop-get raw-record 'defaults))
              (buffer-name)))))

;;;###autoload
(defun bookmark-gt-create (&optional name tags)
  "Create a bookmark at the current location.

Always creates.  To change where an existing bookmark points,
use `bookmark-gt-update' (to here) or `bookmark-gt-relocate' (to
a target you type).

NAME is the bookmark name.  Interactive calls prompt for it with
the suggested name as editable initial input, completing over the
existing names so a repeat is visible while typing.  Lisp callers
pass a name string, or nil to accept the suggested name without
prompting.

TAGS is the tag list to store, or t to run the tag pipeline: the
default tags of `bookmark-gt-default-tags-mode', the tag reader
when `bookmark-gt-prompt-for-tags-flag' is non-nil, then
`bookmark-gt-create-tag-reader-hook'.  Interactive calls pass t.
The typed creators (`bookmark-gt-create-url' and the rest) take
TAGS the same way.

`bookmark-gt-allow-same-name-bookmarks' decides what happens when
the name is already in use.  Returns the stored record."
  (interactive (list bookmark-gt--prompt-name t))
  (bookmark-maybe-load-default-file)
  (pcase-let* ((`(,data . ,suggested) (bookmark-gt--capture-here))
               (refined (bookmark-gt--refine-name suggested data))
               (chosen
                (cond
                 ((eq name bookmark-gt--prompt-name)
                  ;; The suggested name is inserted as editable
                  ;; initial input rather than offered as a
                  ;; minibuffer default: RET accepts it, point sits
                  ;; at its end for a small edit, and `C-a C-k'
                  ;; rewrites it.  Completion is over the existing
                  ;; names, so reusing one is visible before it
                  ;; happens rather than reported afterwards.
                  (completing-read
                   "Create bookmark: "
                   (mapcar #'bookmark-name-from-full-record bookmark-alist)
                   nil nil refined 'bookmark-history refined))
                 (name name)
                 (t refined))))
    (bookmark-gt--create-record chosen data (bookmark-gt--create-tags tags))))

;;;; Update
;;
;; "This bookmark now lives where I am."  Re-captures the location
;; and puts it onto an existing record, which is why it is not a
;; create: the record keeps its name, id, tags, annotation and
;; history.  Only what describes *where* is replaced.

;;;###autoload
(defun bookmark-gt-update (&optional bookmark)
  "Change BOOKMARK to point at the current location.

BOOKMARK is a record, a name, or an id; nil prompts.  The
bookmark keeps its name, id, tags, annotation, creation time and
visit history — see `bookmark-gt-preserved-props'.  Everything
describing where it points is replaced, which also removes the
leftovers of a previous type.

Signals for bookmarks with no buffer location — URL, function,
kmacro and sequence — since there is nothing at point to capture
for them; use `bookmark-gt-relocate' to retarget those.

Asks for confirmation when the bookmark\='s type would change."
  (interactive)
  (bookmark-maybe-load-default-file)
  (let ((record (bookmark-gt--resolve bookmark "Update bookmark")))
    (unless (bookmark-gt--buffer-backed-p record)
      (user-error
       "`%s' has no buffer location; retarget it with `%s'"
       (bookmark-name-from-full-record record) "bookmark-gt-relocate"))
    (pcase-let* ((`(,data . ,_) (bookmark-gt--capture-here))
                 (saved (bookmark-gt--preserved-props record))
                 (was (bookmark-gt-handler-name record))
                 (now (bookmark-gt-handler-name (cons "x" data))))
      (when (and (not (equal was now))
                 (not (yes-or-no-p
                       (format "`%s' is a %s bookmark; make it a %s bookmark? "
                               (bookmark-name-from-full-record record)
                               was now))))
        (user-error "Not updated"))
      (setcdr record data)
      (bookmark-gt--restore-preserved record saved)
      (bookmark-gt--after-mutation record 'update)
      (message "`%s' now points here"
               (bookmark-name-from-full-record record))
      record)))

;;;###autoload
(defvar-keymap bookmark-gt-mode-map
  :doc "Keymap for `bookmark-gt-mode'.

Remaps the built-in bookmark commands to bookmark-gt\='s, so an
existing binding — the stock `C-x r m\=', or one a user set years
ago — reaches the bookmark-gt command without being rebound, and
goes back to the built-in when the mode is off.

Only the *commands* are remapped.  The functions behind them keep
their own semantics for Lisp callers, which is what packages that
store bookmarks programmatically depend on."
  "<remap> <bookmark-set>"               #'bookmark-gt-create
  "<remap> <bookmark-set-no-overwrite>"  #'bookmark-gt-create
  "<remap> <bookmark-jump>"              #'bookmark-gt-jump
  "<remap> <bookmark-delete>"            #'bookmark-gt-delete
  "<remap> <bookmark-rename>"            #'bookmark-gt-rename
  "<remap> <bookmark-bmenu-list>"        #'bookmark-gt-list)

;;;###autoload
(define-minor-mode bookmark-gt-mode
  "Toggle the bookmark-gt integrations globally."
  :global t
  :group 'bookmark-gt
  :keymap bookmark-gt-mode-map
  (cond
   (bookmark-gt-mode
    (advice-add 'bookmark-save     :around #'bookmark-gt--save-filter-advice)
    (advice-add 'bookmark-handle-bookmark
                :around #'bookmark-gt--handle-bookmark-advice)
    (advice-add 'rename-file       :around #'bookmark-gt--rename-file-advice)
    (advice-add 'bookmark-default-handler
                :around #'bookmark-gt--file-type-handler-advice)
    (advice-add 'bookmark-store    :after  #'bookmark-gt--auto-temp-advice)
    (advice-add 'bookmark-store    :around #'bookmark-gt--store-advice)
    (advice-add 'bookmark-load     :after  #'bookmark-gt--ensure-ids-advice)
    (advice-add 'bookmark-load     :after  #'bookmark-gt-highlight--on-load)
    (advice-add 'tabulated-list-sort :after
                #'bookmark-gt-list--tabulated-sort-observer)
    (add-hook 'bookmark-after-jump-hook #'bookmark-gt--on-jump-record-visit)
    (add-hook 'bookmark-after-jump-hook #'bookmark-gt--on-jump-restore-region)
    (add-hook 'bookmark-after-jump-hook #'bookmark-gt-highlight--on-jump)
    (add-hook 'find-file-hook           #'bookmark-gt-highlight--on-find-file)
    (add-hook 'kill-emacs-hook          #'bookmark-gt-list-save-state)
    (bookmark-gt-highlight--refresh-all-visible)
    (bookmark-gt-jump--install-marginalia))
   (t
    (advice-remove 'bookmark-save     #'bookmark-gt--save-filter-advice)
    (advice-remove 'bookmark-handle-bookmark
                   #'bookmark-gt--handle-bookmark-advice)
    (advice-remove 'rename-file       #'bookmark-gt--rename-file-advice)
    (advice-remove 'bookmark-default-handler
                   #'bookmark-gt--file-type-handler-advice)
    (advice-remove 'bookmark-store    #'bookmark-gt--auto-temp-advice)
    (advice-remove 'bookmark-store    #'bookmark-gt--store-advice)
    (advice-remove 'bookmark-load     #'bookmark-gt--ensure-ids-advice)
    (advice-remove 'bookmark-load     #'bookmark-gt-highlight--on-load)
    (advice-remove 'tabulated-list-sort
                   #'bookmark-gt-list--tabulated-sort-observer)
    (remove-hook 'bookmark-after-jump-hook #'bookmark-gt--on-jump-record-visit)
    (remove-hook 'bookmark-after-jump-hook #'bookmark-gt--on-jump-restore-region)
    (remove-hook 'bookmark-after-jump-hook #'bookmark-gt-highlight--on-jump)
    (remove-hook 'find-file-hook           #'bookmark-gt-highlight--on-find-file)
    (remove-hook 'kill-emacs-hook          #'bookmark-gt-list-save-state)
    (bookmark-gt-highlight--clear-all-visible)
    (bookmark-gt-jump--uninstall-marginalia))))

(provide 'bookmark-gt)

;;; bookmark-gt.el ends here
