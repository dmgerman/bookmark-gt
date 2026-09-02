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

## Direct calls over hooks for internal wiring

Hooks in bookmark-gt are **external extension surface only**.
Internal cross-module coordination is direct calls.  Rationale
and history:

- The original design registered internal observers into
  `bookmark-gt-set-after-hook` (the list refresh, the highlight
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
  filename, then runs the public `bookmark-gt-set-after-hook`.
  Every mutator calls it.  Browsel-tabs refresh calls
  `bookmark-gt-list-refresh` directly at end of batch.
- End result: 840 ms → 40 ms browser-tab refresh, ~330 fewer lines
  of code, and every internal action is visible at the call
  site.

**Test for future changes**: if you find yourself adding an
`add-hook` on a bookmark-gt hook from bookmark-gt code, ask
whether a direct call would work.  It almost always does.

## Mutation notification path

Every internal mutator ends with `(bookmark-gt--after-mutation
entry)`.  The helper:

1. Calls `bookmark-gt-list-refresh` — redraws every live list
   buffer.  No-op when no list buffer exists.
2. Calls `bookmark-gt-highlight-refresh entry` — no-op unless
   `entry` has a `filename` that matches a live buffer.
3. Runs `bookmark-gt-set-after-hook` for third-party observers
   (empty at distribution).

Batch callers that would otherwise notify per-record pass
`NO-NOTIFY` non-nil to `bookmark-gt-set-non-file` and call
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

Two customs, both default `t`:

- `bookmark-gt-same-name-overwrite` — same name + same handler +
  same filename replaces the existing record in place.
- `bookmark-gt-allow-duplicate-names` — otherwise, two records
  may share a literal name (no `<N>` suffix appended).

Both flags on = the current default.  Either flag off falls
back to `<N>` suffix disambiguation for the affected case.
`C-u M-x bookmark-gt-set` forces `<N>` regardless of the
flags.

**Duplicate-name caveat**: Emacs's `bookmark-get-bookmark NAME`
uses `assoc` — returns the first match.  When multiple records
share a name, only one is reachable by name lookup.  The
bookmark-gt list buffer and jump reader iterate the alist
directly and show all records distinguished by the Location
column.

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
`bookmark-gt-set` in a Dired buffer classifies as type "File"
in our registry (handler=nil maps to file), which is
misleading.

`bookmark-gt-set` therefore forces `handler =
bookmark-gt-handler-dired-jump` whenever `derived-mode-p
'dired-mode` is true, overriding whatever the built-in
`bookmark-make-record-function` produced.  The record is
unambiguous on disk (`handler` is explicit) and classifies as
"Dired" via the registry.

This is the only place `bookmark-gt-set` inspects
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

Refresh of ephemeral sources (browser tabs, auto-update
positions) happens at three points, and nowhere else:

- **`g` (revert) in the list buffer.**
  `bookmark-gt-list--revert` calls
  `bookmark-gt-browser-tabs-refresh` and
  `bookmark-gt-auto-update-tick` directly, each gated by a
  `bound-and-true-p` check on its opt-in mode.
- **Each `bookmark-gt-jump` call**, for browser tabs only.
  `bookmark-gt-browser-tabs-mode` adds its refresh to
  `bookmark-gt-jump-before-read-hook`
  (`bookmark-gt-browser-tabs.el:335`), which the reader runs
  exactly once per outer call (`bookmark-gt-jump.el:518`), so a
  live tab list is current when the prompt displays and nested
  jump calls do not re-refresh.
- **`M-x bookmark-gt-browser-tabs-refresh`**, explicitly.

The initial list-buffer render does not refresh:
`bookmark-gt-list` calls `tabulated-list-print`, not
`revert-buffer`.

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
