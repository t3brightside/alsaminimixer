#!/bin/bash

# ======================================================
#                  © Tanel PÕld t3brightside.com
# ======================================================

# Headless mini-mixer for Alsa main outputs (linked) of a set card
# Left/Right arrows for volume, Esc or q to exit
# Nr 0-9 to set volume 0%-90%

# ======================================================
#                  CONFIGURABLE PARAMETERS
# ======================================================

# ALSA card number
CARD=1

# Output channels to control (if using card 1, use: 'amixer -c 1' to see list of hw controls)                              
CHANNELS=("Main-Out AN1" "Main-Out AN2")

# Limit as % of hardware max (0–100)
MAX_PERCENT=20

# Name to show in mixer                  
MIXER_NAME="Babyface Pro"                 

# ======================================================
#                  INTERNALS
# ======================================================

# Auto-detect HW_MAX from first channel
HW_MAX=$(amixer -c "$CARD" sget "${CHANNELS[0]}" | awk '/Limits/ {print $4}')

BAR_WIDTH=30
Muted=false
Saved_Volume=0

# Calculate maximum volume based on percent
MAX_VOL=$(( HW_MAX * MAX_PERCENT / 100 ))
(( MAX_VOL == 0 )) && MAX_VOL=1  # safety check

# Step for arrow keys
STEP=$(( MAX_VOL / 100 ))
(( STEP == 0 )) && STEP=1  # minimum step

# Switch terminal to raw mode and hide cursor
stty -echo -icanon time 0 min 0
tput civis
clear   # clear terminal immediately

cleanup() {
    stty sane
    tput cnorm
    clear
    exit 0
}

# ======================================================
#                     FUNCTIONS
# ======================================================

get_val() {
    local ch=$1
    amixer -c $CARD sget "$ch" | grep -oP 'Mono: \d+' | grep -oP '\d+'
}

set_val() {
    local ch=$1
    local val=$2
    (( val < 0 )) && val=0
    (( val > MAX_VOL )) && val=$MAX_VOL
    amixer -c $CARD sset "$ch" $val >/dev/null
}

get_audio_info() {
    local hw_params_file="/proc/asound/card${CARD}/pcm0p/sub0/hw_params"
    if [ -f "$hw_params_file" ]; then
        local hw_params=$(cat "$hw_params_file")
        local rate=$(echo "$hw_params" | grep "rate:" | awk '{print $2}')
        echo "${rate}Hz"
    else
        echo "No stream active"
    fi
}

toggle_mute() {
    if $Muted; then
        for ch in "${CHANNELS[@]}"; do
            set_val "$ch" $Saved_Volume
        done
        Muted=false
    else
        Saved_Volume=$(get_val "${CHANNELS[0]}")
        for ch in "${CHANNELS[@]}"; do
            set_val "$ch" 0
        done
        Muted=true
    fi
}

show_volumes() {
    local rows cols mode="$1"
    rows=$(tput lines)
    cols=$(tput cols)

    if [[ "$mode" == "resize" ]]; then
        clear   # full clear for resize
    else
        tput cup 0 0  # overwrite previous output
    fi

    local audio_info=$(get_audio_info)
    local lines=()

    # Calculate dynamic header bar to match the bottom line's width (53 chars)
    local name_len=${#MIXER_NAME}
    # Total available space
    local total_width=53
    # Width needed for name and surrounding spaces (if any)
    local content_width=$(( name_len + 2 ))
    # Remaining width for '=' on both sides
    local remaining_width=$(( total_width - content_width ))
    local left_equals=$(( remaining_width / 2 ))
    local right_equals=$(( remaining_width - left_equals ))

    # Generate the header line without the extra outer '='
    local equals_left=$(printf '=%.0s' $(seq 1 $left_equals))
    local equals_right=$(printf '=%.0s' $(seq 1 $right_equals))

    lines+=("${equals_left} ${MIXER_NAME} ${equals_right}")
    lines+=("")
    lines+=("${audio_info}")
    lines+=("")

    for ch in "${CHANNELS[@]}"; do
        raw=$(get_val "$ch")
        [[ -z "$raw" || ! "$raw" =~ ^[0-9]+$ ]] && raw=0

        perc_int=$(( (raw * 100 + MAX_VOL/2) / MAX_VOL ))
        blocks=$(( (raw * BAR_WIDTH + MAX_VOL/2) / MAX_VOL ))
        (( blocks == 0 && raw > 0 )) && blocks=1

        if (( raw == 0 )); then
            bar_text=$(printf "%0.s " $(seq 1 $BAR_WIDTH))
        else
            bar_text=$(printf "%0.s▌" $(seq 1 $blocks))
            spaces=$(( BAR_WIDTH - blocks ))
            bar_text="$bar_text$(printf "%0.s " $(seq 1 $spaces))"
        fi

        perc_text=$([ $Muted = true ] && echo "M" || echo "${perc_int}%")
        lines+=("$(printf "%-12s : |%s| %5s" "$ch" "$bar_text" "$perc_text")")
    done

    lines+=("")
    lines+=("← | → | 0-9 | M | Esc")
    lines+=("")
    lines+=("=====================================================")

    local n=${#lines[@]}
    local top_padding=$(( (rows - n) / 2 ))

    # only apply top padding if not resizing
    if [[ "$mode" != "resize" ]]; then
        for ((i=0;i<top_padding;i++)); do echo ""; done
    fi

    for line in "${lines[@]}"; do
        local len=${#line}
        local left_padding=$(( (cols - len) / 2 ))
        printf "%*s%s\n" $left_padding "" "$line"
    done
}

change_vol() {
    local op=$1
    $Muted && return
    for ch in "${CHANNELS[@]}"; do
        val=$(get_val "$ch")
        if [ "$op" = "+" ]; then
            val=$(( val + STEP ))
        else
            val=$(( val - STEP ))
        fi
        set_val "$ch" $val
    done
}

set_volume_percent() {
    local perc=$1       # 0,10,20,...90
    local raw=$(( (MAX_VOL * perc + 50) / 100 ))  # round properly
    for ch in "${CHANNELS[@]}"; do
        set_val "$ch" $raw
    done
}

# ======================================================
#                     TERMINAL SIZE WATCHER
# ======================================================

prev_rows=$(tput lines)
prev_cols=$(tput cols)

# Only clear on resize, not on volume change
{
    while true; do
        rows=$(tput lines)
        cols=$(tput cols)
        if [[ $rows != $prev_rows || $cols != $prev_cols ]]; then
            prev_rows=$rows
            prev_cols=$cols
            clear
            show_volumes
        fi
        sleep 1
    done
} &

# ======================================================
#                     MAIN LOOP
# ======================================================

while true; do
    # Continuously redraw the display with the latest info
    show_volumes
    
    # Non-blocking read of a single key with a timeout
    # This allows the loop to continue and update the Hz
    IFS= read -rsn1 -t 5 key || continue

    # Handle arrow keys (multi-byte escape sequences)
    if [[ $key == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.05 key2
        key="$key$key2"
    fi

    case "$key" in
        $'\x1b[C') change_vol + ;;   # Right arrow
        $'\x1b[D') change_vol - ;;   # Left arrow
        $'\x1b[A'|$'\x1b[B') ;;     # Up/Down ignored
        m|M) toggle_mute ;;
        q|Q|$'\x1b') cleanup ;;
        0) set_volume_percent 0 ;;
        [1-9])
            perc=$(( 10 * key ))   # exact 10% multiples
            set_volume_percent $perc
            ;;
        *) continue ;;  # ignore all other keys
    esac
done