#!/bin/bash
# get_devs.sh: prints all the SCSI devices.
#
# ijula | Aug 16, 2018 A.D. | mailto: ionut.jula@emerson.com
# /* This is free and unencumbered software released into the public domain. */

set -o nounset  # treat unset variables as an error when substituting.
set -o pipefail # consider errors inside a pipe as pipeline errors.

## global error defs.
declare -ri SUCCESS='0'
declare -ri E_NO_ROOT='100'
declare -ri E_NO_ARGS='101'
declare -ri E_NO_ACCESS='102'
declare -ri E_INVAL_OPT='103'
declare -ri E_INVAL_OS='104'
declare -ri E_INVAL_BASH='105'
declare -ri E_NO_PREREQ='106'

## global definitions.
# ANSI escape sequences for some colors.
declare -r c_red="\\033[01;31m"
declare -r c_yellow="\\033[01;33m"
declare -r c_green="\\033[01;32m"
declare -r c_off="\\033[0m"
# static global variables.
# dynamic global variables.
declare hostname       # short hostname.
declare -i rhel_major  # RHEL major version.
declare -i rhel_minor  # RHEL minor version.
declare dmsetup_out    # `dmsetup ls` output.
declare -a device_list # array w/ HBTL device addresses.
declare scsi_id_path   # location of scsi_id(8).
declare dmsetup_path   # location of dmsetup(8).


# main: magic starts here.
main()
{
    local -i return_code
    local opt                        # getopts options container.
    local opt_show_help='0'          # flag for show_help().
    local opt_print_csv='0'          # flag for print_csv().
    local opt_print_tabulated='0'    # flag for print_tabulated().
    local opt_print_header='0'       # flag for print_header().
    local opt_print_paths='0'        # flag for print_paths().
    local script_basename            # basename of the script file.

    return_code='0' # init to avoid unbond errors.
    #script_basename="$(basename -- "$0")" # basename of the script file.
    script_basename="${0##*/}"             # using POSIX substitution.

    hostname="$(hostname -s)"

    # set the time format for the bash time builtin (now w/ colors!).
    # prints only the real elapsed time, in a long format, 3-digit precision.
    TIMEFORMAT=$"$(echo -e "${c_yellow}")[stderr]$(echo -e "${c_off}") Execution time: %3lR"

    while getopts ':hctvp' opt; do # prepend the option-string w/ ':'.
        case "$opt" in            # getopts is in silent mode.
            h) opt_show_help='1' ;;
            c) opt_print_csv='1' ;;
            t) opt_print_tabulated='1' ;;
            v) opt_print_header='1' ;;
            p) opt_print_paths='1' ;;
            \?)
                echo_err "${script_basename}: invalid option -- '$OPTARG'"
                echo_err "Try \`${script_basename} -h' for more information."
                exit "$E_INVAL_OPT"
                ;;
        esac
    done

    if [[ "$opt_show_help" = '1' ]]; then
        show_help
    fi

    check_os_version    # exit if OS and OS version are not supported.
    check_bash_version  # exit if not bash v4.
    am_i_root           # exit if not root.

    set_path_binaries   # sets appropriate binary paths w/r/t the RHEL release.
    check_prerequisites # exit if prerequisites are not met.

    # echo_err "get_devs()..." # _DEBUG.
    get_devs # initial run. mandatory.

    if [[ "$opt_print_csv" = '1' ]]; then
        print_csv       # csv-only output.
    elif [[ "$opt_print_paths" = '1' ]]; then
        print_paths     # for each LUN, print the number of paths.
    elif [[ "$opt_print_tabulated" = '1' ]]; then
        print_tabulated # tabulated output.
    else
        print_devices # fully colored output.
    fi

    return_code="$?"
    #printf '\nreturn code: %s\n' "$return_code" # _DEBUG.

    return "$return_code"
}

# show_help: prints help and usage info.
show_help()
{
    declare script_basename    # basename of the script file.
    script_basename="${0##*/}" # using POSIX substitution.

    echo "Usage: ${script_basename} [OPTION]..."
    echo ''
    echo 'Displays all the SCSI devices.'
    echo 'Needs to be ran as root (required by scsi_id(8), for raw device access).'
    echo ''
    echo '  -c  print csv output.'
    echo '  -t  print tabulated output (columnated).'
    echo '  -v  print header (column descriptions, verbose).'
    echo '  -p  for each LUN, print the number of paths.'
    echo '  -h  print this help message and exit.'
    echo ''
    echo 'Send bug reports to: <ionut.jula@emerson.com>.'
    echo 'This is free and unencumbered software released into the public domain.'

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

# am_i_root: to root or not to root?
am_i_root()
{
    if [[ "$EUID" -ne 0 ]]; then
        echo_err 'This must be run as root.'
        echo_err 'Required by scsi_id(8), for raw device access.'
        exit "$E_NO_ROOT"
    fi
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
    local extglob_was_off='1'
    shopt extglob >/dev/null && extglob_was_off='0'
    # turn 'extglob' on, if currently turned off.
    (( extglob_was_off )) && shopt -s extglob

    # trim leading and trailing whitespace.
    var="${var##+([[:space:]])}"
    var="${var%%+([[:space:]])}"
    # if 'extglob' was off before, turn it back off.
    (( extglob_was_off )) && shopt -u extglob

    echo -n "$var"  # print the trimmed string.
}

# check_bash_version: checks the bash version, exists if not at least v4.
check_bash_version()
{
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        echo_err "${c_yellow}[stderr]${c_off} bash version less than" \
            "v4 (${BASH_VERSION}). Exiting. ${c_red}[ FAILED ]${c_off}"
        exit "$E_INVAL_BASH"
    fi
}

# check_os_version: checks the OS version, exists if not supported.
#                   populates global variables: rhel_major, rhel_minor.
#                   WARNING: do not run this function in a subshell.
check_os_version()
{
    declare -r redhat_release_file='/etc/redhat-release'
    declare redhat_release_out
    declare redhat_release

    # check if gnu/linux system.
    if [[ "$OSTYPE" != 'linux-gnu' ]]; then
        echo_err "${c_yellow}[stderr]${c_off} Not a GNU/Linux system." \
            "Exiting. ${c_red}[ FAILED ]${c_off}"
        exit "$E_INVAL_OS"
    fi

    # check if RHEL.
    if [[ ! -f "$redhat_release_file" ]]; then
        echo_err "${c_yellow}[stderr]${c_off} Not a RHEL system." \
            "Exiting. ${c_red}[ FAILED ]${c_off}"
        exit "$E_INVAL_OS"
    else
        read -r redhat_release_out < "$redhat_release_file"
        redhat_release="${redhat_release_out:40:3}"
        rhel_major="${redhat_release%.*}"
        rhel_minor="${redhat_release#*.}"
        echo_err "$rhel_major" "$rhel_minor" 2>/dev/null # _DEBUG.
    fi

    # check if RHEL 6 or later.
    if ! [[ "$rhel_major" -ge 6 ]]; then
        echo_err "${c_yellow}[stderr]${c_off} Not RHEL 6 or later." \
            "Exiting. ${c_red}[ FAILED ]${c_off}"
        exit "$E_INVAL_OS"
    fi
}

# set_path_binaries: sets appropriate locations for the binaries required.
#                    populates global variables: scsi_id_path, dmsetup_path.
#                    WARNING: do not run this function in a subshell.
set_path_binaries()
{
    # set appropriate locations for binaries on RHEL 7 or 6.
    if [[ "$rhel_major" -eq 7 ]]; then
        scsi_id_path='/usr/lib/udev/scsi_id'
        dmsetup_path='/usr/sbin/dmsetup'
    else
        scsi_id_path='/sbin/scsi_id'
        dmsetup_path='/sbin/dmsetup'
    fi
}

# check_prerequisites: checks for various binaries needed, exists if not met.
check_prerequisites()
{
    # check if scsi_id() is present.
    if [[ ! -f "$scsi_id_path" ]]; then
        echo_err "${c_yellow}[stderr]${c_off}" \
            "Missing: ${scsi_id_path} ${c_red}[ FAILED ]${c_off}"
        echo_err "${c_yellow}[stderr]${c_off}" \
            "Package \`udev' is missing. Exiting."
        exit "$E_NO_PREREQ"
    fi

    # check if dmsetup(8) is present.
    if [[ ! -f "$dmsetup_path" ]]; then
        echo_err "${c_yellow}[stderr]${c_off}" \
            "Missing: ${dmsetup_path} ${c_red}[ FAILED ]${c_off}"
        echo_err "${c_yellow}[stderr]${c_off}" \
            "Package \`device-mapper' is missing. Exiting."
        exit "$E_NO_PREREQ"
    fi
}

# get_devs: gets all SCSI devices (HBTL addresses).
#           populates the global "device_list[]" array.
#           WARNING: do not run this function in a subshell.
get_devs()
{
    declare devices
    declare scsi_device_dir

    # run dmsetup(8) here so it will be executed only one time.
    # "$dmsetup_out" is a global variable.
    dmsetup_out="$("$dmsetup_path" ls --tree \
        -o blkdevname,inverted,compact,ascii)"

    scsi_device_dir='/sys/class/scsi_device/'
    # change dir done right.
    cd "$scsi_device_dir" || {
        echo_err "Cannot access ${scsi_device_dir}. ${c_red}Exiting.${c_off}"
        exit "$E_NO_ACCESS"
    }

    devices="$(find . -maxdepth 1 | tr -d './' | sed '/^\s*$/d')"
    #echo "$devices" # _DEBUG.
    readarray -t device_list <<< "$devices"
}

# return_device_info: retrieve info for a given [H:B:T:L] device address.
# call: return_device_info <device_HBTL_addr>
return_device_info()
{
    declare device_hbtl       # $1 ("H:B:T:L").
    declare device_lun        # LUN ID (IBM SVC term: SCSI ID).
    declare sg_device_name    # (/dev/)sg<xyz> (SCSI generic device).
    declare block_device_name # (/dev/)sd<xyz> (SCSI block device).
    declare block_device_size # number in 512 byte sectors.
    declare device_vendor     # SCSI device vendor.
    declare device_model      # SCSI device model.
    declare multipath_name    # name of the multipath dev of the SCSI device.
    declare device_wwid       # SCSI device WWID.

    # function arg check:
    if [[ $# -lt 1 ]]; then
        echo_err "${FUNCNAME[0]}(): no argument supplied, nothing to do."
        echo_err "usage: ${FUNCNAME[0]} <device_HBTL_addr>"
        return "$E_NO_ARGS"
    fi

    device_hbtl="$1"

    device_lun="$(echo "$device_hbtl" | awk -F':' '{print $4}')"

    sg_device_name="$(ls -1U \
        /sys/class/scsi_device/"$device_hbtl"/device/scsi_generic/ 2>/dev/null)"
    block_device_name="$(ls -1U \
        /sys/class/scsi_device/"$device_hbtl"/device/block/ 2>/dev/null)"

    read -r device_vendor < /sys/class/scsi_device/"$device_hbtl"/device/vendor
    read -r device_model < /sys/class/scsi_device/"$device_hbtl"/device/model
    device_vendor="$(trim_whitespace "$device_vendor")" # sed 's/[ \t]*$//'
    device_model="$(trim_whitespace "$device_model")"

    device_wwid="$("$scsi_id_path" -gud /dev/"$sg_device_name")"

    if [[ ! -z "$block_device_name" ]]; then
        echo "$hostname"
        echo "$device_hbtl"
        echo "$device_lun"
        echo "$device_vendor"
        echo "$device_model"
        echo "$sg_device_name"
        echo "$block_device_name"
        multipath_name="$(echo "$dmsetup_out" \
            | grep "<${block_device_name}>" \
            | tr '-' ' ' \
            | awk '{print $3}'
        )"
        echo "$multipath_name"
        echo "$device_wwid"

        # get size of a block device, in sectors.
        # equivalent to a BLKGETSIZE ioctl request.
        # $(blockdev --getsize /dev/${block_device_name})
        read -r block_device_size < "/sys/block/${block_device_name}/size"
        if [[ ! -z "$block_device_size" ]]; then
            #echo "$block_device_size" # _DEBUG.
            # sector_size: 512 bytes. size in bytes: 512 * number_of_sectors.
            # to be really pedantic, first send a BLKSSZGET ioctl request,
            # in order to get the device sector_size (ss), in bytes.
            # ioctl(fd, BLKSSZGET, &ss);
            # ss="$(blockdev --getss /dev/${block_device_name})"
            #echo "$((block_device_size * 512))" # _DEBUG.
            # equivalent: BLKGETSIZE64 ioctl request.
            # $(blockdev --getsize64 /dev/${block_device_name})
            awk -v s="$block_device_size" \
                'BEGIN{printf("%.1fGB\n", s*512 / 1000/1000/1000)}'
            #echo "$((block_device_size * 512 / 1024/1024/1024))GiB"
            awk -v s="$block_device_size" \
                'BEGIN{printf("%.1fGiB\n", s*512 / 1024/1024/1024)}'
        else
            echo 'ERROR_GETTING_SIZE'
        fi
    else
        echo "$hostname"
        echo "$device_hbtl"
        echo "$device_lun"
        echo "$device_vendor"
        echo "$device_model"
        echo "$sg_device_name"
        echo 'NO_BLOCK_DEVICE'
        echo "$device_wwid"
    fi
}

# print_devices: prints the devices, one per line.
print_devices()
{
    declare -i i

    for i in "${!device_list[@]}"; do
        ( (echo -e "${c_yellow}Dev_${i}${c_off}"
            return_device_info "${device_list[i]}"
            echo "") | sed n # buffered output (all text at once).
        ) | sed n &          # buffer together all compound outputs.
    done
    wait # wait for all the jobs to finish before going further.
    echo_err -n "\\n${c_yellow}[stderr]${c_off} All subshells finished. "
    echo_err "${c_green}[ OK ]${c_off}" # _DEBUG.

    echo -e "${c_green}[Tip]${c_off}" "Use the \`-c' option for csv output."
}

# print_header: prints the header for csv and columnated output.
print_header()
{
    declare header_line_1
    declare header_line_2

    header_line_1=('host,h:b:t:l,lun_id,vendor,model,sg_dev,sd_dev,multipath,'
        'wwid,size_gb,size_gib')
    header_line_2=('----,-------,------,------,-----,------,------,---------,'
        '----,-------,--------')

    IFS=''
    echo "${header_line_1[*]}"
    echo "${header_line_2[*]}"
}

# print_csv: prints csv-only output.
print_csv()
{
    declare -i i

    if [[ "$opt_print_header" = '1' ]]; then
        print_header
    fi

    for i in "${!device_list[@]}"; do
        # echo -n "${device_list[i]}," # _DEBUG.
        (return_device_info "${device_list[i]}" \
            | tr '\n' ','                    # convert to csv.
            echo "") | sed 's/.$//; /^$/d' & # remove trailing comma.
    done | sort -t',' -k2,2                  # sort by H:B:T:L address.
    wait # wait for all the jobs to finish before going further.
    echo_err -n "\\n${c_yellow}[stderr]${c_off} All subshells finished. "
    echo_err "${c_green}[ OK ]${c_off}" # _DEBUG.
}

# print_tabulated: prints tabulated (columnated).
print_tabulated()
{
    if [[ "$opt_print_header" = '1' ]]; then
        { #print_header;
          print_csv;
        } | column -s',' -t
    else
        { print_csv; } | column -s',' -t
    fi
}

# print_paths: for each LUN, print the number of paths.
print_paths()
{
    print_csv \
        | awk -F',' '{print $2}' \
        | awk -F':' '{print $4}' \
        | sort -n \
        | uniq -c \
        | awk '{print "LUN:" $2 " paths:" $1}'
}


# main exec entry point.
time main "$@"

### ## # eof. # ## ###.
