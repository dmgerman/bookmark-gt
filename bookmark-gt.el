;;; bookmark-gt.el --- Records-only bookmark manager  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Keywords: convenience, matching, hypermedia
;; URL: https://github.com/dmgerman/bookmark-gt
;; Version: 0.2.0
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
;; `bookmark-gt-mode' and shared utilities used by the other
;; bookmark-gt-*.el files.

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
(require 'bookmark-gt-default-tags)
(require 'bookmark-gt-browser-tabs)

;;;###autoload
(define-minor-mode bookmark-gt-mode
  "Toggle the bookmark-gt integrations globally."
  :global t
  :group 'bookmark-gt
  (cond
   (bookmark-gt-mode
    (advice-add 'bookmark-save     :around #'bookmark-gt--save-filter-advice)
    (advice-add 'bookmark--jump-via :override #'bookmark-gt--jump-via-override)
    (advice-add 'rename-file       :around #'bookmark-gt--rename-file-advice)
    (advice-add 'bookmark-default-handler
                :around #'bookmark-gt--file-type-handler-advice)
    (advice-add 'bookmark-store    :after  #'bookmark-gt--auto-temp-advice)
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
    (advice-remove 'bookmark--jump-via #'bookmark-gt--jump-via-override)
    (advice-remove 'rename-file       #'bookmark-gt--rename-file-advice)
    (advice-remove 'bookmark-default-handler
                   #'bookmark-gt--file-type-handler-advice)
    (advice-remove 'bookmark-store    #'bookmark-gt--auto-temp-advice)
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
