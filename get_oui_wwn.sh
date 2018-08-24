#!/bin/bash
# get_oui_wwn.sh: WWN lookup (also resolves WWIDs).
#
# ijula | Feb 23, 2018 A.D. | mailto: ionut.jula@emerson.com
# /* This is free and unencumbered software released into the public domain. */

set -o nounset    # treat unset variables as an error when substituting.
set -o pipefail   # consider errors inside a pipe as pipeline errors.
shopt -s extglob  # extended pattern matching.

## global error defs.
declare -ri SUCCESS="0"
declare -ri E_NO_ARGS="101"
declare -ri E_NO_ACCESS="102"
declare -ri E_INVAL_OPT="103"
declare -ri E_INVAL_WWN="104"

## global definitions.
# ANSI escape sequences for some colors.
declare -r c_red="\\033[01;31m"
declare -r c_yellow="\\033[01;33m"
declare -r c_green="\\033[01;32m"
declare -r c_off="\\033[0m"
# static global variables.
declare -r oui_dir="/unix/tools/lib"
declare -r oui_file="oui.txt"
# dynamic global variables.
# n/a.


# main: magic starts here.
main()
{
    local -i return_code
    local opt                     # getopts options container.
    local opt_show_help="0"       # show_help() flag.
    local opt_show_examples="0"   # show_examples() flag.
    local opt_update_oui_file="0" # update_oui_file() flag.
    local script_basename         # basename of the script file.
    local input_addr              # $1 - the address to lookup.

    return_code="0" # init to avoid unbond errors.
    #script_basename="$(basename -- "$0")"   # basename of the script file.
    script_basename="${0##*/}"               # using POSIX substitution.

    # set the time format for the bash time builtin (now w/ colors!).
    # prints only the real elapsed time, in a long format, 3-digit precision.
    TIMEFORMAT=$"$(echo -e "${c_yellow}")[stderr]$(echo -e "${c_off}") Execution time: %3lR"

    while getopts ":heu" opt; do   # prepend the option-string w/ ':'.
        case "$opt" in            # getopts is in silent mode.
            h) opt_show_help="1" ;;
            e) opt_show_examples="1" ;;
            u) opt_update_oui_file="1" ;;
            \?)
                echo_err "${script_basename}: invalid option -- '$OPTARG'"
                echo_err "Try \`${script_basename} -h' for more information."
                exit "$E_INVAL_OPT"
                ;;
        esac
    done

    if [[ "$opt_show_help" = "1" ]]; then
        show_help
        #shift
    fi

    if [[ "$opt_show_examples" = "1" ]]; then
        show_examples
        #shift
    fi

    if [[ "$opt_update_oui_file" = "1" ]]; then
        update_oui_file
        shift
    fi

    # function arg check:
    if [[ $# -lt 1 ]]; then
        echo_err "${script_basename}: No input WWN address supplied."
        echo_err "Usage: ${script_basename} <input_addr>"
        echo_err "Try \`${script_basename} -h' for more information."
        return "$E_NO_ARGS"
    fi

    input_addr="$1"

    check_oui_file           # checks if the 'oui.txt' file already exists.
    lookup_oui "$input_addr" # performs the OUI lookup.

    return_code="$?"
    #printf '\nreturn code: %s\n' "$return_code" # _DEBUG.

    return "$return_code"
}


# show_help: prints help and usage info.
show_help()
{
    declare script_basename    # basename of the script file.
    script_basename="${0##*/}" # using POSIX substitution.

    echo "Usage: ${script_basename} [OPTION]... <WWN>
Lookup of a WWN or WWID address.

Options:
    -u  updates (re-downloads) the oui.txt file.
    -e  show WWN examples and exit.
    -h  print this help message and exit.

Send bug reports to: <ionut.jula@emerson.com>.
This is free and unencumbered software released into the public domain."

    exit "$SUCCESS"
}

# show_examples: prints WWN examples.
show_examples()
{
    declare script_basename    # basename of the script file.
    script_basename="${0##*/}" # using POSIX substitution.

    echo "WWN and WWID examples, different vendors and formats:

IBM SVC WWID (OUI 005076, IBM Corp):
    3600507680181071900000000000036DC
IBM SVC Target WWPN (OUI 005076, IBM Corp):
    50:05:07:68:0c:51:1e:1a
IBM XIV WWID (OUI 001738, International Business Machines):
    20017380066BA1179
Dell Port WWPN (OUI 4C7625, Dell Inc.):
    20:02:4c:76:25:c4:25:fe
Cisco Fabric WWN (OUI 000DEC, Cisco Systems, Inc):
    22:26:00:0d:ec:b7:1a:41

Send bug reports to: <ionut.jula@emerson.com>.
This is free and unencumbered software released into the public domain."

    exit "$SUCCESS"
}

# printf_err: printf to stderr.
printf_err()
{
    printf '%s\n' "$@" 1>&2
}

# echo_err: echoes the supplied arguments to stderr.
echo_err()
{
    echo -e "$@" 1>&2
}

# trim_whitespace: trims leading/trailing whitespace using the extglob shopt.
# call: trim_whitespace <string_to_be_trimmed>
trim_whitespace()
{
    declare var # $1.

    # function arg check:
    if [[ $# -lt 1 ]]; then
        echo_err "${FUNCNAME[0]}(): no argument supplied, nothing to do."
        echo_err "usage: ${FUNCNAME[0]} <string_to_be_trimmed>"
        return "$E_NO_ARGS"
    fi

    var="$1"

    # determine if 'extglob' is currently on.
    local extglob_was_off="1"
    shopt extglob >/dev/null && extglob_was_off="0"
    # turn 'extglob' on, if currently turned off.
    (( extglob_was_off )) && shopt -s extglob

    # trim leading and trailing whitespace.
    var="${var##+([[:space:]])}"
    var="${var%%+([[:space:]])}"
    # if 'extglob' was off before, turn it back off.
    (( extglob_was_off )) && shopt -u extglob

    echo -n "$var"  # print the trimmed string.
}

# check_oui_file: checks if the 'oui.txt' file exists.
check_oui_file()
{
    if [[ ! -s "${oui_dir}/${oui_file}" ]]; then
        echo_err "${c_yellow}[stderr]${c_off}" \
            "File ${oui_dir}/${oui_file} does not exist."
        echo_err "Downloading the oui.txt file..."
        update_oui_file
    else
        true
        #echo_err "${c_yellow}[stderr]${c_off}" \
        #    "File ${oui_dir}/${oui_file} already exists."
    fi
}

# update_oui_file: updates the oui.txt file (downloads it again).
update_oui_file()
{
    declare -i curl_return_code
    declare -r oui_url="http://standards-oui.ieee.org/oui/oui.txt"

    # change dir done right.
    cd "$oui_dir" || {
        echo_err "Cannot access ${oui_dir}. ${c_red}Exiting.${c_off}"
        exit "$E_NO_ACCESS"
    }

    # handle signals INT, TERM, and QUIT, then exit afterwards.
    #trap "echo; echo ${FUNCNAME[0]}\(\) interrupted.; exit" INT
    curl_sighandler()
    {
        declare signal

        # function arg check:
        if [[ $# -lt 1 ]]; then
            echo_err "${FUNCNAME[0]}(): no argument supplied, nothing to do."
            echo_err "usage: ${FUNCNAME[0]} <input_signal>"
            return "$E_NO_ARGS"
        fi

        signal="$1"

        echo ""
        echo -en "${c_yellow}[ ${signal} ]${c_off} "
        echo -en "Download interrupted (received ${signal})."
        echo
        ls -l "$oui_file"
        if rm "$oui_file"; then
            echo -e "Cleanup: ${oui_file} has been removed." \
                "${c_green}[ OK ]${c_off}"
        else
            echo -e "Cleanup: removing the ${oui_file} file failed." \
                "${c_red}[ FAILED ]${c_off}"
        fi

        exit "$SUCCESS"
    }

    trap 'curl_sighandler SIGINT'  INT
    trap 'curl_sighandler SIGTERM' TERM
    trap 'curl_sighandler SIGQUIT' QUIT

    # if the file already exists, remove it first.
    if [[ -s "$oui_file" ]]; then
        echo "Removing existing file..."
        if rm "$oui_file"; then
            echo -e "Removing the existing file succeeded." \
                "${c_green}[ OK ]${c_off}"
        else
            echo -e "Removing the existing file failed." \
                "${c_red}[ FAILED ]${c_off}"
            exit "$E_NO_ACCESS"
        fi
    fi

    # download a new file.
    echo "Downloading the file... Please wait."
    echo "Running: curl -O ${oui_url}"
    curl -O "$oui_url"
    curl_return_code="$?"

    if [[ "$curl_return_code" -ne 0 ]]; then
        echo -e "Download error. ${c_red}[ FAILED ]${c_off}"
        exit "$curl_return_code"
    else
        echo -e "Download successful. ${c_green}[ OK ]${c_off}"
        return "$curl_return_code"
    fi
}

# validate_address: validates a WWN address.
# call: validate_address <input_addr>
validate_address()
{
    declare input_addr

    # function arg check:
    if [[ $# -lt 1 ]]; then
        echo_err "${FUNCNAME[0]}(): no argument supplied, nothing to do."
        echo_err "usage: ${FUNCNAME[0]} <input_addr>"
        return "$E_NO_ARGS"
    fi

    input_addr="$1"

    #echo_err "input_addr: $input_addr" # _DEBUG.
    #echo_err "input_addr length: ${#input_addr}" # _DEBUG.

    # string length must be at least 16 characters.
    if [[ ${#input_addr} -lt 16 ]]; then
        echo_err "Invalid input address: '${input_addr}'. ${c_red}[ FAILED ]${c_off}"
        exit "$E_INVAL_WWN"
    fi
}

# lookup_oui: extracts the OUI and greps "oui.txt", hoping to find a match.
# call: lookup_oui <input_addr>
lookup_oui()
{
    declare input_addr # $1.
    declare addr_stripped
    declare vendor

    # function arg check:
    if [[ $# -lt 1 ]]; then
        echo_err "${FUNCNAME[0]}(): no argument supplied, nothing to do."
        echo_err "usage: ${FUNCNAME[0]} <input_addr>"
        return "$E_NO_ARGS"
    fi

    input_addr="$1"

    # check if minimum address string length is met (at least 16 chars).
    validate_address "$input_addr"

    # strip off ':', '.' or '-'.
    addr_stripped="$(echo "${input_addr//[:.- ]/}" | tr "a-f" "A-F")"
    # strip off leading "0x", if any.
    if [[ "$addr_stripped" =~ ^0[xX] ]]; then
        addr_stripped="$(echo "$addr_stripped" | cut -c 3-)"
    fi

    # if the address is exactly 16 characters long, it's a WWN.
    if [[ "${#addr_stripped}" -eq 16 ]]; then
        echo "WWN:   " "$addr_stripped"
        # WWN: 16 hexadecimal digits, grouped as 8 pairs. WWN formats:
        # NAA=1: IEEE 803.2 Standard 48-bit ID.
        # NAA=2: IEEE 803.2 Extended 48-bit ID.
        # NAA=5: IEEE Registered Name.
        # NAA=6: IEEE Extended Registered Name.
        if [[ "$addr_stripped" =~ ^1000 ]]; then
            # NAA=1 - IEEE Standard (original format).
            # section_1: 2-byte fixed header: "10:00".
            # section_2: 3-byte OUI (6 digits).
            # section_3: 3-byte vendor-specified S/N (6 digits).
            oui="$(echo "$addr_stripped" | cut -c 5-10)"
        elif [[ "$addr_stripped" =~ ^2 ]]; then
            # NAA=2 - IEEE Extended.
            # section_1: 2-byte header: "2x:xx" (x ::= vendor-specified).
            # section_2: 3-byte OUI (6 digits).
            # section_3: 3-byte vendor-specified S/N (6 digits).
            oui="$(echo "$addr_stripped" | cut -c 5-10)"
        elif [[ "$addr_stripped" =~ ^5 ]]; then
            # NAA=5 - IEEE Registered Name.
            # section_1: 1-digit fixed id: "5" (Registered Name WWN identifier).
            # section_2: 6-digit OUI.
            # section_3: 9-digit vendor-specific generated code based on the S/N.
            oui="$(echo "$addr_stripped" | cut -c 2-7)"
        else
            oui="OUI_UNKNOWN"
        fi
    else # it's a WWID.
        echo "WWID:  " "$addr_stripped"
        # if the address is 17 characters long , it might be an IBM XIV WWID.
        if [[ "${#addr_stripped}" -eq 17 ]] && [[ "$addr_stripped" =~ ^2 ]]; then
            oui="$(echo "$addr_stripped" | cut -c 2-7)"
        # the address might be an IBM SVC WWID or a VMware WWID.
        elif [[ "$addr_stripped" =~ ^6 ]]; then
            # WWID: IBM SVC.
            oui="$(echo "$addr_stripped" | cut -c 2-7)"
        elif [[ "$addr_stripped" =~ ^36 ]]; then
            # WWID: IBM SVC w/ a leading "3", as displayed by the kernel driver.
            oui="$(echo "$addr_stripped" | cut -c 3-8)"
        else
            oui="OUI_UNKNOWN"
        fi
    fi

    echo "OUI:   " "$oui"

    # find match in the "oui.txt" list.
    if [[ "$oui" = "OUI_UNKNOWN" ]]; then
        vendor="VENDOR_UNKNOWN"
    else
        vendor="$(grep "$oui" "$oui_dir"/"$oui_file" | awk -F')' '{print $2}')"
        vendor="$(trim_whitespace "$vendor")"
        if [[ -z "$vendor" ]]; then # no match in the OUI database.
            vendor="VENDOR_NOT_FOUND"
        fi
    fi

    echo "Vendor: $vendor"
}


# main exec entry point.
main "$@" # time main "$@"

### ## # eof. # ## ###.
