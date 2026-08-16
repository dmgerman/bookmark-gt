;;; bookmark-gt-handlers.el --- Handler registry and non-file handlers  -*- lexical-binding: t; -*-

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
;; Handler registry (`bookmark-gt-handler-alist').  Flat alist
;; keyed by bookmark handler symbol; each entry is a plist with
;; `:type', `:name', `:face', `:narrow-char', `:doc'.  Multiple
;; handler symbols may share the same `:type' when they represent
;; the same kind of thing (e.g. our own URL handler and bookmark+'s
;; `bmkp-jump-url-browse' both map to :type url).
;;
;; Unknown handler symbols get a synthesized entry whose `:name'
;; is derived by stripping common bookmark-handler suffixes and
;; title-casing the leading segment — a bookmark saved by any
;; package that follows the standard `foo-bookmark-jump' /
;; `foo-bookmark-jump-handler' naming shows up with a sensible
;; type name without requiring the user to register anything.
;;
;; Also ships the URL handler bookmark-gt owns end-to-end
;; (`bookmark-gt-handler-url-jump' + `bookmark-gt-set-url').

;;; Code:

(require 'bookmark)
(require 'seq)
(require 'bookmark-gt-core)

;;;; Faces

(defface bookmark-gt-face-file
  '((t :inherit default))
  "Face for the Name column of file bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-url
  '((t :inherit link))
  "Face for the Name column of URL bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-eww
  '((t :inherit link))
  "Face for the Name column of EWW bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-dired
  '((t :inherit font-lock-function-name-face))
  "Face for the Name column of Dired bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-info
  '((t :inherit font-lock-doc-face))
  "Face for the Name column of Info bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-org
  '((t :inherit font-lock-keyword-face))
  "Face for the Name column of Org-heading bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-pdf
  '((t :inherit default))
  "Face for the Name column of PDF bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-function
  '((t :inherit font-lock-function-name-face))
  "Face for the Name column of function bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-sequence
  '((t :inherit font-lock-preprocessor-face))
  "Face for the Name column of sequence bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-view
  '((t :inherit font-lock-builtin-face))
  "Face for the Name column of view bookmarks."
  :group 'bookmark-gt)

(defface bookmark-gt-face-group
  '((t :inherit font-lock-type-face))
  "Face for the Group column in the bookmark list."
  :group 'bookmark-gt)

(defface bookmark-gt-face-missing-file
  '((t :strike-through t :inherit shadow))
  "Face for bookmarks whose `filename' does not exist on disk.
Combined with the type-specific face at render time — applied
as a `face-list' on the Name column so both the type color and
the strikethrough are visible."
  :group 'bookmark-gt)

(defface bookmark-gt-face-temp
  '((t :inherit outline-3))
  "Face applied to the whole row of temporary bookmarks.
Inherits `outline-3' — a theme-defined face that gives temp
records a distinguishable but calm appearance."
  :group 'bookmark-gt)

;;;; Group registry
;;
;; Groups sit above types.  Multiple types can share a group so a
;; user filters/narrows by an aggregate category (web = url + eww
;; + browser-tab) rather than one type at a time.  Groups are
;; DERIVED from the handler registry — nothing is stored on the
;; record — so the group of a record can change if the user re-
;; classifies a handler entry, and nothing lives on disk that
;; would go stale.
;;
;; The `other' group is the catch-all: any handler-registry entry
;; without an explicit `:group', or any handler symbol resolved
;; via the derive-fallback, buckets under it.

(defvar bookmark-gt-group-alist nil
  "Registry mapping group symbols to display metadata.
Each element is (GROUP . PLIST) where PLIST carries `:name',
`:narrow-char', and `:doc'.  Populated by
`bookmark-gt-group-register' calls in this file and by user
extensions.  Consulted for the list buffer's Group column, the
`by-group' filter, and the consult narrow rows.")

(defun bookmark-gt-group-register (group plist)
  "Register GROUP with display PLIST.
Idempotent — a repeat registration replaces the previous entry."
  (setq bookmark-gt-group-alist
        (cons (cons group plist)
              (assq-delete-all group bookmark-gt-group-alist))))

(defun bookmark-gt-group-name (group)
  "Return the display name for GROUP.
Falls back to the symbol's name (capitalized) when GROUP is not
registered."
  (or (plist-get (alist-get group bookmark-gt-group-alist) :name)
      (and group (capitalize (symbol-name group)))))

(defun bookmark-gt-group-narrow-char (group)
  "Return the narrow character for GROUP, or the first char of its name."
  (or (plist-get (alist-get group bookmark-gt-group-alist) :narrow-char)
      (aref (downcase (bookmark-gt-group-name group)) 0)))

;; Built-in groups.  Narrow chars are chosen distinct so consult's
;; group-narrow menu is unambiguous.
(bookmark-gt-group-register
 'web '(:name "Web" :narrow-char ?w
        :doc "URL / EWW / browser-tab bookmarks."))

(bookmark-gt-group-register
 'file '(:name "File" :narrow-char ?f
         :doc "Filesystem-backed bookmarks (files, directories)."))

(bookmark-gt-group-register
 'doc '(:name "Doc" :narrow-char ?d
        :doc "Documentation and reading (Info, Org, PDF, EPUB, Help)."))

(bookmark-gt-group-register
 'code '(:name "Code" :narrow-char ?c
         :doc "Development-tool bookmarks (Magit, etc.)."))

(bookmark-gt-group-register
 'media '(:name "Media" :narrow-char ?m
          :doc "Image / audio / video bookmarks."))

(bookmark-gt-group-register
 'other '(:name "Other" :narrow-char ?o
          :doc "Bookmarks whose handler is unregistered or unclassified."))

;;;; Registry

(defvar bookmark-gt-handler-alist nil
  "Registry mapping handler symbols to display metadata.
Each element is (HANDLER . PLIST) where PLIST carries:

  :type        symbol identifying the type.
  :name        display string.
  :group       group symbol (see `bookmark-gt-group-alist').
  :face        face for the Name column.
  :narrow-char char (rarely consulted directly; consult narrow
               uses the GROUP's narrow-char instead).
  :doc         one-line explanation.
  :preview     optional — a function called with the record to
               preview the bookmark, invoked by
               `bookmark-gt-list-preview' inside
               `save-selected-window'.  When absent, preview
               falls back to `bookmark-jump-other-window' via
               the record's own handler.

Populated by `bookmark-gt-handler-register' calls in this file
and by user extensions.

HANDLER may be nil (matches built-in file+position records that
carry no `handler' property).")

(defun bookmark-gt-handler-register (handlers plist)
  "Register each symbol in HANDLERS as sharing display PLIST.
Idempotent — a repeat registration for the same handler symbol
replaces the previous entry.  HANDLERS is a list; PLIST is
shared by reference across all registered handlers."
  (dolist (h handlers)
    (setq bookmark-gt-handler-alist
          (cons (cons h plist)
                (assq-delete-all h bookmark-gt-handler-alist)))))

;;;; Derive-entry fallback

(defconst bookmark-gt-handler--suffix-strip-re
  (rx (or "-bookmark-jump-handler"
          "-bookmark-jump"
          "-jump-handler"
          "--handle-bookmark"
          "-handle-bookmark")
      eos)
  "Regexp of bookmark-handler naming-convention suffixes.
Stripped from an unknown HANDLER symbol before deriving a type
name — so `magit--handle-bookmark' becomes `magit', and
`nov-bookmark-jump-handler' becomes `nov'.")

(defun bookmark-gt--handler-derive-entry (handler)
  "Synthesize a registry entry for an unknown HANDLER symbol.
The `:name' is derived by stripping bookmark-handler suffixes
from the symbol name and title-casing the leading segment.
`:type' is the derived name interned as a lowercase symbol.
`:face' falls back to `default'."
  (let* ((raw (if handler (symbol-name handler) ""))
         (stripped (replace-regexp-in-string
                    bookmark-gt-handler--suffix-strip-re "" raw))
         (leading (car (split-string stripped "-")))
         (name (if (string-empty-p leading) "Unknown" (capitalize leading))))
    (cons handler
          (list :type (intern (downcase name))
                :name name
                :face 'default
                :narrow-char (if (string-empty-p leading)
                                 ?\s
                               (aref (downcase leading) 0))
                :doc "Auto-detected type."))))

;;;; Lookup

(defun bookmark-gt-handler-classify (record)
  "Return the registry entry for RECORD's handler.
Returns an (HANDLER . PLIST) cons — either a registered entry
or one synthesized by `bookmark-gt--handler-derive-entry'.
Never returns nil."
  (let ((h (bookmark-prop-get record 'handler)))
    (or (assq h bookmark-gt-handler-alist)
        (bookmark-gt--handler-derive-entry h))))

(defun bookmark-gt-handler-type (record)
  "Return the registered `:type' symbol for RECORD."
  (plist-get (cdr (bookmark-gt-handler-classify record)) :type))

(defun bookmark-gt-handler-name (record)
  "Return the display name for RECORD's type."
  (plist-get (cdr (bookmark-gt-handler-classify record)) :name))

(defun bookmark-gt-handler-face (record)
  "Return the display face for RECORD's type, or nil."
  (plist-get (cdr (bookmark-gt-handler-classify record)) :face))

(defun bookmark-gt-handler-group (record)
  "Return RECORD's group symbol.
Reads the `:group' key from the handler registry entry; falls
back to `other' when the entry has no `:group' or when the
handler is unknown (derive-fallback)."
  (or (plist-get (cdr (bookmark-gt-handler-classify record)) :group)
      'other))

;;;; Type-based predicates
;;
;; These check `:type', which is stable across handler-symbol
;; aliases.  A record from bookmark+'s `bmkp-jump-url-browse'
;; still satisfies `bookmark-gt-handler-url-p' because both map
;; to :type url.

(defun bookmark-gt-handler-file-p (record)
  "Return non-nil when RECORD is a file+position bookmark."
  (eq (bookmark-gt-handler-type record) 'file))

(defun bookmark-gt-handler-url-p (record)
  "Return non-nil when RECORD is a URL bookmark."
  (eq (bookmark-gt-handler-type record) 'url))

(defun bookmark-gt-handler-eww-p (record)
  "Return non-nil when RECORD was created by EWW."
  (eq (bookmark-gt-handler-type record) 'eww))

(defun bookmark-gt-handler-dired-p (record)
  "Return non-nil when RECORD was created by Dired."
  (eq (bookmark-gt-handler-type record) 'dired))

(defun bookmark-gt-handler-info-p (record)
  "Return non-nil when RECORD was created by Info."
  (eq (bookmark-gt-handler-type record) 'info))

(defun bookmark-gt-handler-org-p (record)
  "Return non-nil when RECORD is an Org bookmark."
  (eq (bookmark-gt-handler-type record) 'org))

(defun bookmark-gt-handler-pdf-p (record)
  "Return non-nil when RECORD is a pdf-tools bookmark."
  (eq (bookmark-gt-handler-type record) 'pdf))

(defun bookmark-gt-handler-browser-tab-p (record)
  "Return non-nil when RECORD is any kind of browser-tab bookmark."
  (eq (bookmark-gt-handler-type record) 'browser-tab))

(defun bookmark-gt-handler-magit-p (record)
  "Return non-nil when RECORD was created by Magit."
  (eq (bookmark-gt-handler-type record) 'magit))

(defun bookmark-gt-handler-help-p (record)
  "Return non-nil when RECORD was created by Help mode."
  (eq (bookmark-gt-handler-type record) 'help))

(defun bookmark-gt-handler-image-p (record)
  "Return non-nil when RECORD is an image bookmark."
  (eq (bookmark-gt-handler-type record) 'image))

(defun bookmark-gt-handler-epub-p (record)
  "Return non-nil when RECORD is an EPUB (`nov') bookmark."
  (eq (bookmark-gt-handler-type record) 'epub))

(defun bookmark-gt-handler-function-p (record)
  "Return non-nil when RECORD is a function bookmark."
  (eq (bookmark-gt-handler-type record) 'function))

(defun bookmark-gt-handler-sequence-p (record)
  "Return non-nil when RECORD is a sequence bookmark."
  (eq (bookmark-gt-handler-type record) 'sequence))

(defun bookmark-gt-handler-view-p (record)
  "Return non-nil when RECORD is a saved view of the list buffer.
The type symbol on the record is `bookmark-gt-view' — namespaced
to avoid colliding with any third-party `view' type — but the
predicate is unqualified for discoverability."
  (eq (bookmark-gt-handler-type record) 'bookmark-gt-view))

;;;; Dired handler — bookmark-gt owns this one end-to-end
;;
;; The built-in Emacs's `dired.el' does not ship a bookmark handler;
;; Dired bookmarks are a bookmark+ invention.  This module ships
;; its own handler and captures the same state bookmark+ does,
;; using the same alist keys and the same dired primitives
;; (`dired-remember-marks', `dired-remember-hidden',
;; `dired-mark-remembered'), so records interchange on disk:
;;
;;   `dired-directory'   Original `dired-directory' value — a
;;                       string (plain path or wildcard), a
;;                       (dirname . files) list, or a directory
;;                       list.  Preferred on jump over `filename'.
;;   `dired-marked'      Alist of (ABSOLUTE-FILENAME . MARK-CHAR)
;;                       for lines whose mark is not space.
;;   `dired-subdirs'     Inserted subdirectories (top excluded).
;;                       Shape is a list of singleton lists
;;                       ((DIR) (DIR) ...) — what bookmark+ writes
;;                       and what `dired-insert-old-subdirs' reads.
;;   `dired-hidden-dirs' Currently hidden subdirectories.
;;   `dired-switches'    Value of `dired-actual-switches'.
;;
;; Two keys are bookmark-gt's own — bookmark+ does not record
;; them and reopens virtual-dired buffers as real dired, which
;; fails when the source is not a real directory:
;;
;;   `dired-virtual'     t when set from a virtual-dired buffer
;;                       (detected via `revert-buffer-function'
;;                       bound to `dired-virtual-revert').
;;   `dired-listing'     For virtual dired only: the buffer's
;;                       exact textual listing, captured with
;;                       `buffer-string' and inlined in the
;;                       record.  Restored on jump with
;;                       `dired-virtual'.  Capped by
;;                       `bookmark-gt-dired-virtual-max-size'.

(defvar dired-actual-switches)
(defvar dired-subdir-alist)
(declare-function dired "dired" (dirname &optional switches))
(declare-function dired-mode "dired" (&optional dirname switches))
(declare-function dired-get-filename "dired"
                  (&optional localp no-error-if-not-filep))
(declare-function dired-goto-file "dired" (file))
(declare-function dired-goto-subdir "dired-aux" (dir))
(declare-function dired-hide-subdir "dired-aux" (arg))
(declare-function dired-maybe-insert-subdir "dired-aux"
                  (dirname &optional switches no-error-if-not-dir-p))
(declare-function dired-subdir-hidden-p "dired" (dir))
(declare-function dired-revert "dired" (&optional arg noconfirm))
(declare-function dired-virtual "dired-x" (dirname &optional switches))
(declare-function dired-remember-marks "dired" (beg end))
(declare-function dired-mark-remembered "dired" (target))
(declare-function dired-remember-hidden "dired" ())
(declare-function dired-insert-old-subdirs "dired" (old-subdir-alist))

(defcustom bookmark-gt-dired-virtual-max-size 524288
  "Maximum size, in bytes, of a virtual-dired buffer to inline in a bookmark.
Setting a bookmark from a `dired-virtual-mode' buffer captures
the buffer's textual listing under the `dired-listing' key so
the jump handler can recreate the buffer exactly.  When the
listing exceeds this limit, `bookmark-gt-set' signals a
`user-error' rather than embedding a large payload in the
bookmark file — raise this value to allow the bookmark, or
lower it to be more conservative.  The bookmark file is
loaded whole at startup and rewritten whole on every save, so
listings scale that cost with them."
  :type 'natnum
  :group 'bookmark-gt)

(defun bookmark-gt--dired-remember-marks ()
  "Return alist of (ABSOLUTE-FILENAME . MARK-CHAR) for the current Dired buffer.
Shape is what `dired-remember-marks' returns.  Matches the format
that bookmark+ writes so records interchange on disk."
  (dired-remember-marks (point-min) (point-max)))

(defun bookmark-gt--dired-collect-inserted-subdirs ()
  "Return the inserted subdirectories of the current Dired buffer.
Excludes the top-level directory (the last entry of
`dired-subdir-alist').  Each element is a singleton list (DIR)
— the same shape bookmark+ writes under `dired-subdirs' and
that `dired-insert-old-subdirs' consumes on restore."
  (when (bound-and-true-p dired-subdir-alist)
    (mapcar (lambda (entry) (list (car entry)))
            (cdr (reverse dired-subdir-alist)))))

(defun bookmark-gt--dired-collect-hidden-subdirs ()
  "Return the hidden subdirectories of the current Dired buffer.
Delegates to `dired-remember-hidden' — same shape bookmark+
records under `dired-hidden-dirs'."
  (require 'dired-aux)
  (when (fboundp 'dired-remember-hidden)
    (save-excursion (dired-remember-hidden))))

(defun bookmark-gt--dired-collect-state ()
  "Return an alist of Dired state to splice into a bookmark record.
Assumes the current buffer is in `dired-mode' (or a derived mode).
Values that are nil/empty are omitted so records stay minimal.
For a `dired-virtual-mode' buffer, also captures the raw
listing under `dired-listing' so `dired-virtual' can rebuild
the buffer on jump.  Signals `user-error' when that listing
exceeds `bookmark-gt-dired-virtual-max-size'."
  (require 'dired)
  (let* ((dir dired-directory)
         (marks (bookmark-gt--dired-remember-marks))
         (subdirs (bookmark-gt--dired-collect-inserted-subdirs))
         (hidden (bookmark-gt--dired-collect-hidden-subdirs))
         (switches dired-actual-switches)
         ;; `dired-virtual' does not derive a distinct major mode
         ;; from `dired-mode' — the only reliable buffer-local
         ;; signal it leaves is `revert-buffer-function' bound to
         ;; `dired-virtual-revert'.
         (virtual (eq revert-buffer-function 'dired-virtual-revert))
         (listing (when virtual (buffer-string)))
         (out nil))
    (when (and listing
               (> (string-bytes listing)
                  bookmark-gt-dired-virtual-max-size))
      (user-error
       "Virtual-dired listing is %d bytes; exceeds `bookmark-gt-dired-virtual-max-size' (%d).  Raise the cap or skip"
       (string-bytes listing)
       bookmark-gt-dired-virtual-max-size))
    (when dir       (push (cons 'dired-directory dir) out))
    (when marks     (push (cons 'dired-marked marks) out))
    (when subdirs   (push (cons 'dired-subdirs subdirs) out))
    (when hidden    (push (cons 'dired-hidden-dirs hidden) out))
    (when switches  (push (cons 'dired-switches switches) out))
    (when virtual   (push (cons 'dired-virtual t) out))
    (when listing   (push (cons 'dired-listing listing) out))
    (nreverse out)))

(defun bookmark-gt--dired-target (bookmark)
  "Return the Dired target for BOOKMARK.
Prefers the `dired-directory' alist entry so wildcard and
explicit-file-list forms round-trip; falls back to `filename'."
  (let ((dd (bookmark-prop-get bookmark 'dired-directory)))
    (or dd (bookmark-gt-filename-of bookmark))))

(defun bookmark-gt--dired-target-exists-p (target)
  "Return non-nil when TARGET is a form `dired' can open."
  (cond
   ((stringp target)
    (or (file-directory-p target)
        ;; Wildcard: parent dir exists and target contains a glob char.
        (and (string-match-p "[[*?]" target)
             (file-directory-p (file-name-directory target)))))
   ((consp target)
    ;; Explicit-file-list form: (dirname . files) or (dirname file...).
    (let ((base (if (stringp (car target)) (car target) nil)))
      (or (null base) (file-directory-p base))))
   (t nil)))

(defun bookmark-gt--dired-mark-remembered (alist)
  "Mark files in the current Dired buffer per ALIST.
ALIST is the shape returned by `dired-remember-marks': entries
of (ABSOLUTE-FILENAME . MARK-CHAR).  Delegates to
`dired-mark-remembered' — the same primitive bookmark+ uses on
jump, so any record that bookmark+ can restore, we can too."
  (dired-mark-remembered alist))

(defun bookmark-gt--dired-restore-virtual (bookmark target switches marks)
  "Restore a virtual-dired BOOKMARK into a fresh buffer.
TARGET, SWITCHES, MARKS are the recorded values.  Uses the
inlined `dired-listing' when present; otherwise falls back to a
real `dired' when TARGET is an existing directory, else errors."
  (let ((listing (bookmark-prop-get bookmark 'dired-listing)))
    (cond
     (listing
      (require 'dired-x)
      (let* ((dir (cond ((stringp target) target)
                        ((and (consp target) (stringp (car target)))
                         (car target))
                        (t default-directory)))
             (buf (get-buffer-create
                   (format "*Dired-virtual: %s*"
                           (abbreviate-file-name dir)))))
        (pop-to-buffer-same-window buf)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert listing))
        (goto-char (point-min))
        (dired-virtual (or dir default-directory) switches)
        (when marks
          (let ((inhibit-read-only t))
            (bookmark-gt--dired-mark-remembered marks)))))
     ((and (stringp target) (file-directory-p target))
      (if switches (dired target switches) (dired target))
      (when marks
        (let ((inhibit-read-only t))
          (bookmark-gt--dired-mark-remembered marks))))
     (t
      (user-error
       "Virtual-dired bookmark has no inlined listing and target is unavailable: %S"
       target)))))

(defun bookmark-gt-handler-dired-jump (bookmark)
  "Bookmark handler for Dired bookmarks.
Opens the directory recorded in BOOKMARK (from `dired-directory'
when present, else `filename') via `dired'.  Then restores the
recorded ls switches, inserted subdirectories, hidden
subdirectories, and file marks — matching the state that was
captured when the bookmark was set.  Bookmarks set from
`dired-virtual-mode' are recreated from the inlined
`dired-listing' when present."
  (require 'dired)
  (let* ((target (bookmark-gt--dired-target bookmark))
         (switches (bookmark-prop-get bookmark 'dired-switches))
         (subdirs (bookmark-prop-get bookmark 'dired-subdirs))
         (hidden (bookmark-prop-get bookmark 'dired-hidden-dirs))
         (marks (bookmark-prop-get bookmark 'dired-marked))
         (virtual (bookmark-prop-get bookmark 'dired-virtual)))
    (unless target
      (user-error "Dired bookmark has no `dired-directory' or `filename'"))
    (cond
     (virtual
      (bookmark-gt--dired-restore-virtual bookmark target switches marks))
     (t
      (unless (bookmark-gt--dired-target-exists-p target)
        (user-error "Dired bookmark's target does not exist: %S" target))
      (if switches (dired target switches) (dired target))
      (let ((inhibit-read-only t))
        (when subdirs
          (require 'dired-aux)
          (dired-insert-old-subdirs subdirs))
        (dolist (sub hidden)
          (when (ignore-errors (dired-goto-subdir sub))
            (ignore-errors (dired-hide-subdir 1))))
        (when marks
          (bookmark-gt--dired-mark-remembered marks)))))))

;;;; URL handler — bookmark-gt owns this one end-to-end

(defun bookmark-gt-handler-url-jump (bookmark)
  "Bookmark handler for URL bookmark BOOKMARK.
Opens the URL via `browse-url' and throws
`bookmark-gt-skip-post-handler' to suppress the built-in
post-jump popup."
  (let ((url (bookmark-gt-url-of bookmark)))
    (unless url
      (user-error "URL bookmark has no `url' or `location' property"))
    (browse-url url)
    (bookmark-gt-record-visit bookmark)
    (bookmark-gt-skip-post-handler 'url)))

;;;###autoload
(defun bookmark-gt-set-url (url &optional name tags)
  "Store a URL bookmark for URL under NAME.
Interactive: prompts for URL (defaulting to any URL at point)
and NAME (defaulting to URL).  TAGS is an optional initial tag
list; when omitted, the tag-reader hook decides.

Returns the stored (NAME . DATA) pair."
  (interactive
   (let* ((default-url (or (thing-at-point 'url t) ""))
          (url (read-string
                (format-prompt "URL" default-url) nil nil default-url))
          (name (read-string
                 (format-prompt "Bookmark name" url) nil nil url)))
     (list url name nil)))
  (let ((props (list (cons 'url url))))
    (when tags
      (push (cons 'tags tags) props))
    (bookmark-gt-set-non-file (or name url)
                              'bookmark-gt-handler-url-jump
                              props)))

;;;; Built-in registrations

;; File — built-in no-handler and the explicit default handler both map here.
(bookmark-gt-handler-register
 '(nil bookmark-default-handler)
 (list :type 'file :name "File" :group 'file
       :face 'bookmark-gt-face-file :narrow-char ?f
       :doc "Standard file+position bookmark."))

;; URL — our own handler plus bookmark+'s URL variants.
(bookmark-gt-handler-register
 '(bookmark-gt-handler-url-jump
   bmkp-jump-url-browse
   bmkp-jump-url-browse-other-window)
 (list :type 'url :name "URL" :group 'web
       :face 'bookmark-gt-face-url :narrow-char ?u
       :doc "Web URL opened with `browse-url'."))

;; EWW.
(bookmark-gt-handler-register
 '(eww-bookmark-jump)
 (list :type 'eww :name "EWW" :group 'web
       :face 'bookmark-gt-face-eww :narrow-char ?e
       :doc "Page bookmarked from EWW."))

;; Dired — our own handler (canonical, works without bookmark+)
;; plus aliases for records still carrying bookmark+ / built-in
;; symbols so historic files classify correctly during migration.
(bookmark-gt-handler-register
 '(bookmark-gt-handler-dired-jump
   dired-bookmark-jump
   bmkp-jump-dired)
 (list :type 'dired :name "Dired" :group 'file
       :face 'bookmark-gt-face-dired :narrow-char ?d
       :doc "Directory bookmarked from Dired."))

;; Info.
(bookmark-gt-handler-register
 '(Info-bookmark-jump)
 (list :type 'info :name "Info" :group 'doc
       :face 'bookmark-gt-face-info :narrow-char ?i
       :doc "Node bookmarked from Info."))

;; Org — three variants ship in Emacs and org-mode.
(bookmark-gt-handler-register
 '(org-bookmark-jump
   org-bookmark-heading-jump
   org-agenda-bookmark-jump)
 (list :type 'org :name "Org" :group 'doc
       :face 'bookmark-gt-face-org :narrow-char ?o
       :doc "Heading or item bookmarked from Org mode."))

;; PDF.
(bookmark-gt-handler-register
 '(pdf-view-bookmark-jump-handler)
 (list :type 'pdf :name "PDF" :group 'doc
       :face 'bookmark-gt-face-pdf :narrow-char ?p
       :doc "Location bookmarked from pdf-tools."))

;; Browser tab — our own handler plus the two ecosystem variants
;; (old bookmark-plus-gt and browsel-tab-manager).  Note: type
;; membership does NOT imply cleanup ownership; the browsel-tabs
;; module clears only records whose handler is its OWN symbol.
(bookmark-gt-handler-register
 '(bmkp-gt-browsel-tabs-jump
   browsel-tab-manager-bookmark-jump)
 (list :type 'browser-tab :name "BrowserTab" :group 'web
       :face 'bookmark-gt-face-url :narrow-char ?b
       :doc "Browser tab bookmarked from browsel or its ecosystem."))

;; Third-party types worth showing by default (all follow the
;; standard naming convention, so the derive fallback would also
;; work — but explicit registration lets us pick a stable
;; `:narrow-char' and a nicer name).
(bookmark-gt-handler-register
 '(magit--handle-bookmark)
 (list :type 'magit :name "Magit" :group 'code
       :face 'bookmark-gt-face-file :narrow-char ?m
       :doc "State bookmarked from Magit."))

(bookmark-gt-handler-register
 '(help-bookmark-jump)
 (list :type 'help :name "Help" :group 'doc
       :face 'bookmark-gt-face-file :narrow-char ?h
       :doc "*Help* page bookmark."))

(bookmark-gt-handler-register
 '(image-bookmark-jump)
 (list :type 'image :name "Image" :group 'media
       :face 'bookmark-gt-face-file :narrow-char ?I
       :doc "Location bookmarked from image-mode."))

(bookmark-gt-handler-register
 '(nov-bookmark-jump-handler)
 (list :type 'epub :name "EPUB" :group 'doc
       :face 'bookmark-gt-face-file :narrow-char ?E
       :doc "Location bookmarked from nov.el."))

;; Function bookmarks — bookmark-gt owns both the handler and
;; the setter.  bookmark+'s aliases would go here if we chose
;; to migrate historic records.
(bookmark-gt-handler-register
 '(bookmark-gt-handler-function-jump)
 (list :type 'function :name "Function" :group 'other
       :face 'bookmark-gt-face-function :narrow-char ?F
       :doc "Bookmark that calls a function on jump."))

;; Sequence bookmarks — jump each of a list of bookmarks in order.
(bookmark-gt-handler-register
 '(bookmark-gt-handler-sequence-jump)
 (list :type 'sequence :name "Sequence" :group 'other
       :face 'bookmark-gt-face-sequence :narrow-char ?Q
       :doc "Bookmark that jumps each of a list of bookmarks in order."))

;;;; Function bookmarks — jump runs an arbitrary callable

(defun bookmark-gt-handler-function-jump (bookmark)
  "Bookmark handler for function bookmark BOOKMARK.
Runs the record's `function' prop (a symbol or lambda) and
throws `bookmark-gt-skip-post-handler'."
  (let ((fn (bookmark-prop-get bookmark 'function)))
    (unless fn
      (user-error "Function bookmark has no `function' property"))
    (unless (functionp fn)
      (user-error "Function bookmark's `function' is not callable: %S" fn))
    (funcall fn)
    (bookmark-gt-record-visit bookmark)
    (bookmark-gt-skip-post-handler 'function)))

;;;###autoload
(defun bookmark-gt-set-function (name fn &optional tags)
  "Store a function bookmark called NAME whose jump invokes FN.
Interactive: prompts for NAME and a command via `read-command'.
FN is any callable (a symbol or lambda).  TAGS is an optional
initial tag list; when omitted, the tag-reader hook decides.

Returns the stored (NAME . DATA) pair."
  (interactive
   (list (read-string "Function bookmark name: ")
         (read-command "Function to call on jump: ")
         nil))
  (let ((props (list (cons 'function fn))))
    (when tags
      (push (cons 'tags tags) props))
    (bookmark-gt-set-non-file
     name 'bookmark-gt-handler-function-jump props)))

;;;; Sequence bookmarks — jump each of a list of bookmarks in order

(defun bookmark-gt-handler-sequence-jump (bookmark)
  "Bookmark handler for sequence bookmark BOOKMARK.
Jump to each name in the record's `sequence' prop in order,
then throw `bookmark-gt-skip-post-handler'."
  (let ((names (bookmark-prop-get bookmark 'sequence)))
    (unless (listp names)
      (user-error "Sequence bookmark's `sequence' is not a list"))
    (dolist (name names)
      (bookmark-jump name))
    (bookmark-gt-record-visit bookmark)
    (bookmark-gt-skip-post-handler 'sequence)))

;;;###autoload
(defun bookmark-gt-set-sequence (name bookmarks &optional tags)
  "Store a sequence bookmark called NAME that jumps BOOKMARKS in order.
Interactive: prompts for NAME then reads bookmark names one at
a time (empty input ends the list).  BOOKMARKS must be a
non-empty list of existing bookmark names.  TAGS is an
optional initial tag list; when omitted, the tag-reader hook
decides.

Returns the stored (NAME . DATA) pair."
  (interactive
   (list (read-string "Sequence bookmark name: ")
         (let (seq
               (done nil))
           (while (not done)
             (let ((b (bookmark-completing-read
                       (if seq
                           (format "Add bookmark (empty to finish; %d so far)"
                                   (length seq))
                         "First bookmark"))))
               (if (or (null b) (string-empty-p b))
                   (setq done t)
                 (push b seq))))
           (nreverse seq))
         nil))
  (unless bookmarks
    (user-error "Sequence bookmark needs at least one bookmark"))
  (let ((props (list (cons 'sequence bookmarks))))
    (when tags
      (push (cons 'tags tags) props))
    (bookmark-gt-set-non-file
     name 'bookmark-gt-handler-sequence-jump props)))

(provide 'bookmark-gt-handlers)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-handlers.el ends here
