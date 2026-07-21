#!/bin/zsh
# tmux-name.sh — emit a unique, evocative name for a protected tmux session.
#
# Two words in the spirit of Halo's Forerunner Monitors (an evocative adjective
# + noun — "Guilty Spark", "Penitent Tangent", "Static Carillon") drawn from
# fire, terminal, and necromantic/mechanicum vocabulary, with a little Latin
# (ignis=fire, umbra=shadow, noctis=night, mortis=death, cinis=ash, corvus=raven,
# ferrum=iron). All ASCII + hyphenated so `tmux attach -t` matching stays clean.
#
# Prints one name to stdout. Dodges a collision with any live session by
# re-rolling a few times, then disambiguating with a numeric suffix.
set -u

# GUI callers (the t t Leader Key bind runs under launchd) inherit no Homebrew
# PATH — resolve tmux the same way sheol-core does so the collision check works.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

adjs=(
  molten ashen ember cinder hollow penitent abject guilty tragic static
  lonely solemn gilded wretched ferrous umbral nocturnal smouldering obsidian
  dolorous sable seething charred votive
)
nouns=(
  ember cinder pyre forge kiln wraith revenant oracle augur seraph
  lich shade spectre geist requiem vigil daemon kernel cipher glyph
  vector ignis umbra corvus ferrum noctis mortis cinis sepulchre carillon
  tangent bias
)

have() { command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$1" 2>/dev/null }
roll() { print -r -- "${adjs[RANDOM % ${#adjs} + 1]}-${nouns[RANDOM % ${#nouns} + 1]}" }

name=$(roll)
for _ in 1 2 3 4 5 6; do
  have "$name" || { print -r -- "$name"; exit 0 }
  name=$(roll)
done
# Rare: many collisions — break the tie with a suffix.
n=2
while have "${name}-${n}"; do (( n++ )); done
print -r -- "${name}-${n}"
