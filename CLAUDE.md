# CLAUDE.md — bookmark-gt

Instructions for future agents editing this package.  The
package's user-facing documentation lives in `readme.org` (and
its generated `docs/bookmark-gt.info` / `docs/bookmark-gt.pdf`);
this file is only for agents.

## Read first

- `readme.org` — every user-visible feature, command, defcustom,
  and keybinding.  Read this before answering "does bookmark-gt
  support X?" or before adding a new user-facing feature.
- `ai/architecture.md` — design decisions and non-obvious
  constraints (records-only, direct calls vs hooks, handler
  registry, mutation notification path).
- `ai/conventions.md` — naming, docstring style, wording rules
  that apply here on top of the global user preferences.

## Absolute rules

1. **Never `git commit`.**  The user commits.  Never invoke
   `git commit` or `git push`.  If work is ready for a commit,
   say so and stop.
2. **Confirm before implementing.**  Non-trivial edits: describe
   the approach in one or two sentences, wait for the go-ahead.
   Simple typos/renames/one-liners don't need this.
3. **Hooks are for external extension, not for our own wiring.**
   Public hooks (`bookmark-gt-set-after-hook`,
   `bookmark-gt-set-name-reader-hook`,
   `bookmark-gt-set-tag-reader-hook`) ship empty at
   distribution.  Bookmark-gt's own cross-module coordination is
   direct function calls, not `add-hook` on our own hooks.
   `bookmark-gt--after-mutation` in `bookmark-gt-core.el` is the
   central notifier; every internal mutator calls it directly.
4. **Precise, non-metaphorical language everywhere** — code,
   docstrings, comments, commit messages, `readme.org`, chat
   replies.  No "clean", "elegant", "pragmatic", "surfaces",
   "steals focus", "clobbers", "silently drops" (drop → omit
   from display; do not conflate omission with removal).  See
   `ai/conventions.md`.
5. **Docstrings state what and how to use — not why we chose
   this design.**  Rationale belongs in `ai/`.  Long design
   notes in docstrings rot.

## Workflow

### Test before saying "done"

```
make clean && make check-30 && make test
```

`make check-30` runs byte-compile with `-Werror`, package-lint,
checkdoc, check-declare, and check-version.  `make test` runs
the ERT suite.  Both must exit 0.

`make check-all` runs `check-30` and `check-31` — do this before
you say the change is safe on both Emacs versions.

### Live-reload during interactive development

The user runs Emacs continuously.  After editing an `.el` file,
reload just the changed file(s) into their session so behavior
updates without a restart:

```
emacsclient -e '(load "/Users/dmg/.emacs.d/modules/bookmark-gt/bookmark-gt-<name>.el" nil t)'
```

Defcustom values already set do not update on `load`; use
`customize-set-variable` from `emacsclient -e`.  Keymap
`defvar-keymap` blocks do not re-evaluate on `load` either;
patch bindings via `define-key`.

### Documentation

- Source of truth: `readme.org` at the repo root.
- Build: `make info pdf` (writes `docs/bookmark-gt.info` and
  `docs/bookmark-gt.pdf`; intermediates are removed on success).
- After any user-facing change (new command, new defcustom, new
  key), update `readme.org` and rebuild the docs.

### Adding a new bookmark type / handler

1. Define `bookmark-gt-handler-<type>-jump` in the right module
   (or in `bookmark-gt-handlers.el` if it's generic).  Handlers
   that open an external target should call
   `bookmark-gt-record-visit` and then
   `bookmark-gt-skip-post-handler` at the end of their body.
2. Register in `bookmark-gt-handler-alist` via
   `bookmark-gt-handler-register`.  Include any handler-symbol
   aliases (bookmark+ variants, ecosystem packages) that should
   classify as the same type.
3. Add an interactive setter if the type isn't produced by an
   existing `bookmark-make-record-function`.
4. Add tests under `test/` (classify + jump behavior).
5. Document in `readme.org` under **Non-file bookmark types**.

### Adding a list-buffer command

- Row-scoped commands (act on the bookmark at point): name as
  `bookmark-gt-list-<verb>-<noun>` (e.g. `-toggle-temp`,
  `-rename`, `-relocate`).  Bind and document in the
  `bookmark-gt-list-mode` docstring.
- Display-scoped commands (change what the buffer shows without
  changing records): name as `bookmark-gt-list-show-<noun>`
  (e.g. `-show-temp`).  This prefix makes it obvious to the
  reader that the command is about visibility, not the
  underlying data.

## Module layout

| File | Contents |
|---|---|
| `bookmark-gt.el` | Master module; requires the rest; defines `bookmark-gt-mode` (the global switch that installs every advice/hook). |
| `bookmark-gt-core.el` | Records, mutation notifier, extension hooks (empty at distribution), same-name policy, region bookmarks, visit tracker, rename tracker, highlight overlays, cycling, `bookmark-gt-set`, `bookmark-gt-relocate`. |
| `bookmark-gt-handlers.el` | Handler registry, groups, face definitions, URL / Dired / function / sequence handlers and setters. |
| `bookmark-gt-tags.el` | Tag reader, tag mutation API, defcustom `bookmark-gt-prompt-for-tags-flag`. |
| `bookmark-gt-default-tags.el` | Opt-in mode that seeds the tag reader from context. |
| `bookmark-gt-list.el` | `*Bookmarks-gt List*` buffer (tabulated-list-mode derivative). |
| `bookmark-gt-jump.el` | Jump reader (consult / marginalia / orderless integrations, all soft-deps). |
| `bookmark-gt-auto-update.el` | Opt-in mode that refreshes bookmarks with `auto-update` prop. |
| `bookmark-gt-browser-tabs.el` | Opt-in mode that stores live browser tabs as temporary URL bookmarks (marker: `bookmark-gt-browser-tab`). |
| `test/` | ERT suite.  Every test wraps its body in `bookmark-gt-test-with-clean-bookmarks`. |

## Common pitfalls

- **Editing `bookmark-alist` directly** in a mutator: prefer
  `bookmark-prop-set` / `bookmark-gt-tags-set` / etc.  After
  mutation, call `bookmark-gt--after-mutation` (or use a
  wrapper that does — `bookmark-gt-set`, `-set-non-file`,
  `-relocate`, `bookmark-gt-tags-set`).
- **Batch mutations** (many records in one loop): pass
  `NO-NOTIFY` non-nil to `bookmark-gt-set-non-file` inside the
  loop and call the UI refresh once at end (browser-tabs is the
  reference example).
- **Byte-compile order**: `bookmark-gt-core.el` compiles before
  the modules that define functions it calls at runtime.  Use
  `declare-function` for cross-module calls (already in place
  for `bookmark-gt-list-refresh`, `bookmark-gt-tags-read`,
  `bookmark-gt-default-tags--hook`).
- **Interactive `bookmark-gt-set` with no handler set by the
  mode**: for modes bookmark-gt owns the canonical handler for
  (currently: Dired), force the handler in `bookmark-gt-set`
  so classification is unambiguous on disk.  See the
  `derived-mode-p 'dired-mode` clause.
- **Handler aliases in the registry**: symbols like
  `bmkp-jump-url-browse`, `bmkp-jump-dired`,
  `bmkp-gt-browsel-tabs-jump` (from the retired browsel package) are registered so records
  from other packages classify correctly.  These are quoted
  symbols in a data table — bookmark-gt does not depend on
  those packages being loaded.

## Extension surface (what third parties may add to)

- `bookmark-gt-set-after-hook` — post-mutation observers.
- `bookmark-gt-set-name-reader-hook` — refine the default name.
- `bookmark-gt-set-tag-reader-hook` — contribute to the tag
  pipeline.
- `bookmark-gt-jump-before-read-hook` — refresh a candidate
  pool before the jump reader displays.  Fires once per outer
  `bookmark-gt-jump*` call; contributors run synchronously in
  order.  Used by `bookmark-gt-browser-tabs-mode` to refresh
  live browser tabs per jump.
- `bookmark-gt-handler-alist` — register a handler symbol under
  a type (via `bookmark-gt-handler-register`).
- `bookmark-gt-group-alist` — register a new group.
- `bookmark-gt-filter-alist` — add a filter to the list buffer.
- `bookmark-gt-sort-alist` — add a sort predicate.
- `bookmark-gt-jump-candidate-format-function` — replace the
  jump reader's row formatter.

All of the above ship empty (or with only the bookmark-gt
defaults) — no internal bookmark-gt code registers into the
hooks.
