# MELPA recipe for bookmark-gt

This directory holds the [MELPA](https://melpa.org/) recipe for the
`bookmark-gt` package.  The single file `bookmark-gt` is what gets
copied into the `melpa/melpa` fork under `recipes/` when submitting.

## What ships

The recipe omits `:files`, so MELPA's default file spec applies:
every top-level `*.el` file (`bookmark-gt.el` and the
`bookmark-gt-*.el` modules), plus `bookmark-gt.info` and `dir`.
`readme.org`, `LICENSE`, tests under `test/`, planning material
under `ai/`, the `Makefile`, and the `.github/` workflows stay in
the git repo but do not get installed with the package.

`make melpazoid` stages exactly the files this recipe selects and
runs MELPA's melpazoid checks on them.

## Deliberate omissions from Package-Requires

`bookmark-gt.el`'s `Package-Requires` declares only `(emacs "30.1")`.
The following runtime helpers are loaded lazily and skipped cleanly
when absent, so they are *not* forced on every install:

- `marginalia` — the jump reader registers a marginalia annotator
  when marginalia is loaded.  Without it, the reader still works;
  users just see plain candidate names.
- `consult` — `bookmark-gt-jump` uses `consult--read` when consult
  is loaded, and falls back to vanilla `completing-read` otherwise.
- `orderless` — the `,@Type` / `;tag` narrowing dispatchers are
  registered into `orderless-style-dispatchers` when orderless is
  loaded.  Without it, users match by whatever completion style is
  active.
- `browser-gt` — `bookmark-gt-browser-tabs` only fetches tabs if
  browser-gt is present.  Without it, browser-tab bookmarks are
  unavailable but every other feature works.

Each of these is loaded with `(require 'foo nil t)` and every use
site is guarded with `featurep` / `fboundp` per the
[MELPA optional-dep pattern](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).

## Submitting

1. Fork <https://github.com/melpa/melpa>.
2. Copy `melpa/bookmark-gt` (this file) into `recipes/` in the
   fork.
3. Run `make melpazoid` here first; it must report no findings.
   In the fork: `make recipes/bookmark-gt` to verify the recipe
   builds a package cleanly.
4. Optional smoke test: `make sandbox INSTALL=bookmark-gt`.
5. Open a PR against `melpa/melpa` following their PR template.
   One recipe per PR.
