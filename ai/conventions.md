# bookmark-gt — conventions

Local conventions layered on top of the global user preferences
in `~/.claude/CLAUDE.md`.

## Coding style

### Functional first; avoid mutation

Prefer functional constructs that produce new values over
mutating existing ones.

- Use `append`, `cons`, `mapcar`, `seq-*`, `let*` bindings.
- Do not `setq` a local variable to accumulate a result when
  the same computation can be expressed with `let*` + fold or
  a pure builder function.
- Do not `setcdr` / `setcar` on records unless there is a
  concrete reason (in-place mutation of an alist entry that
  other code holds by identity).  The mutators in
  `bookmark-gt-core.el` and `bookmark-gt-tags.el` are the
  intended chokepoints for this; new call sites should go
  through them.
- Ask before introducing new mutation.  A one-line reason in
  the commit or the review comment is enough — "I need to
  mutate the alist entry in place so the list buffer's cached
  IDs remain valid" is a legitimate reason; "it was shorter"
  is not.

Preferred:
```elisp
(let ((args (append (list "cmd")
                    (when condition (list "--flag")))))
  (process args))
```

Not preferred:
```elisp
(let ((args (list "cmd")))
  (when condition
    (setq args (append args (list "--flag"))))
  (process args))
```

### Never resolve a record back to its name

If you already hold a record, act on it.  Do not pass
`(car record)` to a function that takes a name — that
re-enters `bookmark-get-bookmark`, which is `assoc`, which
returns the *first* record with that name.  When names are
duplicated, that is a different record than the one you had.

```elisp
;; Wrong — holds the record, acts on whichever comes first.
(bookmark-delete (car record) t)

;; Right — the callee takes a record.
(bookmark-gt-tags-set record tags)
```

`bookmark-gt-tags-set` and the other record-taking mutators are
the model.  Where the callee only accepts a name (some built-in
`bookmark.el` entry points), that is a defect to route around,
not a pattern to copy.

### Referring to a bookmark

A parameter that refers to an *existing* bookmark is named
`bookmark` and dispatches on type, through
`bookmark-gt--resolve`:

| Argument | Type   | Meaning                                    |
|----------|--------|--------------------------------------------|
| `nil`    | —      | none given; prompt where that is sensible  |
| record   | cons   | used directly                              |
| name     | string | a query: may match none, one, or several   |
| id       | symbol | resolved exactly                           |

**The `cond` order is nil → cons → string → symbol.** `nil` is
itself a symbol, so testing the symbol branch first makes every
"prompt me" call an id lookup. The same for `t`. It reads as
correct in any order.

Do not call `bookmark-get-bookmark` at a new site. It resolves a
name to the first match, which is the defect this convention
exists to prevent.

`bookmark-gt-create` is not part of this: its `NAME` names a
bookmark being made, not one being referred to.

### Errors over silent fallback

A reference that cannot be resolved is a broken reference, not
an absent one.  Signal.  Returning `nil` lets the caller treat
it as "no bookmark" and continue, which turns a bug into wrong
behavior somewhere else, later, with no diagnostic.

### Internal hooks — direct calls

Do not use bookmark-gt's own hooks
(`bookmark-gt-record-changed-hook`,
`bookmark-gt-create-tag-reader-hook`,
`bookmark-gt-create-name-reader-hook`) for internal wiring —
those are external extension points and ship empty.  See
`ai/architecture.md` for the rationale and the browser-tabs
performance incident that prompted the rule.

External hooks (Emacs's own — `find-file-hook`,
`bookmark-after-jump-hook`, `kill-buffer-hook`, etc.) are the
correct extension surface for reacting to Emacs's events;
those are fine to `add-hook` into.

## Language: precise, non-metaphorical, non-editorializing

The user cares deeply about this.  Reviewed and enforced across
the codebase.  Applies to:

- Code (identifiers, comments).
- Docstrings.
- `readme.org` and other user-facing docs.
- Chat replies.

### Words / phrases that get flagged

Any metaphor from another domain applied to software mechanics:

- `wires` (electrical) → `installs`, `registers`.
- `paints` overlays → `creates`, `adds`.
- `surfaces` records → `exposes`, `presents`.
- `steals focus` → `moves focus`.
- `clobbers` → `overwrites`.
- `landed` (aviation) → `the point after the jump`.
- `at their tail` (anatomy) → `at the end of the function body`.
- `catches` (net) → `intercepts` (when we mean advice; keep
  `catch` for Elisp catch/throw).
- `ships` (delivery) → `provides`, `includes`.
- `chips` (visual UI vocab) → `labels`.
- `hunts`, `walks`, `peeks`, `pokes`, `hacks` — all avoid.

Editorializing / marketing:

- `pragmatic`, `clean`, `elegant`, `simply`, `beautiful` — avoid.
  State facts.
- `easily`, `just`, `simply` when telling the reader something
  is easy — avoid.  If it needs saying, say what the steps are.
- `hunt for`, `dig into`, `under the hood` — no.

Anthropomorphizing software:

- Software doesn't `want`, `know`, `try`, `refuse`, `decide`
  when acting mechanically.  Use direct verbs.  Exception:
  standard technical usage (a hook `runs`, a function
  `returns`, a predicate `holds`) is fine.

### Rules that are looser than the general "no metaphors"

Some words that are metaphors originally have become technical
vocabulary; using them is fine:

- `fires` a hook — technical.  Prefer `runs` when unambiguous,
  but `fires` is standard Elisp.
- `hook`, `handler`, `advice` — all originally metaphors, now
  precise Elisp terms.
- `throws` / `catches` for Elisp `throw`/`catch` — the
  primitives, not metaphors.
- `cache warm/hot/cold` — established technical usage.

### Test before submitting user-facing text

Read each sentence and ask: would it still be unambiguous if
read literally?  If a metaphor were removed, would meaning
survive?  If yes to both, keep it; if the removal would help,
remove it.

## Docstrings

- One-line summary that names what the function does.  Rest
  should be strictly caller-facing.
- Do not put design rationale in docstrings — it rots.  Put it
  in `ai/architecture.md`.
- Do not put history in docstrings ("previously we used X, now
  we use Y" — no).
- Do not reference removed functions or old defcustoms.  Grep
  after refactors.
- Private (`--`) function docstrings can be very terse (one
  sentence).  Public functions get an argument description if
  the argument name isn't self-explanatory.

## Citing documents from source

Source comments and docstrings may cite `ai/architecture.md`,
`ai/conventions.md`, and `readme.org` — the documents that are
maintained and tracked in git.

Do not cite decision records.  Those exist to settle one
question, are moved to `ai/rip/` once implemented, and are
git-ignored while live, so a citation is a path that a fresh
clone never had and that stops existing after the work lands.

This is not hypothetical: six source files accumulated ten
pointers into `ai/design/`, two of them naming a file that was
never created, and one inside a docstring — where the rule
above already forbids design rationale.  Put the durable
statement in the source comment itself, or in
`ai/architecture.md`, and cite that.

## Naming

### List-buffer commands

- Row-scoped: `bookmark-gt-list-<verb>[-<noun>]`.  Examples:
  `-toggle-temp`, `-rename`, `-relocate`, `-preview`.
- Display-scoped (change what the buffer shows without changing
  records): `bookmark-gt-list-show-<noun>`.  The `show-`
  prefix disambiguates from row commands.  Example:
  `-show-temp` toggles visibility of temp records in the buffer.

### Callbacks on external hooks

Do not suffix callback functions with `-hook` — that suffix is
reserved for hook *variables*.  Prefer `--on-<event>`:

- Right: `bookmark-gt-highlight--on-find-file`,
  `bookmark-gt--on-jump-record-visit`,
  `bookmark-gt-auto-update--on-kill-buffer`.
- Wrong: `bookmark-gt-highlight--find-file-hook` (reads as if
  it's a hook variable named `find-file-hook`).

### Record keys

Before adding a key to a bookmark record, check whether another
package already writes it.  Bookmark records are a shared
namespace: every package that stores bookmarks writes into the
same alist.

`id` is the cautionary case — `org-bookmark-heading` stores the
org heading ID under it (`org-bookmark-heading.el:162`) and its
jump handler depends on it.  A generic name we assumed was free
was not.

Namespace anything whose obvious name is generic:
`bookmark-gt-<key>`.  Keys deliberately shared with bookmark+
for round-tripping (`tags`, `bmkp-temp`) are the documented
exceptions, not the pattern.

### Commands: creating versus changing

Creating a bookmark and changing one are separate commands, and
no variable chooses between them — the user says which they mean
by which command they invoke. `bookmark-gt-create` creates;
`bookmark-gt-update`, `-relocate`, `-rename`, `-delete` and the
property mutators change.

A command that creates is named `bookmark-gt-create-<what>`
(`-create-url`, `-create-non-file`). A command or API that
changes one property is named `bookmark-gt-<property>-set`
(`-tags-set`, `-temp-set`, `-auto-update-set`) — property first,
so the family sorts together.

Do not use `update-` as a prefix: `bookmark.el` has one
occurrence (`bookmark-update-last-modified`, a timestamp
helper), and the vocabulary is otherwise bare verbs. Do not use
`location` for a position — it means the target throughout this
package, in `bookmark-location`, and in the list buffer's column.

### Handler symbols

`bookmark-gt-handler-<type>-jump` for handlers bookmark-gt
owns.  Aliases (bookmark+, ecosystem packages) keep their
upstream names; the registry maps them to our types.

## Commit messages

Follow Linux kernel style (see global CLAUDE.md).  Subject
starts with a subsystem prefix corresponding to the file/area
touched.  Examples used here:

- `handlers: register function and sequence bookmark types`
- `list: rename temp-toggle to toggle-temp`
- `core: force Dired handler on set from Dired buffers`
- `docs: rewrite same-name-policy section`

## Bug reports

PRFT format for any bug fix (Problem, Root Cause, Fix, Test).
See global CLAUDE.md.
