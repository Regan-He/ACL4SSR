#!/usr/bin/bash
#shellcheck shell=bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

CLASH_RULE_CONF="${SCRIPT_DIR}/ClashRule.conf"

if ! [ -f "${CLASH_RULE_CONF}" ]; then
    echo >&2 "File ${CLASH_RULE_CONF} is nonexistent!"
    exit 1
fi

declare -A TAG_LEVEL_MAPPING
declare -A LEVEL_TAG_MAPPING
declare -a DUPLICATE_NO_RESOLVE

function process_tag_level_mapping() {
    while IFS=, read -r tag level_orig; do
        level=$(echo "${level_orig}" | cut -d= -f 2 | tr -d ' ')
        TAG_LEVEL_MAPPING["${tag}"]="${level}"
        LEVEL_TAG_MAPPING["${level}"]="${tag}"
    done < <(
        grep -riE '(^\[|level)' "${CLASH_RULE_CONF}" |
            sed -e 'N; s/\n/, /' | tr -d '[' | tr -d ']'
    )
}

function get_duplicate_ipcidr {
    readarray -t DUPLICATE_NO_RESOLVE < <(
        grep -rnE '^IP-CIDR,' | cut -d: -f 3 | cut -d, -f 2 | sort | uniq -d
    )
}

function remove_duplicate_ipcidr() {
    local cidr
    local level
    local tag

    for cidr in "${DUPLICATE_NO_RESOLVE[@]}"; do
        unset TO_DELETE_RECORD
        local -A TO_DELETE_RECORD

        while read -r tag; do
            TO_DELETE_RECORD["${TAG_LEVEL_MAPPING["${tag}"]}"]="${cidr}"
        done < <(
            grep -rnE "^IP-CIDR,${cidr}," | cut -d',' -f 3 | sort -u
        )

        if ((${#TO_DELETE_RECORD[@]} <= 1)); then
            continue
        fi

        echo "Start processing ${cidr} ..."
        while read -r level; do
            tag=${LEVEL_TAG_MAPPING["${level}"]}
            declare -A TO_REMOVE_LINES
            while IFS=":" read -r file_name line_num _; do
                TO_REMOVE_LINES["${file_name}"]="${TO_REMOVE_LINES[${file_name}]},${line_num}"
            done < <(grep -rnE "^IP-CIDR,${cidr},${tag}" | sort -u)

            for fn in "${!TO_REMOVE_LINES[@]}"; do
                while read -r ln; do
                    echo -e "\tWill remove ${fn}:${ln}, content is ""$(sed -n "${ln}p" "${fn}")"
                    sed -i "${ln}d" "${fn}" || {
                        echo >&2 "Failed to remove useless line"
                        exit 1
                    }
                done < <(
                    echo "${TO_REMOVE_LINES["${fn}"]}" | tr ',' '\n' | sed '/^$/d' | sort -nur
                )
            done
            unset TO_REMOVE_LINES
        done < <(
            echo "${!TO_DELETE_RECORD[@]}" | tr ' ' '\n' | sed '/^$/d' | sort -nu | sed '$d'
        )
    done
}

function remove_unneeded_apple_proxy() {
    echo "Start processing apple tag ..."
    while read -r file; do
        sed -i '/apple/d' "${file}"
    done < <(
        grep -l -r apple "${SCRIPT_DIR}"/ProxySelect
    )

    while read -r file; do
        sed -i '/\.apple\.com/d' "${file}"
    done < <(
        grep -l -rE '\.apple\.com' "${SCRIPT_DIR}"/AdBlock
    )
    echo "Done."
}

function remove_unneeded_blbili_proxy() {
    echo "Start processing for bilibili ..."
    # bilivideo
    while read -r file; do
        sed -ri '/bilivide.*([Rr][Ee][Jj][Ee][Cc][Tt]|[Aa][Dd][Bb][Ll][Oo][Cc][Kk])/d' "${file}"
    done < <(
        grep -l -ri -E "bilivide.*\..*,(REJECT|.*ADBLOCK)" "${SCRIPT_DIR}"/AdBlock
    )
    echo "Done."
}

process_tag_level_mapping
get_duplicate_ipcidr
remove_duplicate_ipcidr
remove_unneeded_apple_proxy
remove_unneeded_blbili_proxy
