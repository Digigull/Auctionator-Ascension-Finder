# CLAUDE.md

Project notes for working on this repo.

## Commit / PR / merge workflow — keep versions in sync

This project uses a commit → PR → approve → merge loop, and the user often
**tests immediately after a change**, so we must always be working against
the same version of the code.

The loop:

1. Make changes, commit, and push to the feature branch
   (`claude/auctionator-addon-repo-c1mm7s`).
2. Pushing produces a pull request; the user reviews and approves/merges it
   into `main`.
3. The change is only live once merged into `main`.

Rules that follow from this:

- **A merged PR is finished.** It cannot pick up new commits. Never stack
  new work on already-merged history.
- **Before starting the next change, sync to the merged `main`** and restart
  the feature branch from it (same branch name), so the next push produces a
  fresh PR:
  ```
  git fetch origin main
  git checkout -B claude/auctionator-addon-repo-c1mm7s origin/main
  ```
  (If the branch already carries unmerged commits, rebase them onto the new
  base instead of discarding them.)
- **After the user says a PR is merged, re-sync before touching code** — the
  user may already be testing that exact version, so local and remote must
  match before the next edit.
- Do not open a PR manually; pushing to the branch is enough. Only open one
  if the user explicitly asks.

## Project overview

WoW (Ascension 3.3.5 client) addon: a build of **Auctionator** with an added
**Finder** tab. See `README.md` for features and `Old Docs/` for
architecture and testing notes (`FINDER-ARCHITECTURE.md`,
`README-TESTS.md`, `ASCENSION-CLIENT-NOTES.md`, etc.).

- Addon lives in `Auctionator-Finder-Ascension/` (Lua 5.1, `.toc` + XML).
- Tests: plain Lua 5.1 mock-WoW harness. Workflow: patch →
  `luac5.1 -p <file>` (syntax check) → run all harnesses. See
  `Old Docs/README-TESTS.md`.
