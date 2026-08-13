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

;;;; Dired handler — bookmark-gt owns this one end-to-end
;;
;; The built-in Emacs's `dired.el' does not ship a bookmark handler;
;; Dired bookmarks are a bookmark+ invention.  To let users
;; migrate off bookmark+ without breaking their existing Dired
;; records, this module ships its own trivial handler that just
;; opens the record's `filename' in Dired.  It ignores the
;; bookmark+-specific alist keys (`dired-marked', `dired-subdirs',
;; `dired-hidden-dirs', `dired-switches') — those preserved
;; state features can come back later if wanted; the primary
;; contract (\"open the directory\") is honored.

(defun bookmark-gt-handler-dired-jump (bookmark)
  "Bookmark handler for Dired bookmarks.
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
