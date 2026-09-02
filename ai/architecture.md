# bookmark-gt — architecture notes

Read `CLAUDE.md` first; this file goes deeper into the why of
non-obvious design choices.

## Records-only invariant

Every fact about a bookmark lives on the bookmark's own alist
entry.  No side tables (no separate hash of tags keyed by
name, no separate visit counter file, no shadow store).
Consequences:

- Save/load round-trips are complete without extra migration
  steps.
- A record deleted from `bookmark-alist` needs no cleanup
  elsewhere.
- Adding a new per-bookmark fact = adding an alist key.  No
  new registry needed.

Exceptions, process-scoped only — each is bounded by the
lifetime of a buffer or a single call, and none survives to
disk:

- Buffer-local hash for list-buffer marks
  (`bookmark-gt-list--marks`).  Bounded by the buffer's
  lifetime.
- Buffer-local hash for post-jump positions used by the
  highlighter (`bookmark-gt-highlight--jumped-positions`).
  Bounded by the buffer's lifetime.
- The `bookmark-gt-browser-tabs--refreshing` re-entrancy
  guard.  Bounded by one refresh call.

## Bookmark identity

A bookmark has two natural handles and neither is sufficient:

- **The record cons.** Precise and `eq`-comparable, and what
  `bookmark-alist` holds. Session-scoped: `bookmark-load`
  builds fresh conses, so it cannot be written to disk or held
  across a reload. `bookmark-maybe-load-default-file` reloads
  whenever the file's mtime changed, and with
  `bookmark-watch-bookmark-file` set to `silent` it does so
  without asking — so a cons captured before almost any command
  can be an orphan, and mutating it writes to something no
  longer in the alist.
- **The name.** Persists, but is neither unique (records may
  share one) nor stable (`bookmark-rename` changes it).
  `bookmark-get-bookmark` resolves a name with `assoc`, so
  anything built on a name reaches the first record carrying it.

`bookmark-gt-id` is the third: an interned symbol on the record,
durable and precise. The key is namespaced because plain `id`
belongs to `org-bookmark-heading`, whose handler reads it.

**It is best-effort, never an invariant.** Records written by
`bookmark.el`, bookmark+ or anything else arrive without one, and
a file copied between machines can carry the same id twice. Code
resolves by id when present and by name otherwise; it must not
assume presence or uniqueness.

### Why the id is a symbol

A bookmark name is always a string — `bookmark-store` copies it
and strips its text properties — so a symbol cannot be a name.
That makes `bookmark-gt--resolve`'s dispatch total rather than a
guess: nil, cons, string, symbol, one meaning each.

The `bgt-` prefix is structural, not decoration: it guarantees
the printed form reads back as a symbol. A body of digits alone
would read as an integer and fall through the dispatch silently.

Non-determinism is deliberate. A content-derived id would let two
machines minting the same file agree, but it cannot distinguish
two records that are identical apart from identity — the case the
id exists for — and an id that looks computable invites someone
to recompute it instead of reading it, which is identity-by-
content again.

### Where identity is enforced

Two passes, deliberately separate.

`bookmark-gt-ensure-ids` assigns ids and converts sequence
members. It removes nothing, so it is safe to run while the list
buffer is being drawn — which it is, from
`bookmark-gt-list--entries`.

`bookmark-gt-enforce-same-name-policy` removes records the
same-name setting forbids and reports sequences whose members
stopped resolving. It runs at *operations*: after
`bookmark-load`, when the list buffer is opened or reverted, and
once per jump reader. Never during a redraw — a redraw follows
every change, so enforcing there would let a change to one
bookmark delete another, and open a warning window while doing
it.

Enforcing beyond creation is what makes the setting mean what it
says. `bookmark-gt-create` cannot produce a forbidden name, but a
bookmark file can, and so can the built-in `bookmark-set`, which
is deliberately left alone for Lisp callers.

Assignment writes with `bookmark-prop-set`, never through the
mutators: `bookmark-gt--after-mutation` would run the change hook
once per record, and `bookmark-gt--stamp-modified` would
overwrite `last-modified` on every record with the time of the
scan. It counts one modification for the whole pass, with
`NO-SAVE`, and none for temporary records — so loading a file
does not provoke a write.

Dropping is not counted at all. It makes memory match the
setting rather than being an edit the user asked for, and
counting it would schedule the write that turns an omission in
memory into a deletion on disk.

### Display names are computed

Records sharing a name are shown with a `<N>` suffix, computed by
`bookmark-gt-display-name-of` and never stored. Storing it would
make every name unique behind the user's back, which is what
allowing shared names exists to avoid.

Bulk callers wrap their loop in `bookmark-gt-with-name-index`;
without it, asking per record turns a render quadratic.

### What the built-ins are allowed to do

Only the *commands* are remapped (`bookmark-gt-mode-map`). The
functions keep their own semantics, because packages call them
from Lisp and depend on them: `org-capture` and `org-refile`
store onto a fixed name on every capture and rely on
`bookmark-set` overwriting by name. Such a name is a singleton by
construction, so first-match resolution is correct there.

One advice guards the data: `bookmark-store`'s overwrite path is
`(setcdr bm alist)`, which discards every bookmark-gt property on
the record. `bookmark-gt--store-preserve-advice` carries the
`bookmark-gt-preserved-props` set across, leaving the built-in's
own behavior untouched.

## Direct calls over hooks for internal wiring

Hooks in bookmark-gt are **external extension surface only**.
Internal cross-module coordination is direct calls.  Rationale
and history:

- The original design registered internal observers into
  the after-set hook (the list refresh, the highlight
  refresh), then had ephemeral sources (browser-tabs,
  auto-update) fire a shared `bookmark-gt-ephemeral-refresh-hook`.
  This produced invisible control flow: reading a mutator, you
  couldn't tell what would run afterwards without grepping
  `add-hook` calls across five files.
- The performance bug this created was concrete: browser-tabs
  refresh fired the after-hook with a `nil` sentinel to mean
  "batch mutation," which cascaded into the highlighter's
  full-buffer sweep — 840 ms per browser-tab refresh in a session
  with ~130 file buffers and ~120 bookmarks.  A sentinel hack
  patched the symptom but muddied the contract.
- The refactor replaced the sentinel and the ephemeral hook
  with direct calls.  `bookmark-gt--after-mutation (entry)` in
  `bookmark-gt-core.el` is the single notifier — it refreshes
  the list, refreshes the highlight for records with a
  filename, then runs the public
  `bookmark-gt-record-changed-hook`.  Every mutator calls it.
  The browser-tabs refresh calls `bookmark-gt-list-refresh`
  directly at the end of its batch.
- End result: 840 ms → 40 ms browser-tab refresh, ~330 fewer lines
  of code, and every internal action is visible at the call
  site.

**Test for future changes**: if you find yourself adding an
`add-hook` on a bookmark-gt hook from bookmark-gt code, ask
whether a direct call would work.  It almost always does.

## Mutation notification path

Every internal mutator ends with `(bookmark-gt--after-mutation
entry OPERATION)`, where OPERATION names what happened —
`create`, `update`, `relocate`, `rename`, `tags`, `temp`,
`auto-update`, `delete`.  The helper:

1. Calls `bookmark-gt-list-refresh` — redraws every live list
   buffer.  No-op when no list buffer exists.
2. Calls `bookmark-gt-highlight-refresh entry` — no-op unless
   `entry` has a `filename` that matches a live buffer.
3. Runs `bookmark-gt-record-changed-hook` for third-party
   observers, with the record and the operation symbol (empty at
   distribution).

Batch callers that would otherwise notify per-record pass
`NO-NOTIFY` non-nil to `bookmark-gt-create-non-file` and call
`bookmark-gt-list-refresh` once at end.  See
`bookmark-gt-browser-tabs-refresh` for the pattern.

## Modification accounting is separate from notification

`bookmark-gt--after-mutation` refreshes the UI; it does not
touch `bookmark-alist-modification-count`.  Counting is a
separate decision, made by `bookmark-gt--note-modification`,
because the count means "changes not yet written to the bookmark
file" and drives two writes in built-in `bookmark.el`: the
threshold save at `bookmark-save-flag`, and the unconditional
save from `kill-emacs-hook` whenever the count is above zero.

The rule: count a change only when it alters what
`bookmark-save` would write.

- Storing, relocating, or removing a record carrying
  `bookmark-gt-temp-key` does not count.  The save filter
  removes temp records before the file is produced, so the write
  such a change would schedule cannot alter the file.  Before
  this rule existed, one browser-tab refresh set the count to
  the number of tabs and Emacs rewrote the bookmark file at
  exit with identical content.
- A record entering or leaving the temp state does count, in
  both directions: it becomes eligible for the file, or stops
  being eligible.
- Visit tracking does not count — see
  `bookmark-gt-record-visit`.  That is a different reason:
  the data does belong in the file, but a save per jump is too
  expensive to be worth it.

`bookmark-gt--note-modification` takes `NO-SAVE` for loops that
change many records; the loop counts each one and the caller
runs `bookmark-gt--maybe-auto-save` once at the end
(`bookmark-gt-list-toggle-temp` is the reference example).

## Handler registry

`bookmark-gt-handler-alist` maps handler symbols to display
metadata (`:type`, `:name`, `:group`, `:face`, `:narrow-char`,
`:doc`, optional `:preview`).  Two roles:

- **Own handlers**: bookmark-gt ships handler bodies for URL,
  Dired, function, sequence.  Registry entry lists the own
  handler symbol plus any historic aliases from bookmark+
  (`bmkp-jump-*`) so records from either format classify
  consistently.
- **Third-party handlers**: for types that other packages own
  the handler for (EWW, Info, Org, PDF, etc.), the registry
  entry lists the third-party symbol.  We do not depend on those
  packages being loaded — the symbols are quoted data.
- **Retired-package aliases**: symbols from packages no longer
  used, kept so records written by them still classify.
  `bmkp-gt-browsel-tabs-jump` is the current example — browsel
  is retired (browser tabs now come from `browser-gt`), but
  records created under it survive in users' bookmark files.
  `bookmark-gt-migrate.el` rewrites the handler; the registry
  entry covers records that were never migrated.

Unknown handlers auto-classify via `bookmark-gt-handler-classify`'s
derive-fallback, which strips common suffixes
(`-bookmark-jump-handler`, `-bookmark-jump`, `-jump-handler`,
`--handle-bookmark`) and title-cases the leading segment.

## Same-name policy

One custom, `bookmark-gt-allow-same-name-bookmarks`, deciding
when `bookmark-gt-create` may reuse a name: `never`,
`different-destination` (the default), `always`.  Nothing else
consults it.

A forbidden name is refused with an error, never stored as
`NAME<2>`: a stored suffix would make every name unique behind
the user's back, which is what allowing shared names exists to
avoid.  The `<N>` a user sees is computed for display — see
"Display names are computed" above.

It replaced two booleans, `bookmark-gt-same-name-overwrite` and
`bookmark-gt-allow-duplicate-names`, which together encoded a
policy nobody could state.  The first was the worse of the two:
its name said the trigger was a name match, but the trigger was
a name match *at the same destination*, and what it selected was
whether re-setting a bookmark updated it or created a second.
That decision is now made by which command is invoked —
`bookmark-gt-create` or `bookmark-gt-update` — which is
something the user knows and a variable never did.

## Browser tabs are URL bookmarks

Tab records created by `bookmark-gt-browser-tabs-mode` use
`handler = bookmark-gt-handler-url-jump`.  Tabs are fetched
from `browser-gt` over its WebSocket bridge; the module is a
no-op when `browser-gt` is absent (`(require 'browser-gt nil t)`).

Two independent markers apply:

- `bmkp-temp = t` — this record is transient; the temp-save
  filter removes it from `bookmark-save` output.  Any temporary
  record carries this, not just browser tabs.
- `bookmark-gt-browser-tab = t` — this record was created by
  the browser-tabs module.  `bookmark-gt-browser-tabs--own-record-p`
  reads this and only this, so `--clear` removes only our
  records on refresh and leaves URL bookmarks the user created
  by hand untouched.

Records also carry `browser-gt-id` and `browser-gt-browser`,
identifying the live tab and its client.  Both are session-only
(see `bookmark-gt-session-only-props`) and are removed when a
tab record stops being temporary.

Rationale for the unified handler: the URL handler already
calls `browse-url`, and the user's
`browse-url-browser-function` provides any focus-existing-tab
behavior without bookmark-gt needing to know about it.
Duplicating `browse-url` dispatch inside a dedicated handler
was redundant.

## bookmark-gt owns the Dired handler at set time

Built-in Dired's `bookmark-make-record-function` produces a
record with no `handler` field — the directory is stored as a
plain file bookmark, and jumping happens to work because
`find-file` on a directory opens Dired.  This means a fresh
`bookmark-gt-create` in a Dired buffer classifies as type "File"
in our registry (handler=nil maps to file), which is
misleading.

`bookmark-gt-create` therefore forces `handler =
bookmark-gt-handler-dired-jump` whenever `derived-mode-p
'dired-mode` is true, overriding whatever the built-in
`bookmark-make-record-function` produced.  The record is
unambiguous on disk (`handler` is explicit) and classifies as
"Dired" via the registry.

This is the only place `bookmark-gt-create` inspects
`major-mode`.  The pattern applies to any future case where
bookmark-gt owns the canonical handler for a mode whose
`bookmark-make-record-function` does not set one.  Modes with
their own handlers (EWW's `eww-bookmark-jump`, PDF's
`pdf-view-bookmark-jump-handler`, Org's
`org-bookmark-heading-jump`, etc.) do not need this treatment
— the record's `handler` field already identifies the type.

## Skip post-handler mechanism

Handlers that open external targets (URL bookmarks, browser
tabs) throw `bookmark-gt-skip-post-handler` at the end of
their body, via the macro of the same name.  An `:around`
advice on `bookmark--jump-via` wraps its body in a catch for
that tag, so the throw skips the built-in
`bookmark-after-jump-hook` and the annotation-buffer popup.

When `bookmark-gt-mode` is off, the advice isn't installed and
the throw signals `no-catch`, which the macro's
`condition-case` swallows.  Handlers can call the macro
unconditionally.

Handlers that throw also call `bookmark-gt-record-visit`
themselves at their tail — they're bypassing the after-jump
hook so the visit tracker (which lives on that hook) wouldn't
otherwise run.

## Refresh policy

Ephemeral sources are rebuilt where they are about to be read,
not kept in sync:

- **Each `bookmark-gt-jump` call**, for browser tabs.
  `bookmark-gt-browser-tabs-mode` adds its refresh to
  `bookmark-gt-jump-before-read-hook`, which the reader runs
  exactly once per outer call, so nested jump calls do not
  re-refresh.
- **`g` (revert) in the list buffer.** `bookmark-gt-list--revert`
  calls `bookmark-gt-browser-tabs-refresh` and
  `bookmark-gt-auto-update-tick` directly, each gated by a
  `bound-and-true-p` check on its opt-in mode.
- **On demand**, and once when the tabs mode is enabled with a
  browser already connected.

The initial list render does not refresh: `bookmark-gt-list`
calls `tabulated-list-print`, not `revert-buffer`.

The browser-tabs module previously also subscribed to
browser-gt's client connect and disconnect hooks, with a
debounce timer to coalesce bursts. That was removed: tabs open,
close and retitle without any client connecting, so the events
were neither necessary nor sufficient for freshness, and the
refreshes they caused rebuilt records nothing was about to
display. `bookmark-gt-auto-update-mode`'s idle timer remains —
it tracks a position in a buffer the user is editing, which has
no read-time to attach to.

### The jump hook is a deliberate exception to "direct calls over hooks"

This is the one place bookmark-gt code adds to a bookmark-gt
hook, contradicting the test stated above.  The reason is
dependency direction: `bookmark-gt-jump.el` must not know the
browser-tabs module exists, since that module is opt-in and
requires an external package.  A direct call would invert the
dependency.  The hook keeps the jump reader independent while
letting an opt-in module participate.

If a second module ever registers here, the cost becomes a
per-jump refresh chain — the failure mode that motivated the
direct-call rule.  Treat further registrations as needing
justification.
