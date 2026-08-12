;;; bookmark-gt.el --- Records-only bookmark manager  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Keywords: convenience, matching, hypermedia
;; URL: https://github.com/dmgerman/bookmark-gt
;; Version: 0.1.0
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
;; bookmark-gt is a bookmark manager layered on vanilla `bookmark.el'
;; with tags, non-file bookmark types (URL, EWW, Dired, Info, Org
;; heading, PDF), a `tabulated-list-mode' buffer, and integration
;; with consult / marginalia / orderless when they are available.
;;
;; Design principles are documented under ai/reimplement.org and
;; ai/staging.org in the source repository.  In short: records are
;; the only persistent mutable state, one registry per axis, and
;; bookmark files round-trip with vanilla bookmark.el.
;;
;; This file is the entry point.  It provides the master switch
;; `bookmark-gt-mode' and shared utilities used by the other
;; bookmark-gt-*.el files.

;;; Code:

(defconst bookmark-gt-version "0.1.0"
  "Version string for the bookmark-gt package.
Kept in sync with the `;; Version:' header in every
bookmark-gt*.el file by scripts/update-version.sh; the CI target
`make check-version' fails on drift.")

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
(require 'bookmark-gt-browsel-tabs)

;;;###autoload
(define-minor-mode bookmark-gt-mode
  "Toggle the bookmark-gt integrations globally.

When enabled, `bookmark-gt-set' picks up the interactive tag
reader.  Additional features (list buffer keybindings, jump
reader, auto-update timer) attach here in later stages."
  :global t
  :group 'bookmark-gt
  (cond
   (bookmark-gt-mode
    (bookmark-gt-tags-enable)
    (bookmark-gt-jump-enable)
    (bookmark-gt-install-temp-save-filter))
   (t
    (bookmark-gt-tags-disable)
    (bookmark-gt-jump-disable)
    (bookmark-gt-uninstall-temp-save-filter))))

(provide 'bookmark-gt)

;;; bookmark-gt.el ends here
