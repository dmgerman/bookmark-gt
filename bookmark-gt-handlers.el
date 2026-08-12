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

;;;; Registry

(defvar bookmark-gt-handler-alist nil
  "Registry mapping handler symbols to display metadata.
Each element is (HANDLER . PLIST) where PLIST carries `:type',
`:name', `:face', `:narrow-char', and `:doc' keys.  Populated
by `bookmark-gt-handler-register' calls in this file and by
user extensions.

HANDLER may be nil (matches vanilla file+position records that
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

;;;; Dired handler — bookmark-gt owns this one end-to-end
;;
;; Vanilla Emacs's `dired.el' does not ship a bookmark handler;
;; Dired bookmarks are a bookmark+ invention.  To let users
;; migrate off bookmark+ without breaking their existing Dired
;; records, this module ships its own trivial handler that just
;; opens the record's `filename' in Dired.  It ignores the
;; bookmark+-specific alist keys (`dired-marked', `dired-subdirs',
;; `dired-hidden-dirs', `dired-switches') — those preserved
;; state features can come back later if wanted; the primary
;; contract (\"open the directory\") is honored.

(defun bookmark-gt-handler-dired-jump (bookmark)
  "Vanilla-compatible bookmark handler for Dired bookmarks.
Opens BOOKMARK's `filename' (a directory) via `dired'."
  (require 'dired)
  (let ((dir (bookmark-gt-filename-of bookmark)))
    (unless dir
      (user-error "Dired bookmark has no `filename' property"))
    (unless (file-directory-p dir)
      (user-error "Dired bookmark's `filename' is not a directory: %s" dir))
    (dired dir)))

;;;; URL handler — bookmark-gt owns this one end-to-end

(defun bookmark-gt-handler-url-jump (bookmark)
  "Vanilla-compatible bookmark handler for URL bookmarks.
BOOKMARK is a bookmark record.  Opens the record's URL (read
via `bookmark-gt-url-of', which accepts either the `url' or
`location' prop for bookmark+ compat) with `browse-url'."
  (let ((url (bookmark-gt-url-of bookmark)))
    (unless url
      (user-error "URL bookmark has no `url' or `location' property"))
    (browse-url url)))

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

;; File — vanilla no-handler and the explicit default handler both map here.
(bookmark-gt-handler-register
 '(nil bookmark-default-handler)
 (list :type 'file :name "File"
       :face 'bookmark-gt-face-file :narrow-char ?f
       :doc "Standard file+position bookmark."))

;; URL — our own handler plus bookmark+'s URL variants.
(bookmark-gt-handler-register
 '(bookmark-gt-handler-url-jump
   bmkp-jump-url-browse
   bmkp-jump-url-browse-other-window)
 (list :type 'url :name "URL"
       :face 'bookmark-gt-face-url :narrow-char ?u
       :doc "Web URL opened with `browse-url'."))

;; EWW.
(bookmark-gt-handler-register
 '(eww-bookmark-jump)
 (list :type 'eww :name "EWW"
       :face 'bookmark-gt-face-eww :narrow-char ?e
       :doc "Page bookmarked from EWW."))

;; Dired — our own handler (canonical, works without bookmark+)
;; plus aliases for records still carrying bookmark+ / vanilla
;; symbols so historic files classify correctly during migration.
(bookmark-gt-handler-register
 '(bookmark-gt-handler-dired-jump
   dired-bookmark-jump
   bmkp-jump-dired)
 (list :type 'dired :name "Dired"
       :face 'bookmark-gt-face-dired :narrow-char ?d
       :doc "Directory bookmarked from Dired."))

;; Info.
(bookmark-gt-handler-register
 '(Info-bookmark-jump)
 (list :type 'info :name "Info"
       :face 'bookmark-gt-face-info :narrow-char ?i
       :doc "Node bookmarked from Info."))

;; Org — three variants ship in Emacs and org-mode.
(bookmark-gt-handler-register
 '(org-bookmark-jump
   org-bookmark-heading-jump
   org-agenda-bookmark-jump)
 (list :type 'org :name "Org"
       :face 'bookmark-gt-face-org :narrow-char ?o
       :doc "Heading or item bookmarked from Org mode."))

;; PDF.
(bookmark-gt-handler-register
 '(pdf-view-bookmark-jump-handler)
 (list :type 'pdf :name "PDF"
       :face 'bookmark-gt-face-pdf :narrow-char ?p
       :doc "Location bookmarked from pdf-tools."))

;; Browser tab — our own handler plus the two ecosystem variants
;; (old bookmark-plus-gt and browsel-tab-manager).  Note: type
;; membership does NOT imply cleanup ownership; the browsel-tabs
;; module clears only records whose handler is its OWN symbol.
(bookmark-gt-handler-register
 '(bookmark-gt-handler-browser-tab-jump
   bmkp-gt-browsel-tabs-jump
   browsel-tab-manager-bookmark-jump)
 (list :type 'browser-tab :name "BrowserTab"
       :face 'bookmark-gt-face-url :narrow-char ?b
       :doc "Browser tab bookmarked from browsel or its ecosystem."))

;; Third-party types worth showing by default (all follow the
;; standard naming convention, so the derive fallback would also
;; work — but explicit registration lets us pick a stable
;; `:narrow-char' and a nicer name).
(bookmark-gt-handler-register
 '(magit--handle-bookmark)
 (list :type 'magit :name "Magit"
       :face 'bookmark-gt-face-file :narrow-char ?m
       :doc "State bookmarked from Magit."))

(bookmark-gt-handler-register
 '(help-bookmark-jump)
 (list :type 'help :name "Help"
       :face 'bookmark-gt-face-file :narrow-char ?h
       :doc "*Help* page bookmark."))

(bookmark-gt-handler-register
 '(image-bookmark-jump)
 (list :type 'image :name "Image"
       :face 'bookmark-gt-face-file :narrow-char ?I
       :doc "Location bookmarked from image-mode."))

(bookmark-gt-handler-register
 '(nov-bookmark-jump-handler)
 (list :type 'epub :name "EPUB"
       :face 'bookmark-gt-face-file :narrow-char ?E
       :doc "Location bookmarked from nov.el."))

(provide 'bookmark-gt-handlers)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-handlers.el ends here
