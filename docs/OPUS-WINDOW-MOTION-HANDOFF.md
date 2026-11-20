# Opus handoff · window motion and launcher responsiveness

**19 November 2026. The classic build is running. Alexander rejected the motion pass after trying it. The next session is for review. Wait for his go-ahead before implementing or installing another variant.**

## Start here

The working source baseline is `2fb0c47`. The rejected experiment is `2251f84`. Its local revert, `2e0e909`, has the same Git tree as the baseline. Both installed signed app bundles were compared recursively against the saved pre-pass bundles. The CLI, resize AppleScript and full live shortcut config were compared byte for byte. Both apps were running after restoration. The board executable SHA-256 starts with `0892c10c8d2b8119`. A dry run resolves Q/Q/Q to Rectangle again. The saved live config includes personal bindings beyond the repository template.

Use `git diff 2fb0c47 2251f84 -- <path>` to inspect the experiment in place. Stash `126b7d4` contains an earlier rejected Numogram experiment. The separate fx4 worktree mixes several visual passes. The lens worktree describes an outline drawn **after** landing. Treat those as historical sources.

## What Alexander asked for

| Request | What the experiment established |
| --- | --- |
| Keep the classic node identity, with gentle hover exits and smooth reversals. | Retargeting from the current presentation layer is worth reviewing. Ordinary forward and Back navigation also got much longer timings. Alexander rejected the resulting feel. Curves, thinner traces, lightning, proportions and usage counts were outside this brief. |
| Make quarters easier to hit. | The preview and mover shared one geometry rule. The candidate used the outer 25% of both axes for corners. The user approved the direction. The 25% threshold was our choice. |
| Hold Caps and Space, aim, then place. Preserve quick taps. | The recognizer used the release point, with a 220 ms hold or eight points of travel. Headless tests covered tap versus hold. Physical timing and cancellation during ordinary use still need evaluation. |
| Let the green destination appear before the window moves, then fade as the window arrives. Include triple-letter placements and monitor transfers. | The held preview could already be visible before release. The Q/Q/Q and E/E/E paths first announced intent on the final tap. The AX write followed immediately, with no evidence the destination had appeared onscreen. The code could therefore produce a trailing flash. |
| Double-tap an arrow after Caps to move to a monitor in that direction. | The geometry favored a monitor aligned with the requested edge, then a diagonal. It stopped at the desktop edge and preserved relative window size. These rules were tested synthetically. |

## Adversarial findings

1. **The renderer itself was made slower.** Baseline `OverlayFX.swift` gives ordinary forward and Back motion 140 ms and 90 ms defaults. The rejected `TypingOverlay.swift:618` used a fixed 600 ms for either whenever animation was enabled. Its stagger added up to 120 ms. Default hover also changed from 140 ms to 1.05 s, with a 1.4 s return. These are animation durations. They directly explain late visual settling. They do not measure when the keyboard event was handled.
2. **One slow window can delay the next shortcut.** In rejected `tools/ms/Sources/ms/Windows.swift:253–260`, the CLI applied the frame, saved ladder state and then polled for arrival, with a 550 ms standard budget or 1.3 s for native fullscreen. An individual AX read can also stall. The existing Leader Key command queue is serial and waits for the child process to exit (`forks/LeaderKey/Leader Key/CommandRunner.swift:11–38`). A clamping app can therefore hold up later commands even after the first move is visible. Several previously Rectangle-backed shortcuts acquired this path together. No physical timing trace established how often this occurred on Alexander’s Mac.
3. **A posted notification is insufficient evidence of a telegraph.** The CLI sends a distributed notification and immediately sets the real frame. The board orders its panel separately. The arrival test compares AX geometry, which can update ahead of the picture on screen. The invisible panel tests injected notifications directly. They established geometry, cancellation, and fade state. They could pass even if the first visible outline frame followed the jump.
4. **The experiment changed too many things to isolate the regression.** It combined graph timing, mouse zones, gesture recognition, a replacement mover for eight existing grid shortcuts, cross-display placement, and arrival polling. The cue also applied to other callers of the shared mover. A separate-window test, an installed-route dry run and a smooth interrupted layer animation each answer different questions. None measures how a sequence of real keystrokes feels.

## Read-only review brief

- Trace three paths separately in the two commits: ordinary graph navigation and Back, Caps–Space aiming, and Q/Q/Q or a monitor transfer. For each, identify who knows the destination, who moves the real window, and which work can block the next key.
- For triple-letter placement, evaluate whether the second matching key provides a reliable opportunity to preview the destination, with the third still firing the original shortcut immediately. Check cancellation, focus changes, different monitor sizes and misdirected previews. A directional arrow's first tap presents the same opportunity. A fixed sleep on every movement spends the user's latency budget.
- If Alexander later wants a prototype, start from the restored build and evaluate one shortcut in isolation. Use a disposable window and compare against the original under the same conditions. A frame recording should show the first visible destination cue, the first changed window frame, and the fade. Measure last key to visible movement and the latency of the *next* key in a burst. Include an app that clamps its size and a move across displays.
- Preserve the successful pieces as candidates: shared preview geometry, captured release coordinates, cancellation of stale acknowledgments and a deterministic neighbor rule. The user’s judgment on responsiveness and whether the cue actually reads as anticipation is still open.

The rollback verifies the installed state. The user’s experience after rollback has not yet been observed.
