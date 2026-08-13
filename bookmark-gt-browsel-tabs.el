;;; bookmark-gt-browsel-tabs.el --- Browser tabs as ephemeral bookmarks  -*- lexical-binding: t; -*-

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
;; Fetches the browser's open tabs (via the browsel WebSocket
;; bridge) and exposes them as temp bookmarks with a dedicated
;; browser-tab handler.  Temp records carry the `bmkp-temp' alist
;; key and are excluded from `bookmark-save' output — restarting
;; Emacs starts with no tab entries; a refresh re-populates them.
;;
;; Entry points:
;;
;;   `bookmark-gt-browsel-tabs-refresh' — one-shot rebuild.
;;   `bookmark-gt-browsel-tabs-mode'    — global minor mode; when
;;                                        enabled, an idle timer
;;                                        refreshes tabs every
;;                                        `bookmark-gt-browsel-tabs-interval'
;;                                        seconds.
;;
;; Loads lazily: if browsel is not installed the file is a no-op
;; and every command signals a friendly `user-error'.

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'bookmark-gt-core)
(require 'bookmark-gt-handlers)
(require 'bookmark-gt-list)

(require 'browsel nil t)

;; browsel is a soft-dep loaded at the top with (require 'browsel nil t).
;; The `ext:' prefix on the FILE argument tells `check-declare' this
;; symbol lives in an external package that need not be present at
;; compile time, so it skips validation.
(declare-function browsel-browser-tabs "ext:browsel")

;; Defined in `bookmark-gt-tags'; declared here so the byte-compiler
;; treats it as dynamic when the refresh loop let-binds it.
(defvar bookmark-gt-prompt-for-tags-flag)

;;;; Customization

(defcustom bookmark-gt-browsel-tabs-browsers nil
  "List of browsel browser clients to query for tabs, or nil for all."
  :type '(choice (const :tag "All connected browsers" nil)
                 (repeat string))
  :group 'bookmark-gt)

(defcustom bookmark-gt-browsel-tabs-filter nil
  "Filter applied to each candidate tab before storing.
Value shape:

  nil        — accept every tab.
  regexp     — accept tabs whose URL matches the regexp.
  function   — called with the tab plist; accept when non-nil."
  :type '(choice (const :tag "Accept all" nil)
                 (regexp   :tag "URL regexp")
                 (function :tag "Predicate function"))
  :group 'bookmark-gt)

;;;; Own-record predicate
;;
;; Records stored by this module carry a `bookmark-gt-browsel-tab'
;; marker; `--clear' filters on it so records owned by other
;; browsel-related packages are not touched.

(defconst bookmark-gt-browsel-tabs--marker-key 'bookmark-gt-browsel-tab
  "Alist key that marks a record as stored by this module.")

(defun bookmark-gt-browsel-tabs--own-record-p (record)
  "Return non-nil when RECORD was stored by this module."
  (bookmark-prop-get record bookmark-gt-browsel-tabs--marker-key))

;;;; Fetch + filter

(defun bookmark-gt-browsel-tabs--fetch ()
  "Return the browser tab list from browsel, or nil after warning."
  (unless (featurep 'browsel)
    (user-error "Browsel is not loaded"))
  (condition-case err
      (browsel-browser-tabs bookmark-gt-browsel-tabs-browsers)
    (error
     (display-warning 'bookmark-gt-browsel-tabs
                      (format "Cannot fetch tabs: %s"
                              (error-message-string err))
                      :warning)
     nil)))

(defun bookmark-gt-browsel-tabs--accept-p (tab)
  "Return non-nil when TAB passes `bookmark-gt-browsel-tabs-filter'."
  (let ((filt bookmark-gt-browsel-tabs-filter)
        (url (or (plist-get tab :url) "")))
    (cond
     ((null filt)      t)
     ((stringp filt)   (string-match-p filt url))
     ((functionp filt) (funcall filt tab))
     (t                t))))

;;;; Store

(defun bookmark-gt-browsel-tabs--store (tab)
  "Store TAB (a browsel plist) as a temp browser-tab bookmark.
The name is the tab title, falling back to the URL.  The
owning browser's client name becomes a tag so it shows up in the
list buffer's Tags column and in the `;tag' particle filter."
  (let* ((url (or (plist-get tab :url) ""))
         (title (or (plist-get tab :title) ""))
         (id (plist-get tab :id))
         (browser (plist-get tab :browsel-browser))
         (base (if (string-empty-p title) url title))
         (props (list (cons 'url url)
                      (cons 'browsel-id id)
                      (cons 'browsel-browser browser)
                      (cons bookmark-gt-temp-key t)
                      (cons bookmark-gt-browsel-tabs--marker-key t))))
    (when (and (stringp browser) (not (string-empty-p browser)))
      (push (cons 'tags (list browser)) props))
    (when (and (stringp title) (not (string-empty-p title)))
      (push (cons 'annotation title) props))
    (bookmark-gt-set-non-file base
                              'bookmark-gt-handler-url-jump
                              props
                              t)))

(defun bookmark-gt-browsel-tabs--clear ()
  "Remove every browsel-owned record from `bookmark-alist'.
Matches only records carrying the
`bookmark-gt-browsel-tabs--marker-key' marker, so records
owned by other browsel-related packages are left alone."
  (setq bookmark-alist
        (seq-remove #'bookmark-gt-browsel-tabs--own-record-p
                    bookmark-alist))
  (setq bookmark-alist-modification-count
        (1+ bookmark-alist-modification-count))
  (bookmark-gt-list-refresh))

;;;; Refresh

(defvar bookmark-gt-browsel-tabs--refreshing nil
  "Non-nil while `bookmark-gt-browsel-tabs-refresh' is running.
Prevents re-entrancy: the idle timer might fire while a manual
refresh (or the mode-on immediate refresh) is still in progress,
which would produce duplicate records.  A second refresh that
finds this flag set silently returns.")

;;;###autoload
(defun bookmark-gt-browsel-tabs-refresh ()
  "Rebuild browser-tab bookmarks from live browser state.
Clears existing tab records, fetches the current tabs via
browsel, applies `bookmark-gt-browsel-tabs-filter', and stores
one temp bookmark per surviving tab.  Guarded against
re-entrancy."
  (interactive)
  (if bookmark-gt-browsel-tabs--refreshing
      (when (called-interactively-p 'interactive)
        (message "Browser-tab refresh already in progress; skipping"))
    (let ((bookmark-gt-browsel-tabs--refreshing t)
          (count 0))
      ;; Silence the after-hook (would fire once per stored tab) and
      ;; auto-save (would trigger mid-batch once modification-count
      ;; crosses `bookmark-save-flag') during the loop.  Temp records
      ;; are excluded from `bookmark-save' anyway, so a mid-batch
      ;; save is pure waste — and it produced spurious \"Cannot
      ;; syntax-propertize because of narrowing\" warnings from the
      ;; bookmark-file write path.
      (let ((bookmark-save-flag nil)
            ;; Silence per-tab tag prompt during the batch.
            (bookmark-gt-prompt-for-tags-flag nil))
        (bookmark-gt-browsel-tabs--clear)
        (dolist (tab (bookmark-gt-browsel-tabs--fetch))
          (let ((url (plist-get tab :url)))
            (when (and (stringp url) (not (string-empty-p url))
                       (bookmark-gt-browsel-tabs--accept-p tab))
              (bookmark-gt-browsel-tabs--store tab)
              (setq count (1+ count))))))
      (bookmark-gt-list-refresh)
      (when (called-interactively-p 'interactive)
        (message "Refreshed %d browser-tab bookmark(s)" count)))))

;;;; Mode
;;
;; No idle timer — refresh runs on demand: `g' in the list
;; buffer, or `M-x bookmark-gt-browsel-tabs-refresh'.  Mode-on
;; runs one immediate refresh.

;;;###autoload
(define-minor-mode bookmark-gt-browsel-tabs-mode
  "Global minor mode that keeps browser-tab bookmarks in sync.

When enabled, `bookmark-gt-browsel-tabs-refresh' runs on
demand — every time the jump reader is invoked, the list
buffer is opened, or `g' is pressed in the list buffer.  There
is no idle timer; refreshes are on-request.

Manual refresh: `bookmark-gt-browsel-tabs-refresh'.

Turning the mode off removes the refresher from the ephemeral
hook and clears any tab records that are currently in the
alist \(only records with our own handler symbol; other
browsel-related packages' bookmarks are untouched).

Requires browsel to be installed and connected.  Enable is a
`user-error' no-op when browsel is not loaded."
  :global t
  :group 'bookmark-gt
  (cond
   ((and bookmark-gt-browsel-tabs-mode (not (featurep 'browsel)))
    (setq bookmark-gt-browsel-tabs-mode nil)
    (user-error "Browsel is not loaded"))
   (bookmark-gt-browsel-tabs-mode
    (bookmark-gt-browsel-tabs-refresh))
   (t
    (bookmark-gt-browsel-tabs--clear))))

(provide 'bookmark-gt-browsel-tabs)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-browsel-tabs.el ends here
