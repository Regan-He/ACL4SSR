#!/usr/bin/bash
#shellcheck shell=bash

# 如果是被 cronie 任务拉起的，则会在 /var/log/cron 日志中记录下调用情况
WEBHOOK_URL="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# 所有操作在转到脚本所在目录之后开展
pushd "${SCRIPT_DIR}" &> /dev/null || exit 1

declare -gi CHANGED_FILES_COUNT=0
declare -ga CHANGED_FILES_LIST=()
declare -gi UPLOAD_STATUS=0
declare -g ERROR_MESSAGE=""

function make_notify_color_line() {
    local color="$1"
    local text="$2"
    local -i is_ref_line=${3:-0}
    local -i font_bold=${4:-0}
    local start_sequence
    local bold_sequence

    if ((is_ref_line)); then
        start_sequence='> '
    fi

    if ((font_bold)); then
        bold_sequence='**'
    fi

    printf '%s%s<font color=\\"%s\\">%s</font>%s' "${start_sequence}" "${bold_sequence}" "${color}" "${text}" "${bold_sequence}"
}

function send_robot_notify() {
    if ! [[ "${WEBHOOK_URL}" ]]; then
        return
    fi
    local -r URL_REGEX='^https:\/\/qyapi\.weixin\.qq\.com\/cgi-bin\/webhook\/send\?key=[0-9a-fA-F\-]+$'
    if ! [[ $WEBHOOK_URL =~ $URL_REGEX ]]; then
        echo >&2 "URL 格式不正确"
        return 1
    fi

    local -n report_content=$1
    local -n content_color=${2:-comment}
    if [[ "$3" ]]; then
        # 这是一个数组
        local -n extended_content=${3}
    else
        local -a extended_content=()
    fi
    if [[ "$4" ]]; then
        local -n extended_color=${4}
    else
        local extended_color='#6A5ACD' # 板岩暗蓝灰色
    fi

    local extended_text
    if (("${#extended_content[@]}")); then
        for ((i = 1; i <= ${#extended_content[@]}; i++)); do
            extended_text+="$(make_notify_color_line "${extended_color}" "${i}. ${extended_content[$((i - 1))]}" 1)\n"
        done
        extended_text+='\n'
    fi

    local -r git_repo='Regan-He/ACL4SSR'
    local -r report_header="[${git_repo}](https://github.com/${git_repo})"

    local report_message
    report_message="$(make_notify_color_line "${content_color}" "${report_content}" 1 1)"
    local operation_record
    operation_record="$(make_notify_color_line '#6A5ACD' "操作时间：$(date '+%Y-%m-%d %H:%M:%S')" 1)"

    #^ markdown 消息格式如下：
    #^ Regan-He/ACL4SSR
    #^
    #^ > **共有 1 个文件发生变化，修改已提交到 GitHub：**
    #^
    #^ > 1. QuantumultX/Adblock/qx.conf
    #^
    #^ 操作时间：2024-06-14 15:37:05
    #^
    local notification_content
    printf -v notification_content '{
    "msgtype": "markdown",
    "markdown": {
        "content": "%s\\n\\n%s\\n\\n%s%s"
    }
}' "${report_header}" "${report_message}" "${extended_text}" "${operation_record}"

    local -r user_agent='User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36 Edge/16.16299'
    local -r content_type='Content-Type: application/json'
    curl -H "${user_agent}" -H "${content_type}" -d "${notification_content}" "${WEBHOOK_URL}" -s
}

#shellcheck disable=SC2034  # 将会使用引用传递
function send_finish_notify() {
    local report_text message_color
    local -a patulous_content=()
    local -r patulous_color='#DB7093' # 苍白的紫罗兰红色
    case $UPLOAD_STATUS in
        1)
            message_color='#228B22' # 森林绿
            report_text="共有 ${CHANGED_FILES_COUNT} 个文件发生变化，修改已提交到 GitHub："
            patulous_content+=("${CHANGED_FILES_LIST[@]}")
            ;;
        2)
            message_color='#FFA500' # 橙色
            report_text="远端没有更新任何规则文件。"
            ;;
        *)
            message_color='#DC143C' # 猩红
            report_text="操作异常，请检查本地仓库"
            if [[ "${ERROR_MESSAGE}" ]]; then
                report_text+="； 错误消息：${ERROR_MESSAGE}"
            else
                report_text+="。"
            fi
            ;;
    esac

    send_robot_notify report_text message_color patulous_content patulous_color
}

function git_clean_local() {
    echo "Delete all untracked files." &&
        git clean -fdx
    echo "Discard all uncommitted changes." &&
        git restore -- *
    echo "Pull the latest code from upstream." &&
        git pull
    echo "Preparation is complete."
}

function update_remote_rules() {
    CONVERT2QX_SCRIPT="${SCRIPT_DIR}/Convert2QX.py"
    POST_PROCESS_SCRIPT="${SCRIPT_DIR}/QuantumultX/post_process.sh"

    for required_script in ${CONVERT2QX_SCRIPT} ${POST_PROCESS_SCRIPT}; do
        if ! [ -f "${required_script}" ]; then
            ERROR_MESSAGE="文件${required_script}不存在!"
            echo >&2 "${ERROR_MESSAGE}"
            return 1
        fi
    done

    if ! python3 "${CONVERT2QX_SCRIPT}"; then
        ERROR_MESSAGE="更新规则文件失败！"
        echo >&2 "${ERROR_MESSAGE}"
        return 1
    fi

    local -i changed_rules=0
    changed_rules=$(
        LANG=C git status |
            grep -E 'modified:[[:space:]]*QuantumultX' |
            awk '{print $2}' |
            sed 's|[^/]||g' |
            grep -c '^//'
    )
    if ! ((changed_rules)); then
        return 0
    fi
    # 只有在规则文件发生变更的时候，才做CIDR处理
    if ! bash "${POST_PROCESS_SCRIPT}"; then
        ERROR_MESSAGE="处理IP-CIDR失败!"
        echo >&2 "${ERROR_MESSAGE}"
        return 1
    fi

    return 0
}

#shellcheck disable=SC2034
function do_update_rule() {
    local notify_message="开始执行更新远程规则 ..."
    local message_color='#FF00FF' # 灯笼海棠(紫红色)

    send_robot_notify notify_message message_color
    if update_remote_rules; then
        return 0
    fi

    echo >&2 "Failed to update rules"
    message_color='#DC143C' # 猩红
    if [[ "${ERROR_MESSAGE}" ]]; then
        notify_message="执行更新远程规则失败，错误消息：${ERROR_MESSAGE}"
    else
        notify_message="执行更新远程规则失败。"
    fi
    send_robot_notify notify_message message_color
    return 1
}

function upload_to_github() {
    CHANGED_FILES_COUNT=$(LANG=C git status | grep -E 'modified:[[:space:]]*QuantumultX' -c)
    if ((CHANGED_FILES_COUNT > 0)); then
        readarray -t CHANGED_FILES_LIST < <(
            LANG=C git status | grep -E 'modified:[[:space:]]*QuantumultX' | awk '{print $2}'
        )
        echo "Add all changed files to stage ..."
        git add ./ -A || {
            ERROR_MESSAGE="未能添加已修改文件到暂存态。"
            return 1
        }
        git commit -s -m"$(date -R)" || {
            ERROR_MESSAGE="未能提交暂存态。"
            return 1
        }
        git push || {
            ERROR_MESSAGE="未能推送到远程仓库。"
            return 1
        }
        UPLOAD_STATUS=1
    else
        echo "No changes in QuantumultX"
        UPLOAD_STATUS=2
    fi

    send_finish_notify
}

{
    git_clean_local
    do_update_rule && {
        upload_to_github
    }
} || {
    exit 17
}
