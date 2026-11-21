# 🌿 petclinic on `main` warning

Asked for on 2026-11-19: every workshop's live coding goes on its own branch of
`~/workspace/petclinic`, and Victor kept starting on `main`. So while a **training
session is active** (the training-assistant daemon announced `session_started`) and
petclinic's `.git/HEAD` points at `main` (or `master`), a **red bottom-left pill** (purple until 2026-11-22)
stays up: `🌿 petclinic is on main — create this workshop's branch`.

- **It goes away by itself** once another branch is checked out: `PetclinicBranchWarning`
  re-reads `.git/HEAD` every 5 s while a session runs (a 30-byte file read, no `git`
  process). Checking `main` out again mid-session brings it back.
- **Its Dismiss button (or a right-click) dismisses it for the rest of the day** (the button said "Open" until 2026-11-22, though nothing ever opened) — for a workshop where
  the code stays on `main` on purpose. The day is kept in `UserDefaults`
  (`petclinicBranch.dismissedDay`), so a redeploy doesn't bring it back.
- Session end (`session_ended`, or the daemon disconnecting) takes it down and stops the
  timer. A detached HEAD or a missing repo counts as "not on main".
- Pure rules in `PetclinicBranchPolicy` (`PetclinicBranchPolicyTests`).

## Testing

- `GET /test/petclinic-branch` — state: session flag, branch, dismissed day, visible.
- `GET /test/petclinic-branch/simulate` — the pill on the **external** screens only, whatever
  the branch; `/clear` ends the simulation.
- `GET /test/petclinic-branch/undismiss` — forget today's dismissal.
