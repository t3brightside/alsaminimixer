#!/bin/bash

# ======================================================
#                  © Tanel PÕld t3brightside.com
#              Improved by Gemini AI - Google
# ======================================================

# Headless mini-mixer for Alsa main outputs (linked) of a set card
# Left/Right arrows for volume, Up/Down for channel selection
# 'm' to mute, 's' to solo, Esc or 'q' to exit
# Nr 0-9 to set volume 0%-90%

# ======================================================
#                  CONFIGURABLE PARAMETERS
# ======================================================

# ALSA card number
CARD=1

# Output channels to control. Channels must be configured in PAIRS for stereo control.
# e.g., CHANNELS=("Main-Out AN1" "Main-Out AN2" "Main-Out PH3" "Main-Out PH4")
CHANNELS=("Main-Out AN1" "Main-Out AN2" "Main-Out PH3" "Main-Out PH4")

# Set the maximum volume limit (in percent) for each channel individually.
# This allows granular control over the max output level for each channel pair.
declare -A CHANNEL_CONFIGS=(
    ["Main-Out AN1"]=10
    ["Main-Out AN2"]=10
    ["Main-Out PH3"]=75
    ["Main-Out PH4"]=75
)

# Name to show in mixer
MIXER_NAME="Babyface Pro"

# ======================================================
#                  INTERNALS
# ======================================================

# Auto-detect HW_MAX from first channel
HW_MAX=$(amixer -c "$CARD" sget "${CHANNELS[0]}" | awk '/Limits/ {print $4}')
BAR_WIDTH=30
SELECTED_CHANNEL_PAIR_INDEX=0
SOLO_STATE=false
declare -A MUTED_CHANNELS
SOLOED_CHANNEL_INDEX=-1
declare -A SAVED_VOLUMES_MUTE
declare -A SAVED_VOLUMES_SOLO

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
    local max_perc=${CHANNEL_CONFIGS["$ch"]}
    local max_vol=$(( HW_MAX * max_perc / 100 ))
    
    (( val < 0 )) && val=0
    (( val > max_vol )) && val=$max_vol
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
    local ch_pair_start=$((SELECTED_CHANNEL_PAIR_INDEX * 2))
    local ch1="${CHANNELS[$ch_pair_start]}"
    local ch2="${CHANNELS[$((ch_pair_start + 1))]}"

    if [[ -n "${MUTED_CHANNELS[$ch_pair_start]}" ]]; then
        # Un-muting the stereo pair
        local saved_vol1="${SAVED_VOLUMES_MUTE[$ch_pair_start]}"
        local saved_vol2="${SAVED_VOLUMES_MUTE[$((ch_pair_start + 1))]}"
        set_val "$ch1" "$saved_vol1"
        set_val "$ch2" "$saved_vol2"
        
        unset MUTED_CHANNELS[$ch_pair_start]
        unset MUTED_CHANNELS[$((ch_pair_start + 1))]
        unset SAVED_VOLUMES_MUTE[$ch_pair_start]
        unset SAVED_VOLUMES_MUTE[$((ch_pair_start + 1))]
    else
        # Muting the stereo pair
        local current_vol1=$(get_val "$ch1")
        local current_vol2=$(get_val "$ch2")
        SAVED_VOLUMES_MUTE[$ch_pair_start]=$current_vol1
        SAVED_VOLUMES_MUTE[$((ch_pair_start + 1))]=$current_vol2
        set_val "$ch1" 0
        set_val "$ch2" 0
        MUTED_CHANNELS[$ch_pair_start]=1
        MUTED_CHANNELS[$((ch_pair_start + 1))]=1
    fi
}

toggle_solo() {
    local ch_pair_start=$((SELECTED_CHANNEL_PAIR_INDEX * 2))

    if [[ "$SOLO_STATE" == true && "$SOLOED_CHANNEL_INDEX" -eq "$ch_pair_start" ]]; then
        # If the currently selected channel is already soloed, un-solo it
        SOLO_STATE=false
        SOLOED_CHANNEL_INDEX=-1
        
        # Restore saved volumes for all channels
        for i in "${!CHANNELS[@]}"; do
             if [[ -n "${SAVED_VOLUMES_SOLO[$i]}" ]]; then
                 set_val "${CHANNELS[$i]}" "${SAVED_VOLUMES_SOLO[$i]}"
                 unset SAVED_VOLUMES_SOLO[$i]
             fi
        done
        
    else
        # If another channel is already soloed, first un-solo it
        if [[ "$SOLO_STATE" == true ]]; then
            # Restore saved volumes for all channels before soloing the new one
            for i in "${!CHANNELS[@]}"; do
                 if [[ -n "${SAVED_VOLUMES_SOLO[$i]}" ]]; then
                     set_val "${CHANNELS[$i]}" "${SAVED_VOLUMES_SOLO[$i]}"
                     unset SAVED_VOLUMES_SOLO[$i]
                 fi
            done
        fi
        
        # Now, solo the newly selected stereo pair
        SOLO_STATE=true
        SOLOED_CHANNEL_INDEX="$ch_pair_start"
        
        # Save current volumes before soloing
        for i in "${!CHANNELS[@]}"; do
            local current_val=$(get_val "${CHANNELS[$i]}")
            SAVED_VOLUMES_SOLO[$i]="$current_val"
        done

        for i in "${!CHANNELS[@]}"; do
            if [[ "$i" -eq "$ch_pair_start" || "$i" -eq "$((ch_pair_start + 1))" ]]; then
                # Soloed channel, don't change volume
                continue
            else
                # Mute all other channels
                set_val "${CHANNELS[$i]}" 0
            fi
        done
    fi
}


show_volumes() {
    local rows cols mode="$1"
    rows=$(tput lines)
    cols=$(tput cols)

    if [[ "$mode" == "resize" ]]; then
        clear
    else
        tput cup 0 0
    fi

    local audio_info=$(get_audio_info)
    local lines=()

    local name_len=${#MIXER_NAME}
    local total_width=53
    local content_width=$(( name_len + 2 ))
    local remaining_width=$(( total_width - content_width ))
    local left_equals=$(( remaining_width / 2 ))
    local right_equals=$(( remaining_width - left_equals ))

    local equals_left=$(printf '=%.0s' $(seq 1 $left_equals))
    local equals_right=$(printf '=%.0s' $(seq 1 $right_equals))

    lines+=("${equals_left} ${MIXER_NAME} ${equals_right}")
    lines+=("")
    lines+=("${audio_info}")
    lines+=("")

    for i in "${!CHANNELS[@]}"; do
        local ch="${CHANNELS[$i]}"
        local max_perc=${CHANNEL_CONFIGS["$ch"]}
        local max_vol=$(( HW_MAX * max_perc / 100 ))
        (( max_vol == 0 )) && max_vol=1 # safety check

        local raw=$(get_val "$ch")
        [[ -z "$raw" || ! "$raw" =~ ^[0-9]+$ ]] && raw=0

        local perc_int=$(( (raw * 100 + max_vol/2) / max_vol ))
        local blocks=$(( (raw * BAR_WIDTH + max_vol/2) / max_vol ))
        (( blocks == 0 && raw > 0 )) && blocks=1

        local bar_char='▒'
        if [ "$i" -eq "$((SELECTED_CHANNEL_PAIR_INDEX * 2))" ] || [ "$i" -eq "$((SELECTED_CHANNEL_PAIR_INDEX * 2 + 1))" ]; then
            bar_char='█'
        fi

        if (( raw == 0 )); then
            bar_text=$(printf "%0.s " $(seq 1 $BAR_WIDTH))
        else
            bar_text=$(printf "%0.s$bar_char" $(seq 1 $blocks))
            spaces=$(( BAR_WIDTH - blocks ))
            bar_text="$bar_text$(printf "%0.s " $(seq 1 $spaces))"
        fi

        local status_mark=""
        if [[ -n "${MUTED_CHANNELS[$i]}" ]]; then
            status_mark=" M"
        elif [[ "$SOLO_STATE" == true && ( "$SOLOED_CHANNEL_INDEX" -eq "$i" || "$SOLOED_CHANNEL_INDEX" -eq "$((i-1))" ) ]]; then
            status_mark=" S"
        fi
        
        local volume_and_status=$(printf "%-5s" "${perc_int}%${status_mark}")
        
        lines+=("$(printf "  %-12s |%s| %s" "$ch" "$bar_text" "$volume_and_status")")
    done

    lines+=("")
    lines+=("↑ ↓ | ← → | 0-9 | M | S | Esc")
    lines+=("")
    lines+=("=====================================================")

    local n=${#lines[@]}
    local top_padding=$(( (rows - n) / 2 ))

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
    local ch_pair_start=$((SELECTED_CHANNEL_PAIR_INDEX * 2))
    local ch1="${CHANNELS[$ch_pair_start]}"
    local ch2="${CHANNELS[$((ch_pair_start + 1))]}"
    
    local max_perc=${CHANNEL_CONFIGS["$ch1"]}
    local max_vol=$(( HW_MAX * max_perc / 100 ))
    (( max_vol == 0 )) && max_vol=1
    local step=$(( max_vol / 100 ))
    (( step == 0 )) && step=1

    local val=$(get_val "$ch1")
    if [ "$op" = "+" ]; then
        val=$(( val + step ))
    else
        val=$(( val - step ))
    fi
    set_val "$ch1" $val
    set_val "$ch2" $val
}

set_volume_percent() {
    local perc=$1
    local ch_pair_start=$((SELECTED_CHANNEL_PAIR_INDEX * 2))
    local ch1="${CHANNELS[$ch_pair_start]}"
    local ch2="${CHANNELS[$((ch_pair_start + 1))]}"

    local max_perc=${CHANNEL_CONFIGS["$ch1"]}
    local max_vol=$(( HW_MAX * max_perc / 100 ))
    (( max_vol == 0 )) && max_vol=1

    local raw=$(( (max_vol * perc + 50) / 100 ))
    set_val "$ch1" $raw
    set_val "$ch2" $raw
}

# ======================================================
#                     TERMINAL SIZE WATCHER
# ======================================================

prev_rows=$(tput lines)
prev_cols=$(tput cols)

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
    show_volumes
    
    IFS= read -rsn1 -t 5 key || continue

    if [[ $key == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.05 key2
        key="$key$key2"
    fi

    case "$key" in
        $'\x1b[C') change_vol + ;;
        $'\x1b[D') change_vol - ;;
        $'\x1b[A') # Up arrow, move up one channel pair
            SELECTED_CHANNEL_PAIR_INDEX=$(( (SELECTED_CHANNEL_PAIR_INDEX - 1 + ${#CHANNELS[@]}/2) % (${#CHANNELS[@]}/2) ))
            ;;
        $'\x1b[B') # Down arrow, move down one channel pair
            SELECTED_CHANNEL_PAIR_INDEX=$(( (SELECTED_CHANNEL_PAIR_INDEX + 1) % (${#CHANNELS[@]}/2) ))
            ;;
        m|M) toggle_mute ;;
        s|S) toggle_solo ;;
        q|Q|$'\x1b') cleanup ;;
        0) set_volume_percent 0 ;;
        [1-9])
            perc=$(( 10 * key ))
            set_volume_percent $perc
            ;;
        *) continue ;;
    esac
done