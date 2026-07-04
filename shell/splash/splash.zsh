# splash.zsh — hotkey-window splash, top to bottom: big "welcome user" banner
# in the default text color, a blinking blackletter +++ Welcome User +++
# caption centered beneath it, fastfetch beside the winged censer skull, and a
# random quote — all typed to the terminal a character at a time.
#
# Sourced (not executed) from aliases.zsh, which calls hotkey_splash only in
# the iTerm hotkey window. Run `hotkey_splash` by hand to preview anywhere.
#
# BANNER TRYOUT MODE: banners/ holds pre-rendered banners, one per
# font-and-language combo (filename <Font>__<lang>.txt; the caption follows
# the language). While there is more than one file, each launch shows the
# next one (alphabetical, counter in ~/.cache) and prints its name after the
# caption. To lock in favorites, delete the rest. Banners were made from OFL
# typefaces (Google Fonts) rendered to PNG via CoreText, then converted with
#   chafa -f symbols -c none --symbols block --stretch -s 114x10
#
# LOGOS: each launch draws a random file from logos/ (any art up to ~35
# rows; $1/$2 are fastfetch color placeholders, $2 blinks, escape literal $
# as $$). When a tall logo needs the rows, the banner/caption/divider block
# drops out automatically for that launch.
#
# Knobs:
#   HOTKEY_SPLASH_BURST      typewriter chars per 10ms tick (default 24)
#   HOTKEY_SPLASH_CAPTION    caption text override (any language)
#   HOTKEY_SPLASH_LOGO       force a specific logo file
#   HOTKEY_SPLASH_ORNAMENTS  0 disables the random ornaments beside info lines
#
# The skull's eyes, and the caption's +++ marks, use the terminal blink
# attribute (needs "Blinking text" enabled in iTerm). The 𒐫 separator and
# divider rhythms re-randomize every launch; both need a font with cuneiform
# glyphs, else they show as boxes.
# NOTE: iTerm only applies profile Rows/Columns when the hotkey window is
# recreated — close it fully and re-summon after resizing the profile.

HOTKEY_SPLASH_DIR=${${(%):-%N}:A:h}

# Print $1 one visible character at a time. ANSI escape sequences are emitted
# whole so colors and fastfetch's cursor positioning survive the animation.
# Pacing: one 10ms tick per $HOTKEY_SPLASH_BURST visible chars (zselect can't
# sleep shorter), so ~2400 chars/s at the default of 24.
_hotkey_splash_type() {
  emulate -L zsh
  local data=$1 ch
  local -i i=1 j=0 n=$#data code shown=0 can_tick=0
  local -i burst=${HOTKEY_SPLASH_BURST:-24}
  zmodload zsh/zselect 2>/dev/null && can_tick=1
  while (( i <= n )); do
    ch=$data[i]
    if [[ $ch == $'\e' ]]; then
      (( j = i + 1 ))
      if [[ $data[j] == '[' ]]; then
        # CSI sequence: skip parameter/intermediate bytes (0x20-0x3F) up to
        # the final byte (0x40-0x7E)
        while (( ++j <= n )); do
          ch=$data[j]
          code=$(( #ch ))
          (( code >= 64 && code <= 126 )) && break
        done
      fi
      print -rn -- $data[i,j]
      (( i = j + 1 ))
      continue
    fi
    print -rn -- $ch
    (( i++, shown++ ))
    (( can_tick && shown % burst == 0 )) && zselect -t 1
  done }

# Emit a random rhythm of 𒐫 and gaps, $1 chars long (always starts solid).
_hotkey_splash_cune() {
  emulate -L zsh
  local -i n=$1 i
  local s=𒐫
  for (( i = 1; i < n; i++ )); do
    if (( RANDOM % 3 )); then s+=𒐫; else s+=' '; fi
  done
  print -rn -- $s
}

hotkey_splash() {
  emulate -L zsh
  setopt local_options extended_glob
  local dir=$HOTKEY_SPLASH_DIR info line text src quote caption content banner l bname="" lang=en
  local -a parts qs bl bfiles orn_up orn_col orn_txt
  local -i k pad=21 bw=114

  # Caption text per banner language (filename suffix __<lang>); blackletter
  # unicode where the script allows it
  local -A capmap
  capmap=(
    en  $'𝖂𝖊𝖑𝖈𝖔𝖒𝖊 𝖀𝖘𝖊𝖗'
    fi  $'𝕿𝖊𝖗𝖛𝖊𝖙𝖚𝖑𝖔𝖆 𝖐ä𝖞𝖙𝖙ä𝖏ä'
    sv  $'𝖁ä𝖑𝖐𝖔𝖒𝖒𝖊𝖓 𝖆𝖓𝖛ä𝖓𝖉𝖆𝖗𝖊'
    ang $'𝖂𝖎𝖑𝖈𝖚𝖒𝖊 𝖇𝖗𝖚𝖈𝖊𝖓𝖉'
    ar  'أهلاً بالمستخدم'
    phn '𐤁𐤓𐤅𐤊 𐤄𐤁𐤀'
  )

  # Pick the logo first — its height decides whether the banner block fits.
  # HOTKEY_SPLASH_LOGO forces a specific file; otherwise random from logos/.
  local logo=$dir/logo.txt
  local -a lfiles=("$dir"/logos/*.txt(N.on))
  (( $#lfiles )) && logo=${lfiles[RANDOM % $#lfiles + 1]}
  [[ -n $HOTKEY_SPLASH_LOGO && -r $HOTKEY_SPLASH_LOGO ]] && logo=$HOTKEY_SPLASH_LOGO
  local -a llines
  [[ -r $logo ]] && llines=("${(@f)$(<$logo)}")
  local -i ffrows=$(( ($#llines > 14 ? $#llines : 14) + 1 ))

  # Banner in the plain default text color (same as fastfetch values), with
  # the blinking +++ caption centered beneath it — above the logo. Skipped
  # (caption and divider too) when a tall logo needs the rows.
  banner=""
  local -i show_banner=0
  bfiles=("$dir"/banners/*.txt(N.on))
  if (( $#bfiles )); then
    local state=${XDG_CACHE_HOME:-$HOME/.cache}/hotkey-splash-banner
    local -i bidx=1 counter=0
    if (( $#bfiles > 1 )); then
      # tryout mode: step through the banners, one per launch
      [[ -r $state ]] && counter=$(<$state)
      (( bidx = counter % $#bfiles + 1 ))
    fi
    bl=("${(@f)$(<$bfiles[bidx])}")
    # banner + caption + divider + info block + quote + prompt vs window rows
    if (( ffrows + 2 + 1 + $#bl + 2 <= ${LINES:-39} )); then
      show_banner=1
      (( $#bfiles > 1 )) && mkdir -p ${state:h} 2>/dev/null && print $(( counter + 1 )) >| $state 2>/dev/null
      bname=${${bfiles[bidx]:t}%.txt}
      [[ $bname == *__* ]] && lang=${bname##*__}
      bw=0
      for l in $bl; do
        banner+=$l$'\n'
        (( $#l > bw )) && bw=$#l
      done
    fi
  fi
  if (( show_banner )); then
    local cap=${HOTKEY_SPLASH_CAPTION:-${capmap[$lang]:-$capmap[en]}}
    (( pad = (bw - ${#cap} - 8) / 2 ))
    (( pad < 0 )) && pad=0
    local e=""
    caption=${(l:$pad:: :)e}$'\e[32m\e[5m+++\e[25m \e[1m'"$cap"$'\e[22m \e[5m+++\e[25m'
    (( $#bfiles > 1 )) && caption+=$'  \e[2m['"$bname"$']\e[22m'
    caption+=$'\e[0m'
    # dim cuneiform rule between the welcome block and the logo, gaps
    # re-randomized every launch
    local rule=$(_hotkey_splash_cune 14)
    local -i dpad=$(( (bw - ${#rule}) / 2 ))
    (( dpad < 0 )) && dpad=0
    local divider=${(l:$dpad:: :)e}$'\e[2;32m'$rule$'\e[0m'
    parts+=("$banner$caption"$'\n'"$divider")
  fi

  if (( $+commands[fastfetch] )); then
    # per-launch config with a randomized cuneiform separator rhythm
    local ffcfg=$dir/fastfetch-hotkey.jsonc
    local needle='"string": "𒐫"' cfg=$(<$ffcfg)
    local patched=${cfg/$needle/\"string\": \"$(_hotkey_splash_cune 9)\"}
    local cache=${XDG_CACHE_HOME:-$HOME/.cache}/hotkey-splash-ff.jsonc
    if print -r -- $patched >| $cache 2>/dev/null; then ffcfg=$cache; fi
    info=$(fastfetch --pipe false --config "$ffcfg" --logo "$logo")
    # fastfetch leaves a styled-but-blank line under the logo — reclaim the row
    local -a ilines=("${(@f)info}")
    local tailplain
    while (( $#ilines )); do
      tailplain=${ilines[-1]//$'\e'\[[0-9;]#m/}
      [[ $tailplain == *[^\ ]* ]] && break
      ilines=("${(@)ilines[1,-2]}")
    done

    # Random ornaments beside info lines — appended only when they provably
    # fit (each char counted as 2 cols, so wide glyphs can't wrap the line).
    # They render dim in the main pass; a post-pass flashes them bright.
    if (( ${HOTKEY_SPLASH_ORNAMENTS:-1} )); then
      local -a orns=(
        '｡ ₊°༺❤︎༻°₊ ｡' '⋆༺𓆩⚔𓆪༻⋆' '𓆩♡𓆪' '★ ★ ★ ★ ★'
        '🃜 🃚 🃖 🃁 🂭 🂺' '𓊆ྀི❤︎𓊇ྀི' '꧁⎝ 𓆩༺✧༻𓆪 ⎠꧂' '⊹ ࣪ ˖'
        '✧˖°⋆༺☬༻⋆°˖✧' '𓋹 𓂀 𓋹' '«──❈──»' '☽ ✧ ☾' '✠ ✠ ✠'
        '⋆⁺₊⋆ ☾ ⋆⁺₊⋆' '𓆩✧𓆪' '༺♰༻' '☠ ⚔ ☠' '✟ ☨ ✟'
        'ᛉ ᛟ ᛉ' '᚛ᚑᚌᚐᚋ᚜' '𓂀 ☥ 𓂀' '𓆙 𓆗' '♱ ✮ ♱'
        '⛧ ⛥ ⛧' '† † †' '❦ ❦ ❦' '☾ ⋆ ࿐' '✦ ✧ ✦ ✧ ✦'
        '⟡ ⟡ ⟡' '◈ ─── ◈' '𖤐 𖤐 𖤐' '☬ ࿊ ☬' '⚝ ⋆ ⚝'
        '✵ ✵ ✵' '𐕣 𐕣 𐕣' '✥ ✥ ✥' '♰ ☽◯☾ ♰' '༒︎ ༒︎'
        '⚰︎ ✟ ⚰︎' '『 ✦ 』' '➳❥' '«᯽»' '⋅˚₊‧ ୨୧ ‧₊˚ ⋅'
        '∘₊✧──✧₊∘' '♜ ♞ ♝ ♛' '𓅓 𓆃 𓅓' '☦ ✵ ☦' '⁂ ⁂'
      )
      local -i want=0 orn_r=$(( RANDOM % 10 ))
      (( orn_r >= 1 )) && want=1
      (( orn_r >= 4 )) && want=2
      (( orn_r >= 7 )) && want=3
      # fastfetch composes each row as logo + padding + info, so an info row
      # is simply a row containing a "key: value" pair
      local -i li vis cols=${COLUMNS:-125}
      local plainl orn
      for (( li = 1; li <= $#ilines && want > 0; li++ )); do
        (( RANDOM % 2 )) && continue
        plainl=${ilines[li]//$'\e'\[[0-9;]#[A-Za-z]/}
        plainl=${plainl%%[[:space:]]#}
        [[ $plainl == *': '* ]] || continue
        [[ $plainl == *𒐫* ]] && continue
        local -i oidx=$(( RANDOM % $#orns + 1 ))
        orn=$orns[oidx]
        (( vis = $#plainl ))
        (( vis + 2 * $#orn + 3 > cols )) && continue
        ilines[li]+=$' \e[2;32m'$orn$'\e[0m'
        # depth from the bottom of the fastfetch block; the flash pass adds
        # the quote's height once that is known
        orn_up+=($(( $#ilines - li )))
        orn_col+=($(( vis + 1 )))
        orn_txt+=($orn)
        (( want-- ))
      done
    fi

    info=${(pj:\n:)ilines}
    parts+=("$info")
  fi

  local -i qrows=0
  if [[ -r $dir/quotes.txt ]]; then
    qs=("${(@f)$(<"$dir/quotes.txt")}")
    qs=(${qs:#\#*})
    qs=(${(M)qs:#*\|*})
    if (( $#qs )); then
      local -i idx=$(( RANDOM % $#qs + 1 ))
      line=$qs[idx]
      text=${line%%|*}
      src=${line#*|}
      # word-wrap the quote so the longest ones can't spill past the window;
      # attribution goes on its own line
      local qtext=$'“'"$text"$'”' rest cut
      local -a qlines=()
      local -i qw=$(( ${COLUMNS:-125} - 6 ))
      rest=$qtext
      while (( $#rest > qw )); do
        cut=${rest[1,qw]}
        [[ $cut == *' '* ]] && cut=${cut% *}
        qlines+=("$cut")
        rest=${${rest#$cut}# }
      done
      qlines+=("$rest")
      quote=""
      for cut in $qlines; do
        quote+=$'  \e[3;32m'"$cut"$'\e[0m\n'
      done
      quote+=$'      \e[32m— '"$src"$'\e[0m'
      (( qrows = $#qlines + 1 ))
      parts+=("$quote")
    fi
  fi

  (( $#parts )) || return 0
  content=${(pj:\n:)parts}
  _hotkey_splash_type "$content"$'\n'

  # ornament settle pass: pause a beat, then flicker each dim charm in with a
  # short CRT-style pulse (bright/dim frames) that lands on a static bright —
  # no persistent blink. Relative cursor moves so it works wherever we ran.
  if (( $#orn_txt )); then
    local -i can_tick=0 oi up fr
    local -a frames=('1;32' '2;32' '1;32' '2;32' '1;32')
    zmodload zsh/zselect 2>/dev/null && can_tick=1
    (( can_tick )) && zselect -t 30
    for (( oi = 1; oi <= $#orn_txt; oi++ )); do
      (( up = orn_up[oi] + qrows + 1 ))
      for (( fr = 1; fr <= $#frames; fr++ )); do
        print -rn -- $'\e['$up$'A\r\e['$orn_col[oi]$'C\e['$frames[fr]$'m'$orn_txt[oi]$'\e[0m\r\e['$up$'B'
        (( can_tick )) && zselect -t 4
      done
    done
  fi
}
