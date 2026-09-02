;;; bookmark-gt-core.el --- Core primitives and extension hooks  -*- lexical-binding: t; -*-

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
;; Core wrappers around `bookmark-store', `bookmark-save', and
;; `bookmark-load', plus the extension hooks third parties may
;; add to (name-reader, tag-reader, after-set).  Those hooks are
;; external surface only and ship empty; bookmark-gt's own
;; cross-module coordination is direct calls through
;; `bookmark-gt--after-mutation'.
;;
;; Same-name collisions are resolved by appending a `<N>' suffix
;; to the stored name, never by text properties: names are
;; stripped of properties on store, matching `bookmark-store'.

;;; Code:

(require 'bookmark)
(require 'seq)

;; Byte-compile visibility for symbols provided by sibling modules
;; that this file calls at runtime.  `bookmark-gt.el' requires all
;; of them before use.
(declare-function bookmark-gt-list-refresh "bookmark-gt-list")
(declare-function bookmark-gt-tags-read "bookmark-gt-tags")
(declare-function bookmark-gt-default-tags--hook
                  "bookmark-gt-default-tags")
(declare-function bookmark-gt--dired-collect-state
                  "bookmark-gt-handlers")
(declare-function bookmark-gt-handler-name "bookmark-gt-handlers")
(defvar bookmark-gt-prompt-for-tags-flag)
(defvar bookmark-gt-default-tags-mode)

;;;; Field-access helpers with bookmark+ compat
;;
;; bookmark+ stores a placeholder string in the `filename' slot of
;; non-file records (URL, browser-tab, EWW).  bookmark-gt writes
;; non-file records with no `filename' at all — but we still need
;; to read the placeholder as \"absent\" so records created by
;; bookmark+ round-trip cleanly.  The URL prop has a similar
;; issue: our code writes it as `url'; bookmark+ writes it as
;; `location'.  These two helpers hide both differences from every
;; caller downstream (list column, jump annotator, URL handler).

(defconst bookmark-gt-non-file-placeholder "   - no file -"
  "String bookmark+ writes into the `filename' slot for non-file records.
Treated as if the field were absent when reading a record.")

(defun bookmark-gt-filename-of (record)
  "Return RECORD's `filename', or nil if it is the bookmark+ placeholder."
  (let ((f (bookmark-prop-get record 'filename)))
    (unless (and f (string= f bookmark-gt-non-file-placeholder))
      f)))

(defun bookmark-gt-url-of (record)
  "Return RECORD's URL from either the `url' or the `location' prop.
`url' is bookmark-gt's convention; `location' is bookmark+'s.
Returns nil when neither is present."
  (or (bookmark-prop-get record 'url)
      (bookmark-prop-get record 'location)))

;;;; Record identity
;;
;; A bookmark name is not an identifier: `bookmark-get-bookmark'
;; resolves one with `assoc', so a name shared by two records
;; reaches only the first, and `bookmark-rename' changes it.  The
;; record cons is precise but does not survive `bookmark-load',
;; which builds fresh conses, so it cannot be written to disk or
;; held across a reload.
;;
;; `bookmark-gt-id' is the durable form: an interned symbol stored
;; on the record.  The key is namespaced because plain `id' is
;; taken — `org-bookmark-heading' stores the org heading ID there
;; and its handler depends on it.
;;
;; It is best-effort, never an invariant.  Records written by
;; `bookmark.el', bookmark+, or any other package have no id, and
;; a file copied between machines can carry the same id twice.
;; Code resolves by id when present and by name otherwise; it must
;; never assume presence or uniqueness.

(defvar bookmark-gt-id-generator-function #'bookmark-gt--generate-id
  "Function of no arguments returning a fresh bookmark id.
Must return an interned symbol.  Indirected so tests can bind a
deterministic generator; production code calls
`bookmark-gt--new-id' rather than this variable directly.")

(defun bookmark-gt--generate-id ()
  "Return a fresh id: `bgt-' followed by a timestamp and hex suffix.
The timestamp is the moment the id was assigned, which for a
record read from an older bookmark file is not when the bookmark
was created — `created' holds that.  It is included because it
makes ids sortable and legible when reading the file.

The `bgt-' prefix is what guarantees the printed form reads back
as a symbol: a body of digits alone would read as an integer."
  (intern
   (format "bgt-%s-%s"
           (format-time-string "%Y%m%dT%H%M%S")
           (substring (secure-hash 'sha1
                                   (format "%s%s%s" (emacs-pid)
                                           (current-time) (random)))
                      0 8))))

(defun bookmark-gt--new-id ()
  "Return a fresh id from `bookmark-gt-id-generator-function'."
  (funcall bookmark-gt-id-generator-function))

(defun bookmark-gt-id-of (bookmark)
  "Return BOOKMARK's `bookmark-gt-id', or nil when it has none.
BOOKMARK is a record or a name."
  (bookmark-prop-get bookmark 'bookmark-gt-id))

(defun bookmark-gt--ids-in-use ()
  "Return a hash table of every `bookmark-gt-id' in `bookmark-alist'."
  (let ((taken (make-hash-table :test 'eq)))
    (dolist (record bookmark-alist taken)
      (when-let* ((id (bookmark-gt-id-of record)))
        (puthash id t taken)))))

(defun bookmark-gt--assign-id (record taken)
  "Assign a fresh id to RECORD and return it.
TAKEN is a hash table of ids already in use; the generated id is
regenerated until it is absent from TAKEN, and then added to it.
Within-file uniqueness is therefore exact rather than probable.

Writes with `bookmark-prop-set' rather than through a mutator:
`bookmark-gt--after-mutation' would run
`bookmark-gt-record-changed-hook' once per record, and
`bookmark-gt--stamp-modified' would overwrite `last-modified' on
every record with the time of the scan."
  (let ((id (bookmark-gt--new-id)))
    (while (gethash id taken)
      (setq id (bookmark-gt--new-id)))
    (puthash id t taken)
    (bookmark-prop-set record 'bookmark-gt-id id)
    id))

(defun bookmark-gt-ensure-ids ()
  "Assign a `bookmark-gt-id' to every record in `bookmark-alist' lacking one.
Returns the number of ids assigned.

Called from the places that already read the whole alist: after
a load, when the list buffer redraws, and once per jump.  Records
arriving from other packages are picked up at whichever of those
comes first.  In the steady state every record has an id and this
is a scan that changes nothing.

Assigns ids and converts sequence members; it does not remove
anything.  Enforcing the same-name setting is
`bookmark-gt-enforce-same-name-policy\=', which is called at
operations rather than here — this runs while the list buffer is
being drawn, and drawing a buffer must not delete data.

Assigning is a change to what `bookmark-save' would write, so it
is counted once at the end rather than per record, and only when
a record eligible for the file was given an id.  Temporary
records are excluded from the file, so ids assigned to them do
not count."
  (let ((taken (bookmark-gt--ids-in-use))
        (assigned 0)
        (persistent nil))
    (dolist (record bookmark-alist)
      (unless (bookmark-gt-id-of record)
        (bookmark-gt--assign-id record taken)
        (setq assigned (1+ assigned))
        (unless (bookmark-gt-temp-p record)
          (setq persistent t))))
    (when (bookmark-gt--convert-sequence-members)
      (setq persistent t))
    (when persistent
      ;; NO-SAVE: one count for the whole pass, persisted at the
      ;; next save rather than provoking a write during a load.
      (bookmark-gt--note-modification 'no-save))
    assigned))

(defun bookmark-gt-enforce-same-name-policy ()
  "Remove records `bookmark-gt-allow-same-name-bookmarks' forbids, and report.
Also reports sequence bookmarks whose members stopped resolving,
which is usually a consequence of the same removal.

Called at operations, not at renders: opening or reverting the
list buffer, reading the jump reader, and after
`bookmark-load'.  `bookmark-gt-list--entries' deliberately does
not call it — it runs on every redraw, and a redraw is provoked
by every change, so enforcing there would let a change to one
bookmark delete another and open a warning window while doing
it."
  (bookmark-gt--drop-same-name-violations)
  (bookmark-gt--report-broken-sequences))

(defun bookmark-gt--report-broken-sequences ()
  "Report sequence bookmarks whose members no longer resolve.

A member stops resolving when the bookmark it names was deleted,
or omitted because the same-name setting forbade it, or removed
on another machine.  The reference is then broken, and finding
that out at the next jump — partway through a traversal — is
late.  Checked in the scan, which already reads the whole alist.

Reports rather than repairs: which member was meant is not
recoverable, and silently shortening a sequence would lose the
user\='s ordering without telling them."
  (dolist (record bookmark-alist)
    (let ((members (bookmark-prop-get record 'sequence)))
      (when (listp members)
        (let ((broken (seq-remove
                       (lambda (member)
                         (condition-case nil
                             (bookmark-gt--resolve member)
                           (error nil)))
                       members)))
          (when broken
            (message
             "Sequence `%s\=' has %d member(s) that no longer resolve: %s"
             (bookmark-name-from-full-record record)
             (length broken)
             (mapconcat (lambda (m) (format "%s" m)) broken ", "))))))))

(defun bookmark-gt--convert-sequence-members ()
  "Rewrite sequence members from names to ids.
Return non-nil when any member changed.

Sequences written before ids existed reference their members by
name.  Such a reference stops resolving when the member is
renamed, and cannot address one of two records sharing a name.

Runs after ids are assigned, so a member stored moments ago
already has one.  A member name matching exactly one record
becomes that record\='s id; a name matching none or several has
no unambiguous answer, so it is left alone and reported."
  (let ((changed nil)
        (unresolved 0))
    (dolist (record bookmark-alist)
      (when-let* ((members (bookmark-prop-get record 'sequence))
                  ((listp members)))
        (let ((converted
               (mapcar
                (lambda (member)
                  (if (not (stringp member))
                      member
                    (let ((matches (bookmark-gt--records-named member)))
                      (if (and matches (null (cdr matches)))
                          (or (bookmark-gt-id-of (car matches)) member)
                        (setq unresolved (1+ unresolved))
                        member))))
                members)))
          (unless (equal converted members)
            (bookmark-prop-set record 'sequence converted)
            (setq changed t)))))
    (when (> unresolved 0)
      (message
       "bookmark-gt: %d sequence member%s left as %s; the name matches no record or several"
       unresolved (if (= unresolved 1) "" "s")
       (if (= unresolved 1) "a name" "names")))
    changed))

;;;; Resolving a bookmark reference
;;
;; One helper, four argument types, no guessing:
;;
;;   nil     no bookmark given
;;   cons    the record itself
;;   string  a name — a query, which may match none or several
;;   symbol  an id — resolved exactly
;;
;; A name is always a string (`bookmark-store' copies it and
;; strips its text properties), so a symbol can only be an id.
;; That makes the dispatch total rather than heuristic.

(defvar bookmark-gt--name-index nil
  "Hash table of name → records, or nil.
Bound only by `bookmark-gt-with-name-index', for the extent of
one bulk operation.  A scoped memo, never persistent state:
nothing outside that macro assigns it, so it cannot go stale
across commands.")

(defun bookmark-gt--build-name-index ()
  "Return a hash table mapping each stored name to its records.
Records keep their `bookmark-alist' order within a name."
  (let ((index (make-hash-table :test 'equal)))
    (dolist (record bookmark-alist index)
      (let ((name (substring-no-properties
                   (bookmark-name-from-full-record record))))
        (puthash name (nconc (gethash name index) (list record)) index)))))

(defmacro bookmark-gt-with-name-index (&rest body)
  "Run BODY with a prebuilt name index in effect.

`bookmark-gt--records-named' scans `bookmark-alist' on each call,
which is what one lookup should do.  Asking it once per record —
rendering the list buffer, building the jump reader's candidates
— would make that quadratic, so bulk callers build the index once
and BODY reads it.

BODY must not add, remove or rename records: the index is a
snapshot."
  (declare (indent 0) (debug t))
  `(let ((bookmark-gt--name-index (bookmark-gt--build-name-index)))
     ,@body))

(defun bookmark-gt--records-named (name)
  "Return every record in `bookmark-alist' named NAME."
  (let ((wanted (substring-no-properties name)))
    (if bookmark-gt--name-index
        (gethash wanted bookmark-gt--name-index)
      (seq-filter (lambda (record)
                    (equal (substring-no-properties
                            (bookmark-name-from-full-record record))
                           wanted))
                  bookmark-alist))))

(defun bookmark-gt-display-name-of (record)
  "Return the name to show for RECORD, distinct from its namesakes.

A stored name is exactly what the user typed, and two bookmarks
may share one.  Appending `<N>' to the stored name instead would
quietly make every name unique, which is what allowing shared
names exists to avoid — so the suffix is computed here, for
display, and never written to the record or the file.

The first record with a name is shown bare, later ones as
`NAME<2>', `NAME<3>', following the order they sit in
`bookmark-alist'.

Callers rendering many records at once should wrap the loop in
`bookmark-gt-with-name-index'."
  (let* ((name (bookmark-name-from-full-record record))
         (peers (bookmark-gt--records-named name)))
    (if (null (cdr peers))
        name
      (let ((n (1+ (or (seq-position peers record #'eq) 0))))
        (if (= n 1) name (format "%s<%d>" name n))))))

(defun bookmark-gt--record-with-id (id)
  "Return the record carrying ID, signaling if none or several do.
Ids are best-effort, so two records can carry one after a file
is copied or merged; that is as much a broken reference as an id
matching nothing, and gets its own message."
  (let ((matches (seq-filter (lambda (record)
                               (eq (bookmark-gt-id-of record) id))
                             bookmark-alist)))
    (cond
     ((null matches)
      (error "No bookmark with id %s" id))
     ((cdr matches)
      (error "Ambiguous bookmark id %s: %d records carry it"
             id (length matches)))
     (t (car matches)))))

(defun bookmark-gt--resolve (bookmark &optional prompt)
  "Return the record BOOKMARK refers to.

BOOKMARK is nil, a record, a name, or an id; see the dispatch
table above.  PROMPT is used when BOOKMARK is nil, or when a
name matches several records and the user can be asked.

A name matching several records is not an answer.  When a prompt
is possible the user chooses; otherwise this signals rather than
returning the first match, which would act on a record the
caller did not choose.

Note the clause order: nil is itself a symbol, so it has to be
tested before the id branch.  So does t."
  (cond
   ((null bookmark)
    (unless (bookmark-gt--can-prompt-p)
      (error "No bookmark given"))
    (bookmark-gt--resolve
     (bookmark-completing-read (or prompt "Bookmark"))))
   ((consp bookmark) bookmark)
   ((stringp bookmark)
    (let ((matches (bookmark-gt--records-named bookmark)))
      (cond
       ((null matches)
        (error "No bookmark named %s" bookmark))
       ((null (cdr matches)) (car matches))
       ((bookmark-gt--can-prompt-p)
        (bookmark-gt--read-among matches bookmark prompt))
       (t
        (error "Ambiguous bookmark name %s: %d records share it"
               bookmark (length matches))))))
   ((symbolp bookmark) (bookmark-gt--record-with-id bookmark))
   (t (error "Not a bookmark reference: %S" bookmark))))

(defvar bookmark-gt--in-timer nil
  "Bound non-nil around work that runs from a timer.
Resolution refuses to prompt while it is set.  Bound by
`bookmark-gt-browser-tabs-refresh' and
`bookmark-gt-auto-update-tick'.")

(defun bookmark-gt--can-prompt-p ()
  "Return non-nil when it is safe to read from the minibuffer.
Batch sessions cannot prompt, and a prompt from a timer would
block on a minibuffer nobody is watching."
  (not (or noninteractive bookmark-gt--in-timer)))

(defun bookmark-gt--read-among (records name prompt)
  "Read one of RECORDS, all named NAME, under PROMPT.

Their stored names are identical — that is why this is being
asked — so the candidates cannot be the names.  Each is labelled
with its position and where it points, and the position alone
keeps them distinct when the destinations match too."
  (let* ((n 0)
         (table
          (mapcar
           (lambda (record)
             (setq n (1+ n))
             (cons (format "%d. %s — %s" n name
                           (or (bookmark-gt-filename-of record)
                               (bookmark-gt-url-of record)
                               "no location"))
                   record))
           records))
         (choice (completing-read
                  (format "%s (%d bookmarks are named `%s'): "
                          (or prompt "Bookmark") (length records) name)
                  (mapcar #'car table) nil t)))
    (cdr (assoc choice table))))

;;;; Extension hooks
;;
;; All three hooks are top-level defvars per Emacs hook convention:
;; they contain callbacks, not state.

(defvar bookmark-gt-create-name-reader-hook nil
  "Abnormal hook that refines the default bookmark name.
Each function is called with two arguments: DEFAULT-NAME (string)
and CONTEXT (the record's alist).  The first function to return a
non-nil string wins; if every function returns nil, DEFAULT-NAME
is used unchanged.

The interactive prompt in `bookmark-gt-create' happens *after* this
hook, so hooks refine what the user sees prefilled, they do not
replace the prompt.")

(defvar bookmark-gt-create-tag-reader-hook nil
  "Abnormal chained hook that reads tags for a bookmark being created.
Each function is called with two arguments: RECORD (the record's
alist) and SEED-TAGS (list of strings).  The return value is a
new list of strings that becomes the SEED-TAGS for the next
function.  The final result is stored on the record under the
`tags' alist key.

Hook order matters: default-tags style hooks that compute
context-based seeds should be added earlier; interactive readers
that use the seeds as prefill should be added later.")

(defvar bookmark-gt-record-changed-hook nil
  "Hook run after `bookmark-gt-set' stores a record.
Called with one argument: the stored (NAME . DATA) pair.
Return values are ignored.")

;;;; Same-name disambiguation
;;
;; The built-in `bookmark-store' strips text properties from names and
;; built-in `bookmark-load' runs `bookmark-maybe-rename' which
;; already appends "<N>" suffixes to colliding names on load.
;; Rather than fight both, we adopt the same convention on store:
;; a bookmark whose name collides with an existing one gets stored
;; as NAME<2>, NAME<3>, and so on.  Users see the suffix in the
;; list buffer; it is the accepted convention across built-in,
;; bookmark+, and every third-party bookmark front-end.

(defcustom bookmark-gt-allow-same-name-bookmarks 'different-destination
  "When `bookmark-gt-create' may reuse a name that already exists.

A bookmark name is a label, not an identifier, so two bookmarks
may legitimately share one — `todo\=' in each of several projects.
Two bookmarks sharing a name *and* a destination is usually a
mistake instead, made by creating twice in one place.

  `never\'                 a name already in use is refused.
  `different-destination\=' the name may be reused for a bookmark
                          pointing somewhere else; reusing it for
                          the same destination is refused.  The
                          default.
  `always\='                any name may be reused.

A refusal is an error naming the conflict, not a silent rename:
storing the bookmark as `todo<2>\=' would make names unique behind
the user\='s back, which is what allowing shared names exists to
avoid.  Records sharing a name are told apart on screen by a
`<N>\=' suffix that is computed for display only; see
`bookmark-gt-display-name-of'.

Nothing else consults this.  Creating a bookmark and changing an
existing one are separate commands — `bookmark-gt-create' and
`bookmark-gt-update' — so no variable decides between them.

Destination means the target, not the position: two bookmarks in
one file at different points share a destination."
  :type '(choice (const :tag "Refuse a name already in use" never)
                 (const :tag "Reuse only for a different destination"
                        different-destination)
                 (const :tag "Allow any name to be reused" always))
  :group 'bookmark-gt)

(defun bookmark-gt--same-destination-p (record other)
  "Return non-nil when RECORD and OTHER point at the same target.
Compares `filename' with `string=', and with `file-equal-p' when
both files exist, so paths differing only by a symlink are one
destination.  URL records compare their URL.  Records with
neither field compare as the same destination, so a second one is
refused rather than silently doubling."
  (let ((f-a (bookmark-gt-filename-of record))
        (f-b (bookmark-gt-filename-of other))
        (u-a (bookmark-gt-url-of record))
        (u-b (bookmark-gt-url-of other)))
    (cond
     ((and f-a f-b)
      (or (string= f-a f-b)
          (and (file-exists-p f-a) (file-exists-p f-b)
               (file-equal-p f-a f-b))))
     ((and u-a u-b) (string= u-a u-b))
     ((or f-a f-b u-a u-b) nil)
     (t t))))

(defun bookmark-gt-name-available-p (name data)
  "Return non-nil when a new record named NAME with alist DATA may be stored.
Applies `bookmark-gt-allow-same-name-bookmarks'; see its
docstring.

The predicate exists for callers that store many records at once
and cannot stop on one refusal — a browser-tab refresh, which
the user did not ask for and which must not fail partway.  A
caller acting on one bookmark should use
`bookmark-gt--check-name-available', which explains the refusal."
  (let ((existing (bookmark-gt--records-named name)))
    (cond
     ((null existing) t)
     ((eq bookmark-gt-allow-same-name-bookmarks 'always) t)
     ((eq bookmark-gt-allow-same-name-bookmarks 'never) nil)
     (t (not (seq-find
              (lambda (other)
                (bookmark-gt--same-destination-p (cons name data) other))
              existing))))))

(defun bookmark-gt--check-name-available (name data)
  "Signal unless a new record named NAME with alist DATA may be stored.
Returns NAME when the name may be used.  The message names the
reason, which differs between the two ways a name can be
refused."
  (cond
   ((bookmark-gt-name-available-p name data) name)
   ((eq bookmark-gt-allow-same-name-bookmarks 'never)
    (user-error
     "A bookmark named `%s' exists; choose another name, or update it with `%s'"
     name "bookmark-gt-update"))
   (t
    (user-error
     "A bookmark named `%s' already points here; update it with `%s'"
     name "bookmark-gt-update"))))

;;;; Hook runners (internal)

(defun bookmark-gt--refine-name (default-name context)
  "Run `bookmark-gt-create-name-reader-hook' and return the refined name.
Returns the first non-nil string returned by a hook, or
DEFAULT-NAME if every hook returns nil.  CONTEXT is passed to
each hook as its second argument."
  (or (run-hook-with-args-until-success
       'bookmark-gt-create-name-reader-hook default-name context)
      default-name))

(defun bookmark-gt--collect-tags (record seed-tags)
  "Return the final tag list for RECORD, starting from SEED-TAGS.
The pipeline is: default-tags contribution when
`bookmark-gt-default-tags-mode' is on, then the interactive
reader when `bookmark-gt-prompt-for-tags-flag' is non-nil,
then any third-party functions on the public
`bookmark-gt-create-tag-reader-hook'."
  (let ((tags seed-tags))
    (when bookmark-gt-default-tags-mode
      (setq tags (bookmark-gt-default-tags--hook record tags)))
    (when bookmark-gt-prompt-for-tags-flag
      (setq tags (bookmark-gt-tags-read "Tags" tags)))
    (seq-reduce (lambda (acc fn) (funcall fn record acc))
                bookmark-gt-create-tag-reader-hook
                tags)))

(defun bookmark-gt--with-tags (record tags)
  "Return RECORD's alist with TAGS attached under the `tags' key.
When TAGS is empty, RECORD is returned unchanged; no empty
`(tags)' entry is emitted."
  (if (null tags)
      record
    (cons (cons 'tags tags) record)))

;;;; Temporary bookmarks
;;
;; A record carrying the `bmkp-temp' alist key is a temp bookmark:
;; visible in `bookmark-alist' for the life of the Emacs session,
;; excluded from `bookmark-save' output.  Same key name as
;; bookmark+'s `bmkp-temp' so bookmark files round-trip either way.
;;
;; The save filter is installed via advice on `bookmark-save' —
;; `bookmark.el' has no extension hook there.  Install / uninstall is
;; controlled by `bookmark-gt-mode' so a user who never enables it
;; sees the built-in behavior unchanged.
;;
;; Defined here, ahead of the store and mutation code, because
;; those decide whether a change is worth counting by asking
;; `bookmark-gt-temp-p'.

(defconst bookmark-gt-temp-key 'bmkp-temp
  "Alist key used to mark a bookmark as temporary.
Chosen to match bookmark+'s `bmkp-temp' so bookmark files
round-trip between the two packages without data loss.")

(defun bookmark-gt-temp-p (record)
  "Return non-nil when RECORD is marked as a temporary bookmark."
  (bookmark-prop-get record bookmark-gt-temp-key))

;;;; Modification accounting
;;
;; `bookmark-alist-modification-count' means "changes not yet
;; written to the bookmark file".  Built-in `bookmark.el' saves
;; when it crosses `bookmark-save-flag', and saves again from
;; `kill-emacs-hook' when it is above zero.
;;
;; A change confined to temporary records is never written: the
;; `bookmark-save' advice removes those records before the file is
;; produced.  Counting such a change schedules a write that cannot
;; alter the file, so every mutator here counts only changes to
;; records that are eligible for the file.

(defun bookmark-gt--maybe-auto-save ()
  "Write the bookmark file when the auto-save threshold is reached.
The threshold is `bookmark-save-flag', evaluated by
`bookmark-time-to-save-p'."
  (when (bookmark-time-to-save-p)
    (bookmark-save)))

(defun bookmark-gt--note-modification (&optional no-save)
  "Count one change that affects `bookmark-save' output.
Bumps `bookmark-alist-modification-count' and, unless NO-SAVE is
non-nil, calls `bookmark-gt--maybe-auto-save'.  A caller that
mutates many records in a loop passes NO-SAVE and calls
`bookmark-gt--maybe-auto-save' once at the end.

Do not call this for a change confined to temporary records."
  (setq bookmark-alist-modification-count
        (1+ bookmark-alist-modification-count))
  (unless no-save
    (bookmark-gt--maybe-auto-save)))

;;;; Internal: fast push
;;
;; Stores go through this function rather than `bookmark-store'
;; because each of the three things `bookmark-store' does
;; unconditionally has to be conditional here:
;;
;;   - The modification count.  A temporary record must not raise
;;     it (see "Modification accounting" above); `bookmark-store'
;;     raises it for every record.
;;   - `bookmark-current-bookmark'.  A caller storing records
;;     unrelated to the current buffer — a browser-tab refresh
;;     running from a timer — passes NO-CURRENT to leave it alone.
;;   - The `*Bookmark List*' rebuild.  bookmark-gt has its own
;;     list buffer and refreshes it from
;;     `bookmark-gt--after-mutation'.
;;
;; What is kept from the `bookmark-store' contract: push the
;; record onto `bookmark-alist' with text properties stripped from
;; the name, and honor auto-save, so a record stored here reaches
;; the file on the same schedule as one stored by built-in
;; commands.  Callers that store many records should let-bind
;; `bookmark-save-flag' to nil to prevent mid-batch saves.
;;
;; A side benefit during migration: bookmark+ redefines
;; `bookmark-store', and its version rebuilds `*Bookmark List*' on
;; every call — measured at 27ms, which turns a browser-tab
;; refresh of ~100 tabs into a multi-second delay.  Going direct
;; means a session with bookmark+ loaded pays none of that.

(defun bookmark-gt--push-record (name alist &optional no-current)
  "Push (NAME . ALIST) onto `bookmark-alist' compatibly with `bookmark-store'.
NAME's text properties are stripped, matching what the built-in
`bookmark-store' does.  Adds `created' and `last-modified'
timestamps unless ALIST already carries them (callers that
preserve historical timestamps, e.g. migration, pass their own).

With NO-CURRENT non-nil, leave `bookmark-current-bookmark'
alone.  That variable is buffer-local, and its value is the
default offered by several name prompts, so a caller that
stores records unrelated to the current buffer (a browser-tab
refresh running from a timer) must not write it.

A temporary ALIST is not counted as a modification: it is
excluded from `bookmark-save' output, so the store cannot change
the file.

Returns the stripped name."
  (let ((stripped (copy-sequence name))
        (now (current-time))
        (temp (assq bookmark-gt-temp-key alist)))
    (set-text-properties 0 (length stripped) nil stripped)
    (unless (assq 'created alist)
      (setq alist (cons (cons 'created now) alist)))
    (unless (assq 'last-modified alist)
      (setq alist (cons (cons 'last-modified now) alist)))
    ;; A record created here gets its id now, so it is addressable
    ;; without waiting for the next scan.  No uniqueness check:
    ;; the id carries a timestamp to the second plus 32 random
    ;; bits, and this path adds one record.  `bookmark-gt-ensure-ids'
    ;; does check, because it has the table of ids in hand anyway.
    (unless (assq 'bookmark-gt-id alist)
      (setq alist (cons (cons 'bookmark-gt-id (bookmark-gt--new-id))
                        alist)))
    (push (cons stripped alist) bookmark-alist)
    (unless no-current
      (setq bookmark-current-bookmark stripped)
      (setq-local bookmark-gt-current-bookmark (car bookmark-alist)))
    (unless temp
      (bookmark-gt--note-modification))
    stripped))

;;;; Public: elisp API

(defun bookmark-gt--create-record (name data &optional no-notify no-current)
  "Store a new record named NAME with alist DATA, and return it.

The single creation path.  Applies the name-reader hook, then
`bookmark-gt-allow-same-name-bookmarks' to decide the stored
name, collects tags, pushes the record and notifies.  Both
`bookmark-gt-create' and `bookmark-gt-create-non-file' end here,
so the same-name policy and the reporting exist once.

Reports when the stored name differs from the one asked for, or
when it repeats an existing name: either way the user typed one
thing and got another.

NO-NOTIFY skips the UI refresh and the change hook, for a caller
mutating many records that will notify once at the end.
NO-CURRENT leaves `bookmark-current-bookmark' alone; see
`bookmark-gt--push-record'."
  (let* ((refined (bookmark-gt--refine-name name data))
         (shared (bookmark-gt--records-named refined))
         (stored-name (bookmark-gt--check-name-available refined data))
         (tags (bookmark-gt--collect-tags data nil))
         (final-data (bookmark-gt--with-tags data tags))
         (final-name (bookmark-gt--push-record stored-name final-data
                                               no-current))
         (record (car bookmark-alist)))
    (unless no-notify
      (bookmark-gt--after-mutation record 'create)
      (cond
       ((not (equal final-name refined))
        (message "Bookmark `%s' already exists; stored as `%s'"
                 refined final-name))
       (shared
        (message "Bookmark `%s' now names %d bookmarks"
                 final-name (1+ (length shared))))))
    record))

;;;###autoload
(defun bookmark-gt-create-non-file (name handler props &optional no-notify
                                         no-current)
  "Create a non-file bookmark called NAME using HANDLER.
PROPS is an alist of additional record entries (URL, page title,
and so on).  NO-NOTIFY and NO-CURRENT are passed to
`bookmark-gt--create-record'.  Returns the stored record."
  (bookmark-gt--create-record name
                              (cons (cons 'handler handler) props)
                              no-notify no-current))

;;;; Session-only record properties
;;
;; A module may attach data identifying a live object owned by
;; another process — `bookmark-gt-browser-tabs.el' stores a browser
;; tab's id and the name of its client.  Such a value is valid only
;; for the session that produced it, so it is removed when a record
;; stops being temporary and becomes eligible to be written to the
;; bookmark file.

(defvar bookmark-gt-session-only-props nil
  "Record keys that describe live session state.
A list of alist keys.  `bookmark-gt-toggle-temp' removes them
from a record when it clears the temp flag, so they are never
written to the bookmark file.  Modules that attach such data
register their keys at load time.")

(defun bookmark-gt--session-only-key-p (cell)
  "Return non-nil when alist CELL's key is registered as session-only."
  (memq (car-safe cell) bookmark-gt-session-only-props))

(defun bookmark-gt-temp-set (record flag &optional no-notify)
  "Set the temp property on RECORD according to FLAG.
RECORD is a `(NAME . DATA)' pair or a bookmark name.  FLAG
non-nil sets the flag; nil clears it.  Clearing makes the record
eligible for the bookmark file, so any
`bookmark-gt-session-only-props' key is removed at the same
time.  When NO-NOTIFY is non-nil, skip UI refresh, the external
`bookmark-gt-record-changed-hook', and the auto-save — the caller is
expected to notify and to call `bookmark-gt--maybe-auto-save'
once at end of a batch.  Returns the mutated record."
  (let* ((entry (bookmark-get-bookmark record))
         (was (and entry (bookmark-gt-temp-p entry))))
    (unless entry
      (user-error "No bookmark called %S" record))
    ;; Mutated in place: `bookmark-alist' and the list buffer
    ;; both hold this record by identity.
    (if flag
        (unless was
          (setcdr entry (cons (cons bookmark-gt-temp-key t)
                              (cdr entry))))
      (setcdr entry
              (seq-remove
               (lambda (cell)
                 (or (eq (car-safe cell) bookmark-gt-temp-key)
                     (bookmark-gt--session-only-key-p cell)))
               (cdr entry))))
    ;; A change of temp state changes what `bookmark-save' writes:
    ;; the record either becomes eligible for the file or stops
    ;; being eligible.  Either way the file is now out of date.
    (unless (eq (and flag t) (and was t))
      (bookmark-gt--note-modification no-notify))
    (if no-notify
        (bookmark-gt--stamp-modified entry)
      (bookmark-gt--after-mutation entry))
    entry))

(defun bookmark-gt-toggle-temp (&optional bookmark)
  "Toggle the temp property on BOOKMARK.
BOOKMARK is a record, a name, or an id; nil prompts.  A name
shared by several bookmarks asks which one rather than taking
the first.

Clearing the flag makes the record eligible for the bookmark
file, so any `bookmark-gt-session-only-props' key is removed at
the same time.  Runs `bookmark-gt-record-changed-hook' so the
list buffer and any other observers refresh."
  (interactive)
  (let* ((record (bookmark-gt--resolve bookmark "Toggle temporary"))
         (current (bookmark-gt-temp-p record)))
    (bookmark-gt-temp-set record (not current))
    (message "%s temp on %S"
             (if current "Cleared" "Set")
             (bookmark-name-from-full-record record))))

;;;; jump-via override
;;
;; Built-in `bookmark--jump-via' runs, in order:
;;   1. `save-window-excursion' around `bookmark-handle-bookmark',
;;      capturing the handler's final buffer + point;
;;   2. `funcall' DISPLAY-FUNCTION on that buffer;
;;   3. `set-window-point' on the displayed window;
;;   4. fringe-mark;
;;   5. `run-hooks' `bookmark-after-jump-hook';
;;   6. `bookmark-show-annotation' when
;;      `bookmark-automatically-show-annotations' is non-nil.
;;
;; This override behaves identically EXCEPT that a handler which
;; throws `bookmark-gt-skip-post-handler' suppresses only step 6.
;; Steps 2-5 always run.  This exists as an extension point for
;; third-party handlers whose target is external (a URL opened
;; via `browse-url', a browser tab focused via a bridge) and
;; whose annotation popup would move window-manager focus off the
;; external target back to Emacs.  No handler shipped in
;; bookmark-gt itself calls the macro — the mechanism is retained
;; for third-party use only.

(declare-function bookmark--set-fringe-mark "bookmark" ())

(defvar-local bookmark-gt-current-bookmark nil
  "Record of the bookmark most recently used in this buffer.
Set by `bookmark-gt--jump-via-override' after the handler runs,
and by `bookmark-gt--push-record' on store.  Holds the record
itself, not its name.

Built-in `bookmark-current-bookmark' holds a *name*, so every
reader of it re-enters `assoc' and acts on the first record
carrying that name — the wrong one whenever names are shared.
This variable exists so the post-jump readers act on the record
that was actually jumped to.

May hold a record that is no longer in `bookmark-alist' if the
bookmark file was reloaded since the jump; readers must
tolerate that rather than assume membership.")

(defun bookmark-gt--jump-via-override (bookmark-name-or-record display-function)
  "Override of `bookmark--jump-via'.
Handle BOOKMARK-NAME-OR-RECORD, then call DISPLAY-FUNCTION on
the buffer left current by the handler.  Same behavior as the
built-in EXCEPT that a handler which throws
`bookmark-gt-skip-post-handler' suppresses only
`bookmark-show-annotation'; display, `set-window-point',
fringe mark, and `bookmark-after-jump-hook' all still run."
  (let (buf point skip)
    (save-window-excursion
      (setq skip (catch 'bookmark-gt-skip-post-handler
                   (bookmark-handle-bookmark bookmark-name-or-record)
                   nil))
      (setq buf (current-buffer)
            point (point))
      ;; Record what was actually jumped to, in the buffer the
      ;; handler left current, before `bookmark-after-jump-hook'
      ;; runs.  When the caller passed a record this is exact;
      ;; when it passed a name the ambiguity is the caller's.
      (setq-local bookmark-gt-current-bookmark
                  (bookmark-get-bookmark bookmark-name-or-record
                                         'noerror)))
    (funcall display-function buf)
    (when-let* ((win (get-buffer-window buf 0)))
      (set-window-point win point))
    (when bookmark-fringe-mark
      (let ((overlays (overlays-in (pos-bol) (1+ (pos-bol))))
            temp found)
        (while (and (not found) (setq temp (pop overlays)))
          (when (eq 'bookmark (overlay-get temp 'category))
            (setq found t)))
        (unless found
          (bookmark--set-fringe-mark))))
    (run-hooks 'bookmark-after-jump-hook)
    (when (and bookmark-automatically-show-annotations (not skip))
      (bookmark-show-annotation bookmark-name-or-record))))

(defun bookmark-gt-jump-record (record &optional display-func)
  "Jump to RECORD, a cons from `bookmark-alist'.
Like `bookmark-jump', but takes the record itself, so the jump
cannot go to a different bookmark that shares RECORD's name.
DISPLAY-FUNC defaults to `pop-to-buffer-same-window'.

RECORD's name, not RECORD, is added to `bookmark-history':
`bookmark-jump' would push the record there, and that history
holds strings."
  (unless (consp record)
    (error "Not a bookmark record: %S" record))
  (add-to-history 'bookmark-history (bookmark-name-from-full-record record))
  (bookmark--jump-via record (or display-func #'pop-to-buffer-same-window)))

(defun bookmark-gt-delete-record (record)
  "Delete RECORD from `bookmark-alist' by identity.
Unlike `bookmark-delete', which removes the first record
carrying a given name, this removes exactly RECORD.

A change confined to a temporary record is not counted: temp
records are excluded from `bookmark-save' output, so removing
one cannot alter the file."
  (unless (consp record)
    (error "Not a bookmark record: %S" record))
  (let ((temp (bookmark-gt-temp-p record)))
    (bookmark--remove-fringe-mark record)
    (setq bookmark-alist (delq record bookmark-alist))
    (unless temp
      (bookmark-gt--note-modification))
    record))

(defun bookmark-gt-rename-record (record new-name)
  "Rename RECORD to NEW-NAME in place.
Unlike `bookmark-rename', which renames the first record
carrying a given name, this renames exactly RECORD.  Returns
RECORD, whose car is now NEW-NAME."
  (unless (consp record)
    (error "Not a bookmark record: %S" record))
  (bookmark-set-name record new-name)
  (bookmark-gt--after-mutation record 'rename)
  record)

(defmacro bookmark-gt-skip-post-handler (value)
  "Throw VALUE to suppress this jump's annotation popup.
Extension point for third-party handlers.  A handler that calls
this at its tail prevents `bookmark-show-annotation' from
opening after the jump.  Intended for handlers whose target is
external (a browser URL, a browser tab, an OS application):
opening the annotation buffer would move window-manager focus
from the external target back to Emacs.
Does NOT skip display, `set-window-point', fringe mark, or
`bookmark-after-jump-hook'; the buffer-display flow and the
visit-tracker hook always run.  Safe to call when the enclosing
override is not installed — a `no-catch' signal is swallowed.
No handler shipped with bookmark-gt calls this macro."
  `(condition-case nil
       (throw 'bookmark-gt-skip-post-handler ,value)
     (no-catch nil)))

;;;; Per-bookmark highlighting
;;
;; Every file bookmark that points at the visited file gets an
;; overlay showing its position (or its region, if the record has
;; `end-position').  Overlays are refreshed when a buffer is
;; visited (`find-file-hook') and when a bookmark mutates
;; (`bookmark-gt-record-changed-hook').  Mode-off removes them.
;;
;; Optimized single-file refresh: after-hook runs with a
;; specific record → only the buffer visiting that record's file
;; is refreshed.  Full sweep only for the `nil' sentinel (batch
;; operations, unknown provenance).
;;
;; Overlays live in a buffer-local list so they die with the
;; buffer.  Nothing on disk; no records-only-invariant impact —
;; overlays are process-scoped display state (category 3).

(defcustom bookmark-gt-highlight-enable t
  "Non-nil: highlight file-bookmarks in their visited buffers.
An overlay is added at each bookmark's position (or spanning
its region) when the file is opened, refreshed on any
mutation, and removed when the mode turns off."
  :type 'boolean
  :group 'bookmark-gt)

(defface bookmark-gt-face-highlight
  '((t :inherit hl-line))
  "Overlay face for bookmarks in file-visiting buffers.
Applied per bookmark; region bookmarks span the full region,
point bookmarks span the containing line."
  :group 'bookmark-gt)

(defvar-local bookmark-gt-highlight--overlays nil
  "Buffer-local list of overlays created by the highlighter.
Overlays die with the buffer; the list can go stale on kill
but stale entries are ignored on next refresh.")

(defvar-local bookmark-gt-highlight--jumped-positions nil
  "Buffer-local hash: record cons → integer point after a jump.
Records without a numeric `position' (e.g. org-heading
bookmarks whose location is resolved by the handler at jump
time) go here after `bookmark-after-jump-hook' runs, so
subsequent refreshes still overlay them.")

(defun bookmark-gt-highlight--effective-position (record)
  "Return the position at which to overlay RECORD in this buffer.
Prefers the record's numeric `position'; falls back to a
post-jump position recorded in
`bookmark-gt-highlight--jumped-positions'.  Returns nil when
neither is available."
  (let ((p (bookmark-prop-get record 'position)))
    (cond
     ((numberp p) p)
     ((and bookmark-gt-highlight--jumped-positions
           (gethash record bookmark-gt-highlight--jumped-positions)))
     (t nil))))

(defun bookmark-gt-highlight--make-overlay (record)
  "Create and return a highlight overlay for RECORD in the current buffer.
Returns nil when the record has neither a numeric `position'
nor a post-jump recorded position."
  (let ((pos (bookmark-gt-highlight--effective-position record)))
    (when (numberp pos)
      (let* ((end (or (bookmark-prop-get record 'end-position) pos))
             (start (save-excursion
                      (goto-char (max (point-min)
                                      (min pos (point-max))))
                      (line-beginning-position)))
             (finish (save-excursion
                       (goto-char (max (point-min)
                                       (min end (point-max))))
                       (line-end-position)))
             (ov (make-overlay start finish nil t nil)))
        (overlay-put ov 'face 'bookmark-gt-face-highlight)
        (overlay-put ov 'bookmark-gt-highlight t)
        (overlay-put ov 'help-echo
                     (format "bookmark-gt: %s"
                             (bookmark-name-from-full-record record)))
        ov))))

(defun bookmark-gt-highlight--clear-buffer ()
  "Remove every bookmark-gt highlight overlay from the current buffer."
  (dolist (ov bookmark-gt-highlight--overlays)
    (when (overlayp ov) (delete-overlay ov)))
  (setq bookmark-gt-highlight--overlays nil))

(defun bookmark-gt-highlight--refresh-buffer ()
  "Rebuild highlight overlays for the current buffer.
Iterate `bookmark-alist' for records whose `filename' resolves
to the buffer's file (via `file-equal-p') and create one
overlay per match."
  (bookmark-gt-highlight--clear-buffer)
  (when-let* ((bookmark-gt-highlight-enable)
              (path (buffer-file-name)))
    (dolist (rec bookmark-alist)
      (let ((f (bookmark-gt-filename-of rec)))
        (when (and f
                   (not (file-remote-p f))
                   (file-exists-p f)
                   (file-equal-p f path))
          (when-let* ((ov (bookmark-gt-highlight--make-overlay rec)))
            (push ov bookmark-gt-highlight--overlays)))))))

(defun bookmark-gt-highlight--refresh-all-visible ()
  "Rebuild the highlight overlays of every live file-visiting buffer."
  (dolist (buf (buffer-list))
    (when (buffer-file-name buf)
      (with-current-buffer buf
        (bookmark-gt-highlight--refresh-buffer)))))

(defun bookmark-gt-highlight--on-find-file ()
  "Refresh highlight overlays for the just-opened buffer."
  (bookmark-gt-highlight--refresh-buffer))

(defun bookmark-gt-highlight--on-jump ()
  "Record the point after a jump and refresh the buffer's overlays.
Lets records without a numeric `position' (e.g. org-heading
bookmarks) still get an overlay at their landed position."
  (when-let* ((bookmark-gt-highlight-enable)
              (rec bookmark-gt-current-bookmark))
    (unless bookmark-gt-highlight--jumped-positions
      (setq bookmark-gt-highlight--jumped-positions
            (make-hash-table :test 'eq)))
    (puthash rec (point) bookmark-gt-highlight--jumped-positions)
    (bookmark-gt-highlight--refresh-buffer)))

(defun bookmark-gt-highlight-refresh (entry)
  "Refresh the buffer visiting ENTRY's file, if any."
  (when-let* ((bookmark-gt-highlight-enable)
              (entry)
              (path (bookmark-gt-filename-of entry))
              (buf (find-buffer-visiting path)))
    (with-current-buffer buf
      (bookmark-gt-highlight--refresh-buffer))))

(defun bookmark-gt-highlight--clear-all-visible ()
  "Remove every bookmark-gt highlight overlay from every buffer."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when bookmark-gt-highlight--overlays
        (bookmark-gt-highlight--clear-buffer)))))

;;;; Mutation notification
;;
;; Called directly by every internal mutator.  Refreshes list
;; buffers and highlight overlays, then runs the public
;; `bookmark-gt-record-changed-hook' for third-party observers.

(defun bookmark-gt--stamp-modified (entry)
  "Stamp `last-modified' on ENTRY when it names a specific record.
Split out of `bookmark-gt--after-mutation' so a batch mutator
can stamp every record it touches while notifying only once."
  (when (and (consp entry) (stringp (car entry)))
    (bookmark-prop-set entry 'last-modified (current-time))))

(defun bookmark-gt--after-mutation (entry &optional operation)
  "Notify observers that ENTRY changed, OPERATION saying how.
OPERATION is one of `create', `update', `relocate', `rename',
`tags', `temp', `auto-update' or `delete', and defaults to
`update'.

Stamps `last-modified' on ENTRY when it names a specific record,
refreshes list buffers and highlight overlays, then runs
`bookmark-gt-record-changed-hook' with both values."
  (bookmark-gt--stamp-modified entry)
  (bookmark-gt-list-refresh)
  (bookmark-gt-highlight-refresh entry)
  (run-hook-with-args 'bookmark-gt-record-changed-hook
                      entry (or operation 'update)))

;;;; In-buffer cycling
;;
;; `bookmark-gt-cycle-next' / `-prev' walk the bookmarks that
;; live in the current buffer's file, in position order.  Wrap
;; around at the ends.  Purely record-driven — nothing looks at
;; the highlight overlays, so cycling works even with
;; `bookmark-gt-highlight-enable' set to nil.

(defun bookmark-gt--current-file-entries ()
  "Return a list of (POSITION . NAME) for bookmarks in this buffer's file.
Sorted by POSITION ascending.  Only local, existing files are
considered.  Records without a numeric `position' are skipped."
  (let ((path (buffer-file-name)))
    (when path
      (sort
       (delq nil
             (mapcar
              (lambda (rec)
                (let ((f (bookmark-gt-filename-of rec))
                      (p (bookmark-prop-get rec 'position)))
                  (and f (numberp p)
                       (not (file-remote-p f))
                       (file-exists-p f)
                       (file-equal-p f path)
                       (cons p (bookmark-name-from-full-record rec)))))
              bookmark-alist))
       (lambda (a b) (< (car a) (car b)))))))

(defun bookmark-gt--cycle-to (entry)
  "Go to ENTRY's position and message its name.
ENTRY is a (POSITION . NAME) pair as returned by
`bookmark-gt--current-file-entries'."
  (goto-char (car entry))
  (message "Bookmark: %s" (cdr entry)))

;;;###autoload
(defun bookmark-gt-cycle-next ()
  "Move point to the next bookmark position in this buffer.
Bookmarks are those in `bookmark-alist' whose `filename'
resolves to the buffer's file.  Wraps from end to start when
past the last one."
  (interactive)
  (let* ((entries (bookmark-gt--current-file-entries))
         (cur (point))
         (next (seq-find (lambda (e) (> (car e) cur)) entries)))
    (unless entries
      (user-error "No bookmarks in this file"))
    (bookmark-gt--cycle-to (or next (car entries)))))

;;;###autoload
(defun bookmark-gt-cycle-prev ()
  "Move point to the previous bookmark position in this buffer.
Wraps from start to end when before the first one."
  (interactive)
  (let* ((entries (bookmark-gt--current-file-entries))
         (cur (point))
         (before (seq-filter (lambda (e) (< (car e) cur)) entries))
         (prev (car (last before))))
    (unless entries
      (user-error "No bookmarks in this file"))
    (bookmark-gt--cycle-to (or prev (car (last entries))))))

;;;; Region bookmarks
;;
;; When `bookmark-gt-create' is called with an active region and
;; `bookmark-gt-use-region' is non-nil, the record captures both
;; region anchors plus context strings around the end.  On jump,
;; `bookmark-gt--on-jump-restore-region' (called from
;; `bookmark-after-jump-hook') pushes the mark at the end
;; position and activates it, so the region reappears
;; highlighted.
;;
;; Alist-key names match bookmark+ (`end-position',
;; `front-context-region-string', `rear-context-region-string')
;; so bookmark files round-trip.  The built-in `bookmark.el' ignores
;; the extra keys — the record still jumps correctly there,
;; just without region restore.

(defcustom bookmark-gt-use-region t
  "Non-nil: capture and restore the active region on set/jump.
When set on `bookmark-gt-create' with an active region, the record
gains `end-position' plus context strings around it.  On
`bookmark-after-jump-hook', if a record has `end-position', the
mark is pushed there and the region is re-activated.

Turn off to store point bookmarks even when a region is
active — records that already carry region info still restore
their region on jump; this flag only gates the capture path.

To fully disable region restore, turn off `bookmark-gt-mode'."
  :type 'boolean
  :group 'bookmark-gt)

(defcustom bookmark-gt-region-context-size 40
  "Characters of context captured around a region's end.
Used by the re-anchoring logic to relocate the end position
when the buffer has been edited between save and re-jump."
  :type 'integer
  :group 'bookmark-gt)

(defun bookmark-gt--region-context-before (pos)
  "Return up to `bookmark-gt-region-context-size' chars ending at POS."
  (buffer-substring-no-properties
   (max (point-min) (- pos bookmark-gt-region-context-size)) pos))

(defun bookmark-gt--region-context-after (pos)
  "Return up to `bookmark-gt-region-context-size' chars starting at POS."
  (buffer-substring-no-properties
   pos (min (point-max) (+ pos bookmark-gt-region-context-size))))

(defun bookmark-gt--record-with-region (record-data)
  "Return RECORD-DATA augmented with region info when the region is active.
No-op when `bookmark-gt-use-region' is nil or the region is not
active.  Overrides `position' with `region-beginning' and adds
`end-position' plus the two region context strings."
  (if (not (and bookmark-gt-use-region (use-region-p)))
      record-data
    (let* ((start (region-beginning))
           (end   (region-end))
           (front (bookmark-gt--region-context-before end))
           (rear  (bookmark-gt--region-context-after end))
           (stripped (assq-delete-all
                      'position
                      (assq-delete-all
                       'end-position
                       (assq-delete-all
                        'front-context-region-string
                        (assq-delete-all
                         'rear-context-region-string
                         record-data))))))
      (append
       `((position . ,start)
         (end-position . ,end)
         (front-context-region-string . ,front)
         (rear-context-region-string . ,rear))
       stripped))))

(defun bookmark-gt--on-jump-restore-region ()
  "Hook on `bookmark-after-jump-hook' that re-activates the region.
When the just-jumped record has `end-position', push the mark
there (activated) so the region reappears highlighted.  Apply
a delta correction so context-based re-anchoring at the start
propagates to the end anchor."
  (when-let* ((bookmark-gt-use-region)
              (rec bookmark-gt-current-bookmark)
              (end-pos (bookmark-prop-get rec 'end-position))
              (raw-pos (bookmark-prop-get rec 'position)))
    (let ((delta (- (point) raw-pos)))
      (push-mark (+ end-pos delta) t t))))

;;;; Visit tracker
;;
;; Increments the `visits' count and sets `last-visited' on every
;; jump.  These two alist keys drive `bookmark-gt-jump''s
;; `:sort-by 'mru' and `:sort-by 'visits' features.
;;
;; Wiring: `bookmark-after-jump-hook' runs
;; `bookmark-gt--on-jump-record-visit' after every jump.  Under
;; `bookmark-gt--jump-via-override' the after-jump-hook always
;; runs, so handlers do not need to call
;; `bookmark-gt-record-visit' themselves.
;;
;; Mutation does NOT bump `bookmark-alist-modification-count' —
;; visit tracking on every jump should not trigger an auto-save
;; per jump.  Users get MRU / visit-count sorting within the
;; session; disk persistence happens on the next explicit save.

(defun bookmark-gt-record-visit (name-or-record)
  "Increment visits and set `last-visited' on NAME-OR-RECORD.
Both alist keys are written directly onto the record — no
`modification-count' bump, so visit tracking doesn't force a
disk write per jump."
  (let* ((rec (bookmark-get-bookmark name-or-record))
         (visits (or (bookmark-prop-get rec 'visits) 0)))
    (bookmark-prop-set rec 'visits (1+ visits))
    (bookmark-prop-set rec 'last-visited (current-time))))

(defun bookmark-gt--on-jump-record-visit ()
  "Hook for `bookmark-after-jump-hook'.
Records the visit against `bookmark-gt-current-bookmark', the
record `bookmark-gt--jump-via-override' set before this hook
ran.  Runs on every jump under that override."
  (when bookmark-gt-current-bookmark
    (bookmark-gt-record-visit bookmark-gt-current-bookmark)))

;;;; File-rename tracker
;;
;; When a file is renamed on disk, any bookmark whose `filename'
;; matched the old path becomes stale.  This advice on
;; `rename-file' rewrites the alist entry to the new path.
;;
;; Two guards:
;;   - `bookmark-gt-track-renames' — user opt-out (default on).
;;   - `backup-file-name-p' — the rename that Emacs performs to
;;     create a backup file (default `backup-by-copying' nil path:
;;     rename ORIG → ORIG~, then write new ORIG) is a spurious
;;     match that would move the bookmark to the backup.
;;     Bookmark+'s tracker has this bug; ours does not.
;;
;; Directory renames update only bookmarks whose `filename'
;; matches the directory exactly — children are not rewritten.
;; Documented in the defcustom.

(defcustom bookmark-gt-track-renames t
  "Non-nil: `bookmark-gt-mode' updates bookmark `filename' on rename.
An `:around' advice on `rename-file' rewrites any bookmark
whose `filename' matches the source path to the destination
path.

Guards:
- Backup destinations (`backup-file-name-p') are always
  ignored regardless of this flag — Emacs's default save mode
  renames ORIG → ORIG~ to create backups, and chasing that
  rename would leave the bookmark pointing at the backup.
- Directory renames only update bookmarks whose `filename'
  equals the directory exactly.  Children are NOT rewritten.

Toggle takes effect immediately (the advice reads this
variable at call time)."
  :type 'boolean
  :group 'bookmark-gt)

(defun bookmark-gt--rename-file-advice (orig-fn from to &rest args)
  "Around advice for `rename-file' that follows the rename in `bookmark-alist'.
FROM and TO are the source/destination paths; ORIG-FN is
`rename-file'; ARGS carries `ok-if-already-exists' and any
further built-in arguments.  Rewrites bookmarks whose
`filename' exactly equals FROM to point at TO.  Gated by
`bookmark-gt-track-renames' and skipped for backup destinations."
  (apply orig-fn from to args)
  (when (and bookmark-gt-track-renames
             (not (backup-file-name-p to)))
    (let ((from-abs (expand-file-name from))
          (to-abs   (expand-file-name to)))
      (dolist (rec bookmark-alist)
        (when (equal (bookmark-gt-filename-of rec) from-abs)
          ;; Write through REC, not `(car rec)': a name would be
          ;; resolved with `assoc', retargeting the first record
          ;; carrying it rather than the one just tested.
          (bookmark-prop-set rec 'filename to-abs))))))

(defun bookmark-gt--store-preserve-advice (orig-fn name alist no-overwrite)
  "Keep bookmark-gt properties across a `bookmark-store' overwrite.
ORIG-FN is `bookmark-store'; NAME, ALIST and NO-OVERWRITE are its
arguments.

The built-in replaces an existing record wholesale —
`(setcdr bm alist)\=' — which discards the id, tags, annotation,
creation time and visit counts bookmark-gt keeps there.  That
path runs whenever another package stores onto a name it already
used: `org-capture\=' and `org-refile\=' do it on every capture.

Overwrite-by-name is left exactly as it was; only the properties
the caller does not know about are carried across.  See
`bookmark-gt-preserved-props'."
  (let* ((existing (and (not no-overwrite)
                        (bookmark-get-bookmark name 'noerror)))
         (saved (and existing (bookmark-gt--preserved-props existing))))
    (prog1 (funcall orig-fn name alist no-overwrite)
      (when saved
        (when-let* ((record (bookmark-get-bookmark name 'noerror)))
          (bookmark-gt--restore-preserved record saved))))))

(defun bookmark-gt--record-for-display (record)
  "Return RECORD pretty-printed, for a message a user has to read.
The name is copied without text properties: bookmark+ attaches a
snapshot of the whole record to the name string, which would
otherwise be printed inline."
  (pp-to-string (cons (substring-no-properties
                       (bookmark-name-from-full-record record))
                      (bookmark-gt--record-data record))))

(defun bookmark-gt--drop-same-name-violations ()
  "Remove records that `bookmark-gt-allow-same-name-bookmarks' forbids.
Returns the records removed.

`bookmark-gt-create' cannot produce a name the setting forbids,
but other things can: a bookmark file written elsewhere, and the
built-in `bookmark-set', which bookmark-gt leaves alone because
packages call it from Lisp.  Enforcing the setting only at
creation would leave `never' meaning \"no two same-named
bookmarks, unless one arrived some other way\".

Runs from `bookmark-gt-enforce-same-name-policy': after a load,
when the list buffer is opened or reverted, and once per jump.
Not while the list buffer draws — see that function.

The first record of a name is kept.  Under
`different-destination' a later one is kept when it points
somewhere no kept record does.

Not counted as a modification: dropping makes memory match the
setting, it is not an edit the user asked for, and counting it
would schedule the write that makes the omission permanent."
  (let ((seen (make-hash-table :test 'equal))
        (kept nil)
        (dropped nil))
    (dolist (record (reverse bookmark-alist))
      (let* ((name (substring-no-properties
                    (bookmark-name-from-full-record record)))
             (peers (gethash name seen)))
        (if (or (null peers)
                (pcase bookmark-gt-allow-same-name-bookmarks
                  ('always t)
                  ('never nil)
                  (_ (not (seq-find
                           (lambda (other)
                             (bookmark-gt--same-destination-p record other))
                           peers)))))
            (progn (puthash name (cons record peers) seen)
                   (push record kept))
          (push record dropped))))
    (when dropped
      (setq bookmark-alist (reverse kept))
      (display-warning
       'bookmark-gt
       (format
        (concat "%d bookmark(s) omitted: their names repeat, and "
                "`bookmark-gt-allow-same-name-bookmarks' is `%s'.\n\n"
                "%s\n"
                "They are still in %s, and stay there until it is "
                "next saved.  Set the option to `always' and reload "
                "to keep them.")
        (length dropped)
        bookmark-gt-allow-same-name-bookmarks
        ;; The whole record, not just the name: this warning is the
        ;; only copy the user has until they open the file, and a
        ;; name alone does not say which bookmark went.
        (mapconcat #'bookmark-gt--record-for-display dropped "\n")
        (abbreviate-file-name (or bookmark-default-file "the bookmark file")))
       :warning))
    dropped))

(defun bookmark-gt--ensure-ids-advice (&rest _)
  "After advice for `bookmark-load' that reconciles the loaded alist.
`bookmark-load' rebuilds `bookmark-alist' from the file, so it
can hold records another package wrote without an id, and names
that repeat in ways the same-name setting forbids.
Enforces the same-name setting, then assigns ids to what
remains."
  (bookmark-gt-enforce-same-name-policy)
  (bookmark-gt-ensure-ids))

(defun bookmark-gt--save-filter-advice (orig-fn &rest args)
  "Around advice for `bookmark-save' that excludes temp records.
Every call binds `bookmark-alist' to a filtered copy without
records carrying `bookmark-gt-temp-key' before delegating to
ORIG-FN with ARGS.  The user's live alist is untouched — the
filter is only applied to what gets written to disk."
  (let ((bookmark-alist
         (seq-remove #'bookmark-gt-temp-p bookmark-alist)))
    (apply orig-fn args)))

;;;; Auto-temp on store for known transient names
;;
;; Some third-party code stores bookmarks under fixed names that
;; are transient by design (`org-capture-last-stored', updated on
;; every capture; similar patterns exist for other packages).
;; Persisting them clutters the bookmark file with a moving
;; target.  This advice marks such records temp at store time,
;; so the save filter excludes them.

(defcustom bookmark-gt-auto-temp-names
  '("\\`org-capture-last-stored\\'")
  "Bookmark names (regexps) auto-marked temporary on store.
Each element is a regexp matched against the stored name.
When any regexp matches, `bookmark-gt-temp-key' is set on the
record so `bookmark-save' skips it via the temp filter.

Default entry covers `org-capture-last-stored', the bookmark
`org-capture' re-stores on every capture."
  :type '(repeat regexp)
  :group 'bookmark-gt)

(defun bookmark-gt--auto-temp-advice (name &rest _)
  "Mark NAME temp when it matches `bookmark-gt-auto-temp-names'.
Attached as `:after' advice on `bookmark-store' so the record
is marked immediately after storage."
  (when (and (stringp name)
             (seq-some (lambda (pat) (string-match-p pat name))
                       bookmark-gt-auto-temp-names))
    (when-let* ((rec (bookmark-get-bookmark name 'noerror)))
      (bookmark-prop-set rec bookmark-gt-temp-key t))))

;;;; File-type handler dispatch
;;
;; A regexp → function table consulted when jumping a file
;; bookmark.  On match, the associated function is called with
;; the whole bookmark record instead of the built-in
;; `find-file' path.  The function's contract matches a
;; standard `bookmark.el' handler (one argument, the record).
;; See `bookmark-gt-file-type-handlers'.

(defcustom bookmark-gt-file-type-handlers nil
  "Alist mapping filename regexp to a bookmark handler function.
When jumping a file bookmark whose `filename' matches one of
the regexps, the corresponding function is called with the
bookmark record and takes over the jump.  The function's
contract is the same as a standard `bookmark.el' handler: one
argument, the bookmark record; it may read any record prop —
`filename', `position', `tags', and so on.

Entries are tried in order; the first matching regexp wins."
  :type '(alist :key-type regexp :value-type function)
  :group 'bookmark-gt)

(defun bookmark-gt--file-type-handler-advice (orig-fn bookmark &rest args)
  "Around advice for `bookmark-default-handler'.
If BOOKMARK's `filename' matches an entry in
`bookmark-gt-file-type-handlers', call that entry's function
with BOOKMARK.  Otherwise delegate to ORIG-FN with ARGS."
  (let ((filename (bookmark-prop-get bookmark 'filename))
        (matched  nil))
    (when filename
      (dolist (entry bookmark-gt-file-type-handlers)
        (unless matched
          (when (string-match-p (car entry) filename)
            (setq matched (cdr entry))))))
    (if matched
        (funcall matched bookmark)
      (apply orig-fn bookmark args))))

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
(defun bookmark-gt-create (&optional name)
  "Create a bookmark at the current location.

Always creates.  To change where an existing bookmark points,
use `bookmark-gt-update' (to here) or `bookmark-gt-relocate' (to
a target you type).

NAME is the bookmark name.  Interactive calls prompt for it with
the suggested name as editable initial input, completing over the
existing names so a repeat is visible while typing.  Lisp callers
pass a name string, or nil to accept the suggested name without
prompting.

`bookmark-gt-allow-same-name-bookmarks' decides what happens when
the name is already in use.  Returns the stored record."
  (interactive (list bookmark-gt--prompt-name))
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
    (bookmark-gt--create-record chosen data)))

;;;; Update
;;
;; "This bookmark now lives where I am."  Re-captures the location
;; and puts it onto an existing record, which is why it is not a
;; create: the record keeps its name, id, tags, annotation and
;; history.  Only what describes *where* is replaced.

(defconst bookmark-gt-preserved-props
  '(bookmark-gt-id created tags annotation visits last-visited
                  auto-update)
  "Record keys describing which bookmark this is, not where it points.
They survive `bookmark-gt-update' and any overwrite performed by
the built-in `bookmark-store\='.  Everything else comes from the
new capture, which is what removes a previous type\='s leftovers —
a PDF record\='s page data, an org record\='s heading id, a Dired
record\='s marks.

The temporary marker is preserved too; it is not listed here
because its key is the value of `bookmark-gt-temp-key\='.")

(defun bookmark-gt--preserved-props (record)
  "Return the alist of RECORD's properties that survive a rewrite."
  (seq-filter
   #'identity
   (mapcar (lambda (key)
             (when-let* ((cell (assq key (bookmark-gt--record-data record))))
               ;; Not `copy-sequence': these are dotted pairs.
               (cons (car cell) (cdr cell))))
           (cons bookmark-gt-temp-key bookmark-gt-preserved-props))))

(defun bookmark-gt--record-data (record)
  "Return RECORD's alist, whether or not it carries a name."
  (if (stringp (car record)) (cdr record) record))

(defun bookmark-gt--restore-preserved (record saved)
  "Put SAVED properties back onto RECORD unless it already has them."
  (dolist (cell saved record)
    (unless (assq (car cell) (cdr record))
      (setcdr record (cons cell (cdr record))))))

(defun bookmark-gt--buffer-backed-p (record)
  "Return non-nil when RECORD points at a place a buffer can be at.
URL, function, kmacro and sequence bookmarks have no position to
re-capture, so `bookmark-gt-update' cannot act on them."
  (not (seq-some (lambda (key) (bookmark-prop-get record key))
                 '(url location function kmacro sequence))))

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
(defun bookmark-gt-delete (&optional bookmark)
  "Delete BOOKMARK.
BOOKMARK is a record, a name, or an id; nil prompts.  Deletes the
record referred to, not the first record sharing its name.

Reports any sequence bookmark that references it: the reference
becomes a broken one, and that is worth knowing before rather
than at the next jump."
  (interactive)
  (bookmark-maybe-load-default-file)
  (let* ((record (bookmark-gt--resolve bookmark "Delete bookmark"))
         (name (bookmark-name-from-full-record record))
         (referrers (bookmark-gt--sequences-referencing record)))
    (when referrers
      (message "`%s' was referenced by %d sequence bookmark(s): %s"
               name (length referrers)
               (mapconcat #'bookmark-name-from-full-record referrers ", ")))
    (bookmark-gt-delete-record record)
    (bookmark-gt--after-mutation record 'delete)
    record))

(defun bookmark-gt--sequences-referencing (record)
  "Return the sequence bookmarks whose members include RECORD."
  (let ((id (bookmark-gt-id-of record))
        (name (bookmark-name-from-full-record record)))
    (seq-filter
     (lambda (other)
       (and (not (eq other record))
            (let ((members (bookmark-prop-get other 'sequence)))
              (and (listp members)
                   (seq-some (lambda (member)
                               (or (and id (eq member id))
                                   (equal member name)))
                             members)))))
     bookmark-alist)))

;;;###autoload
(defun bookmark-gt-rename (&optional bookmark new-name)
  "Rename BOOKMARK to NEW-NAME.
BOOKMARK is a record, a name, or an id; nil prompts.  Renames the
record referred to, not the first record sharing its name.

NEW-NAME is checked against
`bookmark-gt-allow-same-name-bookmarks' the same way a new
bookmark\='s name is, so renaming cannot produce a state that
creating one could not."
  (interactive)
  (bookmark-maybe-load-default-file)
  (let* ((record (bookmark-gt--resolve bookmark "Rename bookmark"))
         (old (bookmark-name-from-full-record record))
         (new (or new-name
                  (read-from-minibuffer (format-prompt "Rename `%s' to" nil old)
                                        old nil nil 'bookmark-history))))
    (unless (equal new old)
      (bookmark-gt--check-name-available new (cdr record))
      (bookmark-gt-rename-record record new))
    record))

;;;; Relocate
;;
;; Interactive "change where this bookmark points" command.
;; File records read a new path via `read-file-name'; records
;; carrying a `url' key read a new URL via `read-string'.
;; Position is left unchanged — the common trigger for
;; relocation is a file rename, where the offset is still valid.
;; For a genuinely different location the user can jump into
;; the new file, place point, and use `bookmark-gt-update';
;; the same-name-overwrite policy updates `position' in place.

;;;###autoload
(defun bookmark-gt-relocate (&optional bookmark)
  "Change the target of BOOKMARK.
File bookmarks prompt for a new filename with `read-file-name'
and keep the current position.  Records with a `url' key
prompt for a new URL.  Records with neither signal a
`user-error'.  Fires `bookmark-gt-record-changed-hook'.

BOOKMARK is a record, a name, or an id; nil prompts.  A name
shared by several bookmarks asks which one rather than taking
the first."
  (interactive)
  (let* ((entry    (bookmark-gt--resolve bookmark "Relocate bookmark"))
         (label    (bookmark-name-from-full-record entry))
         (filename (bookmark-prop-get entry 'filename))
         (url      (bookmark-prop-get entry 'url)))
    (cond
     (filename
      (let* ((new (expand-file-name
                   (read-file-name
                    (format "Relocate `%s' to file: " label)
                    (file-name-directory filename)
                    filename nil (file-name-nondirectory filename))))
             (was (bookmark-gt-handler-name entry))
             (now (bookmark-gt-handler-name
                   (cons label (cons (cons 'filename new)
                                     (assq-delete-all
                                      'filename
                                      (copy-sequence (cdr entry))))))))
        ;; Relocate moves a bookmark of one kind to another target
        ;; of that kind.  Pointing a PDF record at an org file
        ;; would leave the PDF handler on a file it cannot open;
        ;; changing a bookmark's type is what `bookmark-gt-update'
        ;; is for.
        (unless (equal was now)
          (user-error
           "`%s' is a %s bookmark; %s would make it a %s bookmark — use `%s'"
           label was (abbreviate-file-name new) now "bookmark-gt-update"))
        (bookmark-prop-set entry 'filename new)))
     (url
      (let ((new (read-string
                  (format "Relocate `%s' URL: " label) url)))
        (bookmark-prop-set entry 'url new)))
     (t
      (user-error
       "bookmark-gt-relocate: `%s' has neither `filename' nor `url'"
       label)))
    (unless (bookmark-gt-temp-p entry)
      (bookmark-gt--note-modification))
    (bookmark-gt--after-mutation entry 'relocate)
    entry))

(provide 'bookmark-gt-core)


;; Local Variables:
;; package-lint-main-file: "bookmark-gt.el"
;; End:

;;; bookmark-gt-core.el ends here
