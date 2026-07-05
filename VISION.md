# machine-spirit

> The machine has a spirit you learn to commune with through the keyboard — but it's still a machine you can just reach out and touch.

**A hybrid tiling window manager and input layer for macOS. Keyboard where keyboard wins, mouse where mouse wins, and the friction of choosing between them designed away.**

## The thesis

Window tools on macOS pick a side. Tiling window managers make the keyboard mandatory — everything snaps to a grid, the mouse is treated as failure. Stock macOS makes the mouse mandatory — free-floating windows, drag everything, shortcuts an afterthought. Both are dogmatic in opposite directions.

machine-spirit sits in the equilibrium on purpose — not a compromise between the two, but a position more capable than either, because it refuses the premise that you must choose one input method per task.

The clearest way to say it: **being anti-mouse is stupid.** You can drive one screen with the trackpad while controlling another with the keyboard, at the same time — initiate an action on one pane by hand while a keystroke fires on the next. The mouse and keyboard aren't rivals competing for the same job; they're two hands working in parallel, ideally in harmony. Mouse-optional, never mouse-hostile.

So machine-spirit *adds* a keyboard layer on top of macOS — a leader-key launcher, a spatial window grid, an inline image feed, session protection — without removing anything. Windows still float. You still drag when dragging is better. Nothing is taken away; capability is only added.

## What it does today

A launcher built on mnemonic key-sequences (`caps → g → p` for ChatGPT), a spatial window grid mapped to the keyboard's own geometry (top letter-row → top of screen, bottom row → bottom), quit tucked safely behind keys that spell `quit`. Browser gestures that focus-or-cycle-or-open. A cross-project inline image feed for seeing AI-generated renders in the terminal. An escalating "shield" on terminal panes running live work — closing one triggers an energy-shield flare that only breaks on the third hit. The goal: **fun to kill a pane on purpose, hard to kill one by accident.** The friction that prevents the mistake *is* the delight.

## Where it's going

Not a better menu — a **visual node-graph editor** for your entire input layer. You build keybinds on a canvas by wiring nodes: shortcut-keys into groups and actions into commands, with parameters, animations, and scripts. A nested tree is just one way to view the graph; the graph is the real thing, and you shape it yourself. The tools it currently sits on — Leader Key, Rectangle, Karabiner — become importable templates and managed dependencies, never lock-in: migrate your existing config in losslessly and edit it into something better, start from a preset, or build from a blank canvas. Planned in that spirit: **sheol**, an underworld where detached terminal sessions wait to be recalled or laid to rest (and nag you until you deal with them); an editable summon indicator; per-project layers that spin up a whole working context in one keystroke.

## Principles

- **Additive, not replacing.** Layer on macOS; never fight its model.
- **Sovereignty without fragility.** Own your tools deeply, but antifragile — any component can crash, update, or be removed without taking the rest down. A coordinator, never a brittle parent.
- **Detect, auto-configure, guide.** Automate every safe setup step; guide through security-gated ones (never silently bypass a consent prompt); grey out and nudge toward features whose dependencies aren't installed.
- **The config is a canonical artifact.** Human-readable, diffable, version-controlled, portable, zero secrets.
- **Game-feel where it earns its place.** Friction and delight, deliberately placed.

## Why it exists

The default machine has a shape, and it's a *good* shape — Jobs and Wozniak and the original Apple engineers were onto something real for creatives. But there are significant virtues in the other tradition: the terminal-heavy, keyboard-driven tiling manager (mouse-optional, or better, mouse and keyboard in harmony). I love that tradition so much I wanted to learn from other shapes — to understand why some people love them so much — and build those features on top of a very Lindy, in the Talebian sense, operating system. In a way that's power-user applicable, but simple enough that a child could learn computer science, workflow optimization, and programming fundamentals through it.

and honestly part of the reason is that it's just actually beautiful — 2027 neo-cyberpunk, AI-infused, terminal-junkie kvlt. it helps make money, it plays music easily, it keeps me surrounded by beauty. that matters too.

These were all just ideas I was building by modifying various open-source projects, until I realized there was a cohesive design language emerging — worth putting in a repo in case my computer gets bricked, or so I could show someone, portably. And then: I should make this a portfolio project. And also, just for my own computing pleasure, efficiency, and learning. :)
