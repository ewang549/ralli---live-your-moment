# Self-diagnosis prompt: find and fix real bugs in Ralli

You have full access to this codebase (Swift/SwiftUI/SwiftData client in `explog/`, Firebase Cloud Functions in `functions/index.js`). Your job: find real, currently-existing bugs on your own, investigate their actual root cause in the code, fix them, and verify the fix — without being handed a specific bug report first. Work autonomously, but follow the discipline below; it exists because sloppier approaches have caused real wasted effort on this project before.

## Ground rules, in priority order

1. **Investigate before you touch anything.** Read the actual code — real file, real line numbers, real function names — before forming a theory about what's wrong. Don't fix a *plausible-sounding* bug; fix the *actual* one. If you're not sure something is broken, say so rather than "fixing" working code.
2. **Check git state before you assume nothing's been done.** Run `git status`, `git log`, and `git branch --show-current` before diagnosing. This codebase has a real history of fixes existing correctly in the code but sitting uncommitted, or committed to a feature branch (`social-graph-phase-1`) that never got merged into `main`. If you find a bug that already looks fixed in the code, check whether that fix is actually committed and on the branch that matters before reporting it as unresolved — and check whether it's already merged to `main` before assuming a fresh build would even include it.
3. **Never assume; verify.** If a previous session's notes or comments claim something was fixed, re-read the current code yourself rather than trusting the claim. Comments and doc-strings in this codebase are generally reliable (the team writes them to explain *why*, not just *what*), but re-confirm behavior against the actual code path, not just the comment.
4. **Respect the product's hard rules — don't "fix" these into a different behavior:**
   - Video must never be cropped. Every screen that shows a log should show the entire frame, letterboxed if needed, never cut off — this has been a recurring, deliberate constraint through this project's history. If you find a screen that crops video, that's a bug to fix toward "show the whole thing," not a design choice to leave alone.
   - Logs sent to specific friends must only be visible to those friends. Any change touching `recipientUids`, `publishLog`, `listFriendLogs`, or Firestore rules around the `logs` collection needs extra scrutiny — a leak here (a private log becoming visible to the wrong people) is the single worst class of bug this app can have. If you're not certain a change preserves this, don't make it without flagging your uncertainty clearly.
   - The friends-only send/publish pipeline (`SendToFriendsView.send()`, `LogSync.publish`/`publishPending`, `publishLog`/`listFriendLogs`/`cleanRecipientUids` in `functions/index.js`) has been exhaustively verified correct multiple times in this project's history. If you suspect a bug there, re-verify with extreme care before touching it — most "it's sending to everyone" reports in this app's history turned out to be *display* bugs elsewhere (e.g. a screen showing a cached clip that wasn't scoped to the right chat), not actual delivery bugs. Don't assume the send pipeline is broken; prove it, and check display logic first.
5. **Firestore security is defense-in-depth on purpose.** Most collections are closed to direct client access (`allow read, write: if false`) with real logic living in Cloud Functions callables. Don't "fix" a client-side permission error by loosening a Firestore rule — find out why the client isn't going through the intended callable instead.
6. **Match the codebase's existing patterns rather than introducing new ones.** This project has established conventions: SwiftData `@Model`/`@Query` for local state, a shared `HourFeedState`/`EdgeStepZones` navigation system for stepping through hours and days, a `Theme` module for all colors (never hardcode `Color.black`/`.white` in new code — use the adaptive tokens), a `LogSync`/`BeaconSync`-style sync-layer pattern for anything that needs to reconcile local SwiftData state against server state, and Cloud Functions callables (`onCall`) as the only way the client mutates server data. If you're adding something new, look for the existing pattern first rather than inventing a parallel one.

## How to actually find bugs to fix

Pick from these approaches, roughly in order of value:

1. **Look for TODO/FIXME/HACK comments and any code comment that describes a known limitation or workaround** — grep for these across the codebase. This project's authors leave detailed comments explaining *why* something is the way it is, including places where a shortcut was taken deliberately; some of those are worth revisiting.
2. **Look for asymmetries.** If screen A handles a case correctly and screen B (doing something conceptually similar) doesn't, that's very often a real bug in this codebase's history — several past fixes here were exactly this shape (one feed screen correctly aspect-fits video, another doesn't; one navigation screen has a distinct swipe gesture, another reuses tap's closure by accident).
3. **Look for silently-swallowed errors.** Grep for `try?` and empty/near-empty `catch` blocks — this codebase has had real bugs caused by a failure being silently discarded instead of surfaced (e.g., a Firestore save failure that left local state looking wrong with no error ever shown).
4. **Look for state that's computed once and never re-evaluated when its inputs change** — a recurring bug shape here has been a value (a rotation angle, a locked orientation, a cached clip reference) captured at one point in time and reused later without re-checking whether the underlying context changed (e.g. reusing an old camera's rotation angle after flipping to a different camera).
5. **Cross-check the client against the server.** For any feature that has both a client-side path and a Cloud Functions callable, confirm they actually agree on data shape, field names, and edge-case handling (e.g., does the client's local `hasUnread` logic match what the server actually delivers as "unread-worthy"? does a client-side filter duplicate or diverge from a server-side query filter, like the beacon-expiry logic where the server filters query results but the client never prunes already-synced local rows?).
6. **Actually run things where you can.** If you have the ability to run `swift build`/`xcodebuild` for a compile check, or run the Cloud Functions locally/lint them, do that rather than only reading code — a compile error or lint failure is a real, cheap signal you shouldn't skip.

## When you find something

For each bug:
1. State the file, the line number(s), and the exact current code.
2. Explain precisely why it's wrong — not just "this looks off," but the actual mechanism by which it produces the wrong behavior.
3. Make the fix, matching the codebase's existing style and patterns.
4. Explain how to verify the fix actually works (what to test, what the expected before/after behavior is).
5. If the bug touches anything in the "hard rules" list above (video cropping, recipient scoping, security rules), call that out explicitly and explain why your fix preserves the rule rather than just asserting it does.

## What not to do

- Don't refactor working code "for cleanliness" as a side effect of a bug fix — stay scoped to the actual bug.
- Don't touch the friends-only send/publish pipeline speculatively (see rule 4).
- Don't loosen Firestore security rules to work around a client error.
- Don't report something as "fixed" without having actually verified the current code reflects the fix — including checking it's committed and on the right branch, per rule 2.
- Don't invent a bug to have something to report — if a targeted search doesn't turn up anything real, say so plainly rather than manufacturing a low-value change.

## Output format

For each real bug found and fixed, produce a short summary in this shape (matching how bugs have been documented throughout this project's history):

```
## [Short bug title]
**File/line:** ...
**What's wrong:** ...
**Fix:** ...
**Verification:** ...
```

If you find nothing worth fixing after a genuine search, say that plainly instead of padding the output.
