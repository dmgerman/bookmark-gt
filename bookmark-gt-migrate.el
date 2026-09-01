;;; bookmark-gt-migrate.el --- One-shot migration from bookmark+ to bookmark-gt   -*- lexical-binding: t; -*-

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
;; One-shot rewrite of `bookmark-alist' records saved by
;; bookmark+ into their bookmark-gt equivalents:
;;
;;   - Handler symbols (`bmkp-jump-dired', `bmkp-jump-url-browse',
;;     `bmkp-gt-browsel-tabs-jump', ...) are rewritten to the
;;     bookmark-gt-owned handlers so jumps work without bookmark+
;;     loaded.
;;   - URL bookmarks: `location' → `url'.
;;   - Bookmark+ bookkeeping props are removed
;;     (`bmkp-gt-load-index', `buffer-name', Dired-state fields,
;;     empty `annotation' / `tags', region-context strings on
;;     non-region records).
;;   - The `filename' placeholder bookmark+ writes on non-file
;;     records is removed, so migrated records carry no
;;     `filename' key at all, as bookmark-gt's own do.
;;   - Standard fields are preserved: `filename' (when it names a
;;     real file), `position', `front-context-string',
;;     `rear-context-string', `visits', `last-visited',
;;     `created', `last-modified'.
;;
;; Not autoloaded.  This module is a one-time tool; load it
;; explicitly when needed:
;;
;;   (require 'bookmark-gt-migrate)
;;   M-x bookmark-gt-migrate-from-bookmark-plus
;;
;; The command mutates the in-memory `bookmark-alist' only.  It
;; does NOT save the bookmark file.  Inspect the results in
;; `bookmark-gt-list', then commit with `bookmark-save' when
;; satisfied.  Keep a backup of the file first.

;;; Code:

(require 'bookmark)
(require 'bookmark-gt-core)

(defconst bookmark-gt-migrate--handler-map
  '((bmkp-jump-dired                   . bookmark-gt-handler-dired-jump)
    (bmkp-jump-url-browse              . bookmark-gt-handler-url-jump)
    (bmkp-jump-url-browse-other-window . bookmark-gt-handler-url-jump)
    (bmkp-gt-browsel-tabs-jump         . bookmark-gt-handler-url-jump))
  "Alist mapping bookmark+ handler symbols to bookmark-gt equivalents.")

(defconst bookmark-gt-migrate--strip-props
  '(bmkp-gt-load-index
    buffer-name
    front-context-region-string
    rear-context-region-string)
  "Bookmark+ bookkeeping props removed from every migrated record.
`created' and `last-modified' are kept — bookmark-gt uses both.
The Dired state keys (`dired-directory', `dired-marked',
`dired-subdirs', `dired-hidden-dirs', `dired-switches',
`dired-virtual') are also kept — bookmark-gt's Dired handler
consumes them just like bookmark+ did.")

(defun bookmark-gt-migrate--rewrite-record (record)
  "Rewrite RECORD in place; return non-nil when a change was made."
  (let* ((old-handler (bookmark-prop-get record 'handler))
         (new-handler (alist-get old-handler
                                 bookmark-gt-migrate--handler-map))
         (changed nil))
    (when new-handler
      (bookmark-prop-set record 'handler new-handler)
      (setq changed t))
    ;; URL records: promote `location' to `url' when `url' is
    ;; absent, then drop `location' either way (it duplicates
    ;; `url' once we've migrated).
    (when (eq (bookmark-prop-get record 'handler)
              'bookmark-gt-handler-url-jump)
      (when (and (not (bookmark-prop-get record 'url))
                 (bookmark-prop-get record 'location))
        (bookmark-prop-set record 'url
                           (bookmark-prop-get record 'location))
        (setq changed t))
      (when (assq 'location (cdr record))
        (setcdr record (assq-delete-all 'location (cdr record)))
        (setq changed t)))
    ;; Strip bookmark+ bookkeeping props.
    (dolist (key bookmark-gt-migrate--strip-props)
      (when (assq key (cdr record))
        (setcdr record (assq-delete-all key (cdr record)))
        (setq changed t)))
    ;; Non-file records: bookmark+ fills `filename' with a
    ;; placeholder string, bookmark-gt omits the key.  Removing it
    ;; here is what makes a migrated record match the shape
    ;; bookmark-gt writes; `bookmark-gt-filename-of' still reads
    ;; the placeholder as absent for files that were never
    ;; migrated.
    (when (equal (bookmark-prop-get record 'filename)
                 bookmark-gt-non-file-placeholder)
      (setcdr record (assq-delete-all 'filename (cdr record)))
      (setq changed t))
    ;; Strip empty annotation / tags.
    (when (and (assq 'annotation (cdr record))
               (null (bookmark-prop-get record 'annotation)))
      (setcdr record (assq-delete-all 'annotation (cdr record)))
      (setq changed t))
    (when (and (assq 'tags (cdr record))
               (null (bookmark-prop-get record 'tags)))
      (setcdr record (assq-delete-all 'tags (cdr record)))
      (setq changed t))
    changed))

;;;###autoload
(defun bookmark-gt-migrate-from-bookmark-plus ()
  "Rewrite bookmark+ records in `bookmark-alist' to bookmark-gt form.
Returns the number of records changed.  Does NOT save; run
`bookmark-save' after inspecting the results in
`bookmark-gt-list'."
  (interactive)
  (let ((changed 0))
    (dolist (record bookmark-alist)
      (when (bookmark-gt-migrate--rewrite-record record)
        (setq changed (1+ changed))))
    (when (> changed 0)
      (setq bookmark-alist-modification-count
            (1+ bookmark-alist-modification-count))
      (when (fboundp 'bookmark-gt-list-refresh)
        (bookmark-gt-list-refresh)))
    (message
     "Migrated %d record(s).  Run `bookmark-save' to commit."
     changed)
    changed))

(provide 'bookmark-gt-migrate)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-migrate.el ends here
