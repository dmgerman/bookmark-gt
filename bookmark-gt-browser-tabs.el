;;; bookmark-gt-browser-tabs.el --- Browser tabs as ephemeral bookmarks  -*- lexical-binding: t; -*-

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
;; Fetches the browser's open tabs (via the browser-gt WebSocket
;; bridge) and exposes them as temp bookmarks with a dedicated
;; browser-tab handler.  Temp records carry the `bmkp-temp' alist
;; key and are excluded from `bookmark-save' output — restarting
;; Emacs starts with no tab entries; a refresh re-populates them.
;;
;; Entry points:
;;
;;   `bookmark-gt-browser-tabs-refresh' — one-shot rebuild.
;;   `bookmark-gt-browser-tabs-mode'    — global minor mode; when
;;                                        enabled, subscribes to
;;                                        browser-gt's client
;;                                        connect and disconnect
;;                                        hooks and refreshes the
;;                                        tab records on each event,
;;                                        coalesced through a
;;                                        `bookmark-gt-browser-tabs-debounce'
;;                                        timer.  Also registers
;;                                        `bookmark-gt-browser-tabs-refresh'
;;                                        on `bookmark-gt-jump-before-read-hook'
;;                                        so the jump reader sees
;;                                        current tabs at each read.
;;
;; Loads lazily: if browser-gt is not installed the file is a no-op
;; and every command signals a friendly `user-error'.

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'bookmark-gt-core)
(require 'bookmark-gt-handlers)
(require 'bookmark-gt-list)

(require 'browser-gt nil t)

;; browser-gt is a soft-dep loaded at the top with (require 'browser-gt nil t).
;; The `ext:' prefix on the FILE argument tells `check-declare' this
;; symbol lives in an external package that need not be present at
;; compile time, so it skips validation.
(declare-function browser-gt-browser-tabs "ext:browser-gt")
(declare-function browser-gt-connected-clients "ext:browser-gt")

(defvar browser-gt-client-connected-functions)
(defvar browser-gt-client-disconnected-functions)

;; Defined in `bookmark-gt-tags'; declared here so the byte-compiler
;; treats it as dynamic when the refresh loop let-binds it.
(defvar bookmark-gt-prompt-for-tags-flag)

;;;; Customization

(defcustom bookmark-gt-browser-tabs-browsers nil
  "List of browser-gt browser clients to query for tabs, or nil for all."
  :type '(choice (const :tag "All connected browsers" nil)
                 (repeat string))
  :group 'bookmark-gt)

(defcustom bookmark-gt-browser-tabs-filter nil
  "Filter applied to each candidate tab before storing.
Value shape:

  nil        — accept every tab.
  regexp     — accept tabs whose URL matches the regexp.
  function   — called with the tab plist; accept when non-nil."
  :type '(choice (const :tag "Accept all" nil)
                 (regexp   :tag "URL regexp")
                 (function :tag "Predicate function"))
  :group 'bookmark-gt)

(defcustom bookmark-gt-browser-tabs-debounce 0.3
  "Seconds to coalesce browser connect/disconnect events before refreshing.
A single connect or disconnect can arrive as several events in
rapid succession (e.g. reload, multiple windows).  The connect
and disconnect hooks schedule the refresh through a single timer;
subsequent events during the debounce window fold into the same
refresh."
  :type 'number
  :group 'bookmark-gt)

;;;; Own-record predicate
;;
;; Records stored by this module carry a `bookmark-gt-browser-tab'
;; marker; `--clear' filters on it so records owned by other
;; browser-gt-related packages are not touched.

(defconst bookmark-gt-browser-tabs--marker-key 'bookmark-gt-browser-tab
  "Alist key that marks a record as stored by this module.")

(defun bookmark-gt-browser-tabs--own-record-p (record)
  "Return non-nil when RECORD was stored by this module."
  (bookmark-prop-get record bookmark-gt-browser-tabs--marker-key))

;; Keeping a tab removes these three, leaving a plain URL
;; bookmark.  Losing the marker is also what makes the record
;; survive: `--clear' no longer recognizes it as a live-tab copy.
(dolist (key (list 'browser-gt-id
                   'browser-gt-browser
                   bookmark-gt-browser-tabs--marker-key))
  (unless (memq key bookmark-gt-session-only-props)
    (push key bookmark-gt-session-only-props)))

;;;; Fetch + filter

(defun bookmark-gt-browser-tabs--fetch ()
  "Return the browser tab list from browser-gt, or nil after warning."
  (unless (featurep 'browser-gt)
    (user-error "Package `browser-gt' is not loaded"))
  (condition-case err
      (browser-gt-browser-tabs bookmark-gt-browser-tabs-browsers)
    (error
     (display-warning 'bookmark-gt-browser-tabs
                      (format "Cannot fetch tabs: %s"
                              (error-message-string err))
                      :warning)
     nil)))

(defun bookmark-gt-browser-tabs--accept-p (tab)
  "Return non-nil when TAB passes `bookmark-gt-browser-tabs-filter'."
  (let ((filt bookmark-gt-browser-tabs-filter)
        (url (or (plist-get tab :url) "")))
    (cond
     ((null filt)      t)
     ((stringp filt)   (string-match-p filt url))
     ((functionp filt) (funcall filt tab))
     (t                t))))

;;;; Store

(defun bookmark-gt-browser-tabs--store (tab)
  "Store TAB (a browser-gt plist) as a temp browser-tab bookmark.
The name is the tab title, falling back to the URL.  The
owning browser's client name becomes a tag so it shows up in the
list buffer's Tags column and in the `;tag' particle filter.

Stores with NO-NOTIFY and NO-CURRENT set: a refresh writes many
records from a timer, so the list buffer is refreshed once by
the caller, and `bookmark-current-bookmark' — buffer-local, and
the default for several name prompts — is left alone in
whatever buffer the timer happened to run in.

Seeds `last-visited' from the tab's `:lastAccessed' field (JS
milliseconds since epoch) when present, so MRU sort in the jump
reader reflects the browser's own last-focused ordering.  Each
pre-jump refresh re-reads `:lastAccessed', so the timestamp
tracks browser activity rather than bookmark-gt jump history."
  (let* ((url (or (plist-get tab :url) ""))
         (title (or (plist-get tab :title) ""))
         (id (plist-get tab :id))
         (browser (plist-get tab :browser-gt-browser))
         (accessed-ms (plist-get tab :lastAccessed))
         (base (if (string-empty-p title) url title))
         (props (list (cons 'url url)
                      (cons 'browser-gt-id id)
                      (cons 'browser-gt-browser browser)
                      (cons bookmark-gt-temp-key t)
                      (cons bookmark-gt-browser-tabs--marker-key t))))
    (when (numberp accessed-ms)
      (push (cons 'last-visited
                  (time-convert (/ accessed-ms 1000.0) 'list))
            props))
    (when (and (stringp browser) (not (string-empty-p browser)))
      (push (cons 'tags (list browser)) props))
    (bookmark-gt-set-non-file base
                              'bookmark-gt-handler-url-jump
                              props
                              t t)))

(defun bookmark-gt-browser-tabs--clear ()
  "Remove every browser-gt-owned record from `bookmark-alist'.
Matches only records carrying the
`bookmark-gt-browser-tabs--marker-key' marker, so records
owned by other browser-gt-related packages are left alone."
  (setq bookmark-alist
        (seq-remove #'bookmark-gt-browser-tabs--own-record-p
                    bookmark-alist))
  (setq bookmark-alist-modification-count
        (1+ bookmark-alist-modification-count))
  (bookmark-gt-list-refresh))

;;;; Refresh

(defvar bookmark-gt-browser-tabs--refreshing nil
  "Non-nil while `bookmark-gt-browser-tabs-refresh' is running.
Prevents re-entrancy: the idle timer might fire while a manual
refresh (or the mode-on immediate refresh) is still in progress,
which would produce duplicate records.  A second refresh that
finds this flag set silently returns.")

;;;###autoload
(defun bookmark-gt-browser-tabs-refresh ()
  "Rebuild browser-tab bookmarks from live browser state.
Clears existing tab records, fetches the current tabs via
browser-gt, applies `bookmark-gt-browser-tabs-filter', and stores
one temp bookmark per surviving tab.  Guarded against
re-entrancy."
  (interactive)
  (if bookmark-gt-browser-tabs--refreshing
      (when (called-interactively-p 'interactive)
        (message "Browser-tab refresh already in progress; skipping"))
    (let ((bookmark-gt-browser-tabs--refreshing t)
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
        (bookmark-gt-browser-tabs--clear)
        (dolist (tab (bookmark-gt-browser-tabs--fetch))
          (let ((url (plist-get tab :url)))
            (when (and (stringp url) (not (string-empty-p url))
                       (bookmark-gt-browser-tabs--accept-p tab))
              (bookmark-gt-browser-tabs--store tab)
              (setq count (1+ count))))))
      (bookmark-gt-list-refresh)
      (message "Refreshed %d browser-tab bookmark(s)" count))))

;;;; Mode
;;
;; No idle timer.  The mode subscribes to browser-gt's
;; `browser-gt-client-connected-functions' and
;; `browser-gt-client-disconnected-functions' hooks and refreshes
;; whenever a browser connects or disconnects.  Bursts of events
;; (e.g. several tabs reloading at once) are coalesced through a
;; single debounce timer.  Explicit `g' in the list buffer and
;; `M-x bookmark-gt-browser-tabs-refresh' still work on demand.

(defvar bookmark-gt-browser-tabs-mode)

(defvar bookmark-gt-browser-tabs--debounce-timer nil
  "Pending debounce timer for a coalesced refresh, or nil.")

(defun bookmark-gt-browser-tabs--debounced-refresh ()
  "Timer callback: run the coalesced refresh.
Clears the debounce timer, then calls
`bookmark-gt-browser-tabs-refresh' if the mode is still on."
  (setq bookmark-gt-browser-tabs--debounce-timer nil)
  (when bookmark-gt-browser-tabs-mode
    (bookmark-gt-browser-tabs-refresh)))

(defun bookmark-gt-browser-tabs--schedule-refresh (&rest _)
  "Schedule a debounced refresh, coalescing bursts of client events.
Attached to `browser-gt-client-connected-functions' and
`browser-gt-client-disconnected-functions'; ignores its arguments,
which carry the client name.  When a refresh is already pending,
this call folds into it."
  (unless bookmark-gt-browser-tabs--debounce-timer
    (setq bookmark-gt-browser-tabs--debounce-timer
          (run-at-time bookmark-gt-browser-tabs-debounce nil
                       #'bookmark-gt-browser-tabs--debounced-refresh))))

(defun bookmark-gt-browser-tabs--cancel-debounce-timer ()
  "Cancel and forget any pending debounce timer."
  (when bookmark-gt-browser-tabs--debounce-timer
    (cancel-timer bookmark-gt-browser-tabs--debounce-timer)
    (setq bookmark-gt-browser-tabs--debounce-timer nil)))

;;;###autoload
(define-minor-mode bookmark-gt-browser-tabs-mode
  "Global minor mode that keeps browser-tab bookmarks in sync.

When enabled, subscribes to browser-gt's
`browser-gt-client-connected-functions' and
`browser-gt-client-disconnected-functions' hooks and refreshes
browser-tab bookmarks whenever a browser connects or disconnects.
Bursts of events within `bookmark-gt-browser-tabs-debounce'
seconds are coalesced into one refresh.  On mode-on, if any
browser is already connected, one refresh runs immediately;
otherwise the first refresh runs when a browser connects.

Also registers `bookmark-gt-browser-tabs-refresh' on
`bookmark-gt-jump-before-read-hook' so the jump reader sees
current tabs at each read.  Tab state can change faster than
connect/disconnect events fire, and each read pays only one
fetch+store.

Refreshes are also on-demand via `g' (revert) in the
`*Bookmarks-gt List*' buffer and `M-x
bookmark-gt-browser-tabs-refresh'.

Turning the mode off removes the connect/disconnect hooks and the
jump-before-read hook, cancels any pending debounced refresh,
and clears any tab records added by this mode from the alist —
only records with our own handler symbol; records from other
browser-gt-related packages are untouched.

Requires browser-gt to be installed.  Enable is a `user-error'
no-op when browser-gt is not loaded."
  :global t
  :group 'bookmark-gt
  (cond
   ((and bookmark-gt-browser-tabs-mode (not (featurep 'browser-gt)))
    (setq bookmark-gt-browser-tabs-mode nil)
    (user-error "Package `browser-gt' is not loaded"))
   (bookmark-gt-browser-tabs-mode
    (add-hook 'browser-gt-client-connected-functions
              #'bookmark-gt-browser-tabs--schedule-refresh)
    (add-hook 'browser-gt-client-disconnected-functions
              #'bookmark-gt-browser-tabs--schedule-refresh)
    (add-hook 'bookmark-gt-jump-before-read-hook
              #'bookmark-gt-browser-tabs-refresh)
    (when (browser-gt-connected-clients)
      (bookmark-gt-browser-tabs-refresh)))
   (t
    (remove-hook 'browser-gt-client-connected-functions
                 #'bookmark-gt-browser-tabs--schedule-refresh)
    (remove-hook 'browser-gt-client-disconnected-functions
                 #'bookmark-gt-browser-tabs--schedule-refresh)
    (remove-hook 'bookmark-gt-jump-before-read-hook
                 #'bookmark-gt-browser-tabs-refresh)
    (bookmark-gt-browser-tabs--cancel-debounce-timer)
    (bookmark-gt-browser-tabs--clear))))

(provide 'bookmark-gt-browser-tabs)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-browser-tabs.el ends here
