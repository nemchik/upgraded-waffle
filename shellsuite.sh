#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Usage Information
#/ Usage: shellsuite.sh [OPTION]
#/
#/ This is the main ShellSuite script.
#/
#/  -p --path
#/  -v --validator
#/  -f --flags
#/
usage() {
    grep '^#/' "${SCRIPTNAME}" | cut -c4- || echo "Failed to display usage information."
    exit
}

# Command Line Arguments
readonly ARGS=("$@")

# Script Information
# https://stackoverflow.com/a/246128/1384186
get_scriptname() {
    local SOURCE
    local DIR
    SOURCE="${BASH_SOURCE[0]}"
    while [[ -L ${SOURCE} ]]; do # resolve ${SOURCE} until the file is no longer a symlink
        DIR="$(cd -P "$(dirname "${SOURCE}")" > /dev/null && pwd)"
        SOURCE="$(readlink "${SOURCE}")"
        [[ ${SOURCE} != /* ]] && SOURCE="${DIR}/${SOURCE}" # if ${SOURCE} was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    echo "${SOURCE}"
}
readonly SCRIPTNAME="$(get_scriptname)"
readonly SCRIPTPATH="$(cd -P "$(dirname "${SCRIPTNAME}")" > /dev/null && pwd)"

# User/Group Information
readonly DETECTED_PUID=${SUDO_UID:-$UID}
readonly DETECTED_UNAME=$(id -un "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_PGID=$(id -g "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_UGROUP=$(id -gn "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_HOMEDIR=$(eval echo "~${DETECTED_UNAME}" 2> /dev/null || true)

# Colors
# https://misc.flogisoft.com/bash/tip_colors_and_formatting
readonly BLU='\e[34m'
readonly GRN='\e[32m'
readonly RED='\e[31m'
readonly YLW='\e[33m'
readonly NC='\e[0m'

# Log Functions
readonly LOG_FILE="/tmp/shellsuite.log"
sudo chown "${DETECTED_PUID:-$DETECTED_UNAME}":"${DETECTED_PGID:-$DETECTED_UGROUP}" "${LOG_FILE}" > /dev/null 2>&1 || true # This line should always use sudo
info() { echo -e "$(date +"%F %T") ${BLU}[INFO]${NC}       $*" | tee -a "${LOG_FILE}" >&2; }
warning() { echo -e "$(date +"%F %T") ${YLW}[WARNING]${NC}    $*" | tee -a "${LOG_FILE}" >&2; }
error() { echo -e "$(date +"%F %T") ${RED}[ERROR]${NC}      $*" | tee -a "${LOG_FILE}" >&2; }
fatal() {
    echo -e "$(date +"%F %T") ${RED}[FATAL]${NC}      $*" | tee -a "${LOG_FILE}" >&2
    exit 1
}

cmdline() {
    # http://www.kfirlavi.com/blog/2012/11/14/defensive-bash-programming/
    # http://kirk.webfinish.com/2009/10/bash-shell-script-to-use-getopts-with-gnu-style-long-positional-parameters/
    local ARG=
    local LOCAL_ARGS
    for ARG; do
        local DELIM=""
        case "${ARG}" in
            #translate --gnu-long-options to -g (short options)
            --flags) LOCAL_ARGS="${LOCAL_ARGS:-}-f " ;;
            --path) LOCAL_ARGS="${LOCAL_ARGS:-}-p " ;;
            --validator) LOCAL_ARGS="${LOCAL_ARGS:-}-v " ;;
            --debug) LOCAL_ARGS="${LOCAL_ARGS:-}-x " ;;
            #pass through anything else
            *)
                [[ ${ARG:0:1} == "-" ]] || DELIM='"'
                LOCAL_ARGS="${LOCAL_ARGS:-}${DELIM}${ARG}${DELIM} "
                ;;
        esac
    done

    #Reset the positional parameters to the short options
    eval set -- "${LOCAL_ARGS:-}"

    while getopts ":f:p:v:x" OPTION; do
        case ${OPTION} in
            f)
                if [[ ${OPTARG:0:1} != " " ]]; then
                    fatal "Flags must start with a space."
                fi
                readonly VALIDATIONFLAGS="${OPTARG[*]}"
                ;;
            p)
                readonly VALIDATIONPATH="${OPTARG[*]}"
                ;;
            v)
                if [[ -z ${VALIDATIONPATH:-} ]]; then
                    fatal "Path must be defined first."
                fi
                case ${OPTARG} in
                    bashate)
                        readonly VALIDATOR="docker run --rm -v ${VALIDATIONPATH}:${VALIDATIONPATH} textclean/bashate"
                        readonly VALIDATORCHECK="--show"
                        ;;
                    shellcheck)
                        readonly VALIDATOR="docker run --rm -v ${VALIDATIONPATH}:${VALIDATIONPATH} koalaman/shellcheck"
                        readonly VALIDATORCHECK="--version"
                        ;;
                    shfmt)
                        readonly VALIDATOR="docker run --rm -v ${VALIDATIONPATH}:${VALIDATIONPATH} mvdan/shfmt"
                        readonly VALIDATORCHECK="--version"
                        ;;
                    *)
                        fatal "Invalid validator option."
                        ;;
                esac
                ;;
            x)
                readonly DEBUG='-x'
                set -x
                ;;
            :)
                fatal "${OPTARG} requires an option."
                ;;
            *)
                usage
                exit
                ;;
        esac
    done
    return 0
}

# Main Function
main() {
    # Arch Check
    readonly ARCH=$(uname -m)
    if [[ ${ARCH} != "x86_64" ]]; then
        fatal "Unsupported architecture."
    fi

    # Set command line variables
    cmdline "${ARGS[@]:-}"

    # Confirm variables are set
    if [[ -z ${VALIDATIONPATH:-} ]]; then
        fatal "Path must be defined."
    fi
    if [[ -z ${VALIDATOR:-} ]]; then
        fatal "Validator must be defined."
    fi
    if [[ -z ${VALIDATIONFLAGS:-} ]]; then
        fatal "Flags must be defined."
    fi
    if [[ -z ${VALIDATORCHECK:-} ]]; then
        fatal "Check must be defined."
    fi

    # Check that the validator is installed
    eval "${VALIDATOR} ${VALIDATORCHECK}" || fatal "Failed to check ${VALIDATOR} version."

    # https://github.com/caarlos0/shell-ci-build
    info "Linting all executables and .*sh files with ${VALIDATOR}..."
    while IFS= read -r line; do
        if head -n1 "${VALIDATIONPATH}/${line}" | grep -q -E -w "sh|bash|dash|ksh"; then
            eval "${VALIDATOR} ${VALIDATIONFLAGS[*]} ${VALIDATIONPATH}/${line}" || fatal "Linting ${line}"
            info "Linting ${line}"
        else
            warning "Skipping ${line}..."
        fi
    done < <(git -C "${VALIDATIONPATH}" ls-tree -r HEAD | grep -E '^1007|.*\..*sh$' | awk '{print $4}')
    info "${VALIDATOR} validation complete."
}
main
