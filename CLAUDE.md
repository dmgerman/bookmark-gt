# CLAUDE.md — bookmark-gt

Instructions for future agents editing this package.  The
package's user-facing documentation lives in `readme.org` (and
its generated `bookmark-gt.info` and `dir` at the repo root);
this file is only for agents.

## Read first

- `readme.org` — every user-visible feature, command, defcustom,
  and keybinding.  Read this before answering "does bookmark-gt
  support X?" or before adding a new user-facing feature.
- `ai/architecture.md` — design decisions and non-obvious
  constraints (records-only, module layering and hooks, handler
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
3. **A module calls only functions of modules it requires.**
   Each module has a layer number: 1 core; 2 tags; 3 handlers;
   4 list and jump; 5 auto-update, browser-tabs and migrate;
   6 `bookmark-gt.el`.  A module requires only modules with a
   lower number.  When a module must cause code in a module
   with a higher number to run, it runs a hook and the
   higher-numbered module adds its function to that hook — from
   its minor mode when it has one, so turning the mode off
   removes it.  Never `declare-function` a bookmark-gt function
   from another bookmark-gt file, and never call a function of a
   higher-numbered module behind an `fboundp` check.  Every hook
   bookmark-gt code adds to is listed in `ai/architecture.md`
   ("Module layering and hooks"); update that list when you add
   one.  The public hooks
   `bookmark-gt-record-changed-hook`,
   `bookmark-gt-create-name-reader-hook` and
   `bookmark-gt-create-tag-reader-hook` are for third parties
   only: bookmark-gt code never adds to them.
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
checkdoc, check-declare, check-forward-declares, the ERT suite,
melpazoid, and check-version.  `make test` runs the ERT suite on
its own.  Both must exit 0.

Compile, lint, checkdoc, and check-declare run in `.elpa-melpa`,
which holds only what MELPA's checker installs (Package-Requires
plus package-lint and pkg-info).  The soft deps in `DEPS`
(marginalia, consult, orderless) are installed only into `.elpa`
for the tests.  Do not add a soft dep to the MELPA environment to
remove a warning: that hides the warning MELPA reports.

`make melpazoid` runs the upstream melpazoid.el on the files that
`melpa/bookmark-gt` selects, under Emacs 31.1, the way the MELPA
reviewers' container does (needs network).  Its output is what
the MELPA PR review shows.

`make check-all` runs `check` under Emacs 30 and Emacs 31, then
melpazoid once (melpazoid always runs under Emacs 31.1) — do this
before you say the change is safe on both Emacs versions.

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
- Build: `make info` (writes `bookmark-gt.info` and `dir` at the
  repo root; both are committed).
- After any user-facing change (new command, new defcustom, new
  key), update `readme.org` and rebuild the docs.

### Adding a new bookmark type / handler

1. Define `bookmark-gt-handler-<type>-jump` in the right module
   (or in `bookmark-gt-handlers.el` if it's generic).  The
   handler does not record the visit: `bookmark-after-jump-hook`
   does that for every jump.
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
| `bookmark-gt.el` | Master module; requires the rest; defines `bookmark-gt-mode` (the global switch that installs every advice/hook), `bookmark-gt-create`, `bookmark-gt-update`, and the `bookmark-store` advice. |
| `bookmark-gt-core.el` | Records, mutation notifier, extension hooks (empty at distribution), same-name policy, region bookmarks, visit tracker, rename tracker, highlight overlays, cycling. |
| `bookmark-gt-handlers.el` | Handler registry, groups, face definitions, URL / Dired / function / sequence handlers and setters, `bookmark-gt-relocate`. |
| `bookmark-gt-tags.el` | Tag reader, tag mutation API, defcustom `bookmark-gt-prompt-for-tags-flag`, opt-in `bookmark-gt-default-tags-mode` that seeds the tag reader from context. |
| `bookmark-gt-list.el` | `*Bookmarks-gt List*` buffer (tabulated-list-mode derivative). |
| `bookmark-gt-jump.el` | Jump reader (consult / marginalia / orderless integrations, all soft-deps). |
| `bookmark-gt-auto-update.el` | Opt-in mode that refreshes bookmarks with `auto-update` prop; `bookmark-gt-list-toggle-auto-update` (`^` in the list). |
| `bookmark-gt-browser-tabs.el` | Opt-in mode that stores live browser tabs as temporary URL bookmarks (marker: `bookmark-gt-browser-tab`). |
| `test/` | ERT suite.  Every test wraps its body in `bookmark-gt-test-with-clean-bookmarks`. |

## Common pitfalls

- **Editing `bookmark-alist` directly** in a mutator: prefer
  `bookmark-prop-set` / `bookmark-gt-tags-set` / etc.  After
  mutation, call `bookmark-gt--after-mutation` (or use a
  wrapper that does — `bookmark-gt-create`,
  `bookmark-gt-create-non-file`, `bookmark-gt-relocate`,
  `bookmark-gt-tags-set`).
- **Batch mutations** (many records in one loop): pass
  `NO-NOTIFY` non-nil to `bookmark-gt-create-non-file` inside the
  loop and redraw once at the end (browser-tabs is the
  reference example).
- **Byte-compile order**: `EL_FILES` in `Makefile` lists the
  files in increasing layer number.  A file that needs a
  function from another bookmark-gt file requires that file;
  if the other file has a higher layer number, see rule 3.
- **Prompting from a Lisp API**: `bookmark-gt-create-non-file`
  and `bookmark-gt--create-record` never prompt.  The tag
  pipeline runs only when a creation command is called
  interactively or with TAGS `t`.
- **Interactive `bookmark-gt-create` with no handler set by the
  mode**: for modes bookmark-gt owns the canonical handler for
  (currently: Dired), force the handler at creation
  so classification is unambiguous on disk.  See the
  `derived-mode-p 'dired-mode` clause.
- **Handler aliases in the registry**: symbols like
  `bmkp-jump-url-browse`, `bmkp-jump-dired`,
  `bmkp-gt-browsel-tabs-jump` (from the retired browsel package) are registered so records
  from other packages classify correctly.  These are quoted
  symbols in a data table — bookmark-gt does not depend on
  those packages being loaded.

## Extension surface (what third parties may add to)

- `bookmark-gt-record-changed-hook` — post-mutation observers.
- `bookmark-gt-create-name-reader-hook` — refine the default name.
- `bookmark-gt-create-tag-reader-hook` — last step of the tag
  pipeline.
- `bookmark-gt-jump-before-read-hook` — refresh a candidate
  pool before the jump reader displays.  Runs once per outer
  `bookmark-gt-jump*` call; functions run synchronously in
  order.  `bookmark-gt-browser-tabs-mode` adds its refresh here.
- `bookmark-gt-list-before-read-hook` — refresh records before
  the list buffer is drawn (open and revert).
  `bookmark-gt-browser-tabs-mode` and
  `bookmark-gt-auto-update-mode` add their refresh here.
- `bookmark-gt-handler-alist` — register a handler symbol under
  a type (via `bookmark-gt-handler-register`).
- `bookmark-gt-group-alist` — register a new group.
- `bookmark-gt-filter-alist` — add a filter to the list buffer.
- `bookmark-gt-sort-alist` — add a sort predicate.
- `bookmark-gt-jump-candidate-format-function` — replace the
  jump reader's row formatter.

All of these are empty, or hold only bookmark-gt's defaults,
when the package is installed.  bookmark-gt code adds only to
the two `-before-read-hook`s, and only from the opt-in modes
named in their entries.
