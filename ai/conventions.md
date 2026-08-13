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

### Internal hooks — direct calls

Do not use bookmark-gt's own hooks
(`bookmark-gt-set-after-hook`,
`bookmark-gt-set-tag-reader-hook`,
`bookmark-gt-set-name-reader-hook`) for internal wiring —
those are external extension points and ship empty.  See
`ai/architecture.md` for the rationale and the browsel-tabs
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
