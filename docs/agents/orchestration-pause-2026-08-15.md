# Offline improvements — orchestration pause

Paused on 2026-08-15 at the user's request. Do not start another ticket, agent,
review, benchmark, integration, PR, or GitHub closure until the user explicitly
asks to resume.

## Stable repository state

- Main checkout: `/Users/maz/Documents/projets/whisperASR`
- Before this checkpoint document, `HEAD == main == origin/main` at
  `f1a3e0b28710ad1807b22312134d7a9d25733841`. Local `main` is now exactly one
  documentation commit ahead of `origin/main`; publish it only when orchestration resumes.
- Main checkout and every retained secondary worktree were clean at pause time.
- No heavy model benchmark was running when the pause was recorded.
- Already merged and closed: #110, #116, #120.
- Open umbrella: #109.

Do not delete the retained worktrees or the three named stashes until their
changes have either been integrated or explicitly discarded.

## Exact checkpoints

### #111 — folder-scoped Projects

- Task: `01a00568-dc94-72d3-ba5c-57343fd9516c`
- Worktree: `/Users/maz/.codex/worktrees/b885/whisperASR`
- Branch/HEAD: `codex/issue-111-projects` / `53a85b4653e765887c58786b91c7b299b603c2b4`
- Base: `000b7f2b2a9ba5e1ff939ec3cdfa577b9fa0469f`
- Paused changes: stash `659fa1c75085cd4c3c62cab1c0aa2c8f03c97c87`
  (`pause-issue-111-final-rereview`).
- Last green checks: 82 targeted, 473 full, 46 Live; zero failures.
- State: implementation and latest P1 root-validation correction are present in
  the stash, but the final correction has not received the required fresh pair
  of reviews and has not been committed.
- Resume first action: in this worktree run
  `git stash apply 659fa1c75085cd4c3c62cab1c0aa2c8f03c97c87`, then run exactly two fresh
  Standards/Spec reviews. If both pass, commit conventionally and leave the
  worktree clean.

### #112 — SpeakerKit-only reanalysis

- Task: `01a00568-dc94-72d3-ba5c-56e662d5c910`
- Worktree: `/Users/maz/.codex/worktrees/f46b/whisperASR`
- Final SHA: `8a855d26c6b35645cd46a7d71a9b47905efb105d`
- State: finished, independently reviewed, not integrated or published.
- Real run: 25.954 s, peak RSS 828,391,424 bytes; ASR, alignment and translation
  hashes unchanged. Full 468 and Live 46 passed with zero failures.
- Resume first action: no implementation work; include this SHA in the grouped
  #111–#114 integration.

### #113 — speaker editor

- Task: `01a00568-dc94-72d3-ba5c-570abc7c5b4c`
- Worktree: `/Users/maz/.codex/worktrees/6fe3/whisperASR`
- Final SHA: `8105810f013a289dc53dc23bb851bf1f5d3cd3c1`
- Base: `000b7f2b2a9ba5e1ff939ec3cdfa577b9fa0469f`
- State: finished and committed, two reviews closed, not integrated or published.
- Last green checks: 96 targeted, 488 full, 46 Live; zero failures; E31 hashes valid.
- Resume first action: no implementation work; include this SHA in the grouped
  #111–#114 integration.

### #114 — centroid-based duplicate speaker suggestions

- Task: `01a00568-dc95-7e63-9886-b0be08d3d9cf`
- Worktree: `/Users/maz/.codex/worktrees/0c9d/whisperASR`
- HEAD/base: `e032f48b2ebd6e13e52eee37c340dfbef846136e` /
  `000b7f2b2a9ba5e1ff939ec3cdfa577b9fa0469f`
- Paused changes: stash `7fa833032d410c0744a8a35932e19094bd5081f6`
  (`pause-issue-114-spec-fixes`).
- Last green checks: 107 targeted, 477 full, 75 Live; zero failures.
- Existing experiment: threshold 0.30, ambiguity margin 0.10; holdout produced one
  useful suggestion, zero false suggestions and 65 abstentions.
- State: Standards review passed; Spec review found two unresolved P2 cases:
  1. non-empty speaker spans with an empty centroid dictionary need an explicit
     diagnostic and must not expose suggestions;
  2. calibration/holdout reports containing `validationDiagnostics` must block
     suggestions.
- Resume first action: apply stash
  `7fa833032d410c0744a8a35932e19094bd5081f6`, add the two RED tests, fix only
  those guards, rerun targeted/Live/full, then run two fresh reviews before a
  Conventional Commit.

### #117 — adaptive Qwen to Parakeet

- Task: `01a005a7-d76d-73b3-88cf-1da28dfdc5d0`
- Worktree: `/Users/maz/.codex/worktrees/b8c2/whisperASR`
- Final SHA: `98f4ccd8bf6dcd1cb98e10554f9153074357debf`
- State: experiment complete, NO-GO, hidden from the UI, not yet integrated or
  published because #118 builds on it.
- Result: 169 Qwen segments, 26 Parakeet escalations, zero safe selections and
  nine vetoes. Apparent JA edit gain was rejected because critical content
  (`1000`, `前に行かない`) was lost. English and holdout were not run.
- Resume first action: do not retest Parakeet; retain this as the fixed base and
  honest NO-GO evidence for #118.

### #118 — targeted WhisperKit fallback

- Task: `01a00664-e1dc-7410-8e79-b1c4babb8276`
- Worktree: `/Users/maz/.codex/worktrees/52f7/whisperASR`
- Branch/base: `codex/issue-118-targeted-whisperkit` /
  `98f4ccd8bf6dcd1cb98e10554f9153074357debf`
- Paused changes: stash `54e43f6db36bb8068e5d8e3dbae645f465704ce7`
  (`wip: issue 118 targeted whisperkit checkpoint`).
- Last green checks: 14 targeted; zero failures.
- Provisional code: complete-hypothesis WhisperKit selection, fallback/veto logic,
  sequential Qwen→Parakeet→WhisperKit execution, audit, and one translation.
- Not done: runner/evidence, READY preflight, authorized heavy DEV benchmark,
  full/Live tests, two final reviews, final commit and app launch.
- Resume first action: apply stash
  `54e43f6db36bb8068e5d8e3dbae645f465704ce7`, finish the runner and light
  preflight, then stop at `READY_FOR_HEAVY_BENCHMARK #118` for an explicit slot.

## Work that must not start yet

- #115 — recurring voice recognition inside a Project. Blocked by accepted and
  integrated #111, #113 and #114.
- #119 — closed auditable lexical correction. Blocked by accepted and integrated
  #111; #116 is already complete.
- #121 — final integrated offline validation. Must be last, after #112, #113,
  #115, #117, #118, #119 and #120 are resolved/integrated as applicable.
- #109 — close only after #121 and all child decisions are published.

## Resume order

1. Resume and finish #111 and #114 from their exact stashes.
2. Independently verify their final SHAs.
3. Integrate #111, #112, #113 and #114 together from current `main`; resolve
   overlap once, run full/Live tests, open one PR, merge, close the four issues,
   delete only the integrated branches/worktrees, and sync `main`.
4. Resume #118 from its stash and complete the DEV decision. Publish #117 and
   #118 together without exposing any NO-GO option.
5. Start #115 and #119 in parallel from the updated `main`. Heavy model work,
   if any, remains serialized.
6. Run #121 final validation, then close #109.

At every step: use the local host `gh` CLI for GitHub writes, require exactly
two final reviews, close reviewer agents immediately, and never start a heavy
benchmark without its explicit ticket slot.
