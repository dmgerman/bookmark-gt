# MELPA recipe for bookmark-gt

This directory holds the [MELPA](https://melpa.org/) recipe for the
`bookmark-gt` package.  The single file `bookmark-gt` is what gets
copied into the `melpa/melpa` fork under `recipes/` when submitting.

## What ships

Only the nine top-level `bookmark-gt*.el` files listed under
`:files` in the recipe.  `README.md`, `LICENSE`, tests under
`test/`, planning material under `ai/`, the `Makefile`, and the
`.github/` workflows stay in the git repo but do not get installed
with the package.

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
- `browsel` — `bookmark-gt-browsel-tabs` only loads if browsel is
  present.  Without it, browser-tab bookmarks are unavailable but
  every other feature works.

Each of these is loaded with `(require 'foo nil t)` and every use
site is guarded with `featurep` / `fboundp` per the
[MELPA optional-dep pattern](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).

## Submitting

1. Fork <https://github.com/melpa/melpa>.
2. Copy `melpa/bookmark-gt` (this file) into `recipes/` in the
   fork.
3. In the fork: `make recipes/bookmark-gt` to verify the recipe
   builds a package cleanly.
4. Optional smoke test: `make sandbox INSTALL=bookmark-gt`.
5. Open a PR against `melpa/melpa` following their PR template.
   One recipe per PR.
