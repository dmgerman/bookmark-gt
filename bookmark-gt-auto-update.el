;;; bookmark-gt-auto-update.el --- Track and refresh bookmarks under editing  -*- lexical-binding: t; -*-

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
;; A bookmark carrying the `auto-update' alist property is refreshed
;; to the current point of the buffer visiting its file, on three
;; triggers:
;;
;;   - An idle timer firing every `bookmark-gt-auto-update-interval'
;;     seconds.
;;   - `kill-buffer-hook'         (catches "closing the file").
;;   - `window-state-change-hook' (catches "switching away").
;;
;; The refresh only runs while `bookmark-gt-auto-update-mode' is on.
;; The mode is off by default — enable it globally with
;; `(bookmark-gt-auto-update-mode 1)' or interactively.
;;
;; Per-bookmark toggle: `bookmark-gt-auto-update-toggle NAME'.  The
;; list buffer (`bookmark-gt-list-mode') shows a `^' glyph in its
;; dedicated column for any record with the property set, whether or
;; not the tracking timer is currently running.

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'bookmark-gt-core)

;;;; Customization

(defcustom bookmark-gt-auto-update-interval 60
  "Seconds of idle time between ticks of `bookmark-gt-auto-update-mode'."
  :type 'integer
  :group 'bookmark-gt)

(defcustom bookmark-gt-auto-update-preserve-fields
  '(handler tags annotation auto-update visits last-visited defaults)
  "Alist keys never overwritten during an auto-update refresh.
Every other field returned by the buffer's
`bookmark-make-record-function' replaces the bookmark's value."
  :type '(repeat symbol)
  :group 'bookmark-gt)

;;;; Predicate

(defun bookmark-gt-auto-update-p (record)
  "Return non-nil when RECORD carries the `auto-update' property."
  (bookmark-prop-get record 'auto-update))

;;;; Toggle

;;;###autoload
(defun bookmark-gt-auto-update-toggle (name)
  "Toggle the `auto-update' property on the bookmark called NAME.
Fires `bookmark-gt-set-after-hook' with the updated record so
the list buffer and any other observers refresh."
  (interactive
   (list (bookmark-completing-read "Toggle auto-update"
                                   (bookmark-gt-display-name
                                    (or bookmark-current-bookmark "")))))
  (let ((record (bookmark-get-bookmark name)))
    (unless record
      (user-error "No bookmark called %S" name))
    (let ((current (bookmark-gt-auto-update-p record)))
      (if current
          (setcdr record (assq-delete-all 'auto-update (cdr record)))
        (setcdr record (cons (cons 'auto-update t) (cdr record))))
      (run-hook-with-args 'bookmark-gt-set-after-hook record)
      (message "%s auto-update on %S"
               (if current "Disabled" "Enabled") name))))

;;;; Refresh

(defun bookmark-gt-auto-update--refresh (record buffer)
  "Refresh RECORD's position from BUFFER.
Calls BUFFER's `bookmark-make-record-function' so the update
uses the mode-appropriate recorder.  Every field in the fresh
record replaces the bookmark's value, except those listed in
`bookmark-gt-auto-update-preserve-fields'."
  (with-current-buffer buffer
    (let* ((raw (funcall bookmark-make-record-function))
           (fresh (if (stringp (car-safe raw)) (cdr raw) raw)))
      (dolist (cell fresh)
        (let ((field (car cell)))
          (unless (memq field bookmark-gt-auto-update-preserve-fields)
            (bookmark-prop-set (car record) field (cdr cell))))))))

(defun bookmark-gt-auto-update--buffer-for-record (record)
  "Return the live buffer visiting RECORD's file, or nil."
  (let ((file (bookmark-prop-get record 'filename)))
    (and file (find-buffer-visiting file))))

(defun bookmark-gt-auto-update-tick (&optional only-buffer)
  "Refresh every auto-update bookmark whose file is currently visited.
When ONLY-BUFFER is non-nil, restrict to records whose file
matches that buffer."
  (let ((target-file (and only-buffer (buffer-file-name only-buffer))))
    (dolist (record bookmark-alist)
      (when (bookmark-gt-auto-update-p record)
        (let ((buffer (if target-file
                          (and (equal (bookmark-prop-get record 'filename)
                                      target-file)
                               only-buffer)
                        (bookmark-gt-auto-update--buffer-for-record record))))
          (when (buffer-live-p buffer)
            (bookmark-gt-auto-update--refresh record buffer)))))))

;;;###autoload
(defun bookmark-gt-auto-update-now ()
  "Force an immediate refresh of every auto-update bookmark."
  (interactive)
  (bookmark-gt-auto-update-tick)
  (when (called-interactively-p 'interactive)
    (message "Auto-update bookmarks refreshed")))

;;;; Timer + hooks
;;
;; The timer is the one true piece of process-scoped state this
;; module owns.  Listed in ai/design/records-only-invariant.org
;; category 3 (resource handle held for teardown).

(defvar bookmark-gt-auto-update--timer nil
  "Idle timer object for `bookmark-gt-auto-update-mode'.
Held so it can be cancelled on mode-off.  Nil when the mode is
inactive.")

(defun bookmark-gt-auto-update--on-kill-buffer ()
  "Refresh any auto-update bookmark whose file is the buffer being killed."
  (when (buffer-file-name)
    (bookmark-gt-auto-update-tick (current-buffer))))

(defun bookmark-gt-auto-update--on-window-state-change ()
  "Refresh auto-update bookmarks for any buffer newly visible in a window."
  (bookmark-gt-auto-update-tick))

(defun bookmark-gt-auto-update--arm ()
  "Start the idle timer and register the trigger hooks."
  (unless bookmark-gt-auto-update--timer
    (setq bookmark-gt-auto-update--timer
          (run-with-idle-timer bookmark-gt-auto-update-interval
                               t #'bookmark-gt-auto-update-tick)))
  (add-hook 'kill-buffer-hook #'bookmark-gt-auto-update--on-kill-buffer)
  (add-hook 'window-state-change-hook
            #'bookmark-gt-auto-update--on-window-state-change))

(defun bookmark-gt-auto-update--disarm ()
  "Cancel the idle timer and remove the trigger hooks."
  (when bookmark-gt-auto-update--timer
    (cancel-timer bookmark-gt-auto-update--timer)
    (setq bookmark-gt-auto-update--timer nil))
  (remove-hook 'kill-buffer-hook #'bookmark-gt-auto-update--on-kill-buffer)
  (remove-hook 'window-state-change-hook
               #'bookmark-gt-auto-update--on-window-state-change))

;;;; Global mode

;;;###autoload
(define-minor-mode bookmark-gt-auto-update-mode
  "Global minor mode that keeps auto-update bookmarks current.

When enabled, an idle timer refreshes every bookmark carrying
the `auto-update' alist property to the current point of the
buffer visiting its file.  `kill-buffer' and
`window-state-change' catch closes and window switches so a
one-tick lag is not the difference between saving and losing
your last position.  The refresh is also registered into
`bookmark-gt-ephemeral-refresh-hook' so `g' in the list
buffer, opening the list, and opening the jump reader all
trigger a tick.

Turning the mode off cancels the timer, removes the hooks, and
unregisters the ephemeral refresher.  Bookmark records keep
their `auto-update' property; tracking just stops running.
Re-enable to resume."
  :global t
  :group 'bookmark-gt
  (cond
   (bookmark-gt-auto-update-mode
    (bookmark-gt-auto-update--arm)
    (add-hook 'bookmark-gt-ephemeral-refresh-hook
              #'bookmark-gt-auto-update-tick))
   (t
    (bookmark-gt-auto-update--disarm)
    (remove-hook 'bookmark-gt-ephemeral-refresh-hook
                 #'bookmark-gt-auto-update-tick))))

(provide 'bookmark-gt-auto-update)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-auto-update.el ends here
