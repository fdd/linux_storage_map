#!/bin/bash
# get_vmware_dev_map.sh: prints the VMware SCSI device mapping.
#                        maps Linux and VMware SCSI host (adapters).
#
# ijula | Feb 27, 2018 A.D. | mailto: ionut.jula@emerson.com
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
declare -ri E_NO_VM='107'

## global definitions.
# ANSI escape sequences for some colors.
declare -r c_red="\\033[01;31m"
declare -r c_yellow="\\033[01;33m"
declare -r c_green="\\033[01;32m"
declare -r c_off="\\033[0m"
# static global variables.
# dynamic global variables.
declare hostname         # short hostname.
declare -i rhel_major    # RHEL major version.
declare -i rhel_minor    # RHEL minor version.
declare -a device_list   # array w/ HBTL device addresses.
declare lspci_path       # location of lspci(8).
declare scsi_id_path     # location of scsi_id(8).
declare dmsetup_path     # location of dmsetup(8).
declare oracle_asm_rules # contents of the oracle udev rules file.
declare scsi_host_map    # map of the SCSI Linux and VMware host mapping.
declare dmsetup_out      # `dmsetup ls` output.
declare kfod_out         # kfod output.


# main: magic starts here.
main()
{
    local -i return_code
    local opt                  # getopts options container.
    local opt_show_help='0'    # flag for show_help().
    local opt_print_csv='0'    # flag for print_csv().
    local opt_print_header='0' # flag for print_header().
    local opt_print_tab='0'    # flag for print_tab().
    local opt_print_header='0' # flag for print_header().
    local opt_get_asm_info='0' # flag for get_asm_info().
    local opt_print_map='0'    # flag for print_scsi_host_mapping().
    local script_basename      # basename of the script file.

    return_code='0' # init to avoid unbond errors.
    #script_basename="$(basename -- "$0")" # basename of the script file.
    script_basename="${0##*/}"             # using POSIX substitution.

    hostname="$(hostname -s)"

    # set the time format for the bash time builtin (now w/ colors!).
    # prints only the real elapsed time, in a long format, 3-digit precision.
    TIMEFORMAT=$"$(echo -e "${c_yellow}")[stderr]$(echo -e "${c_off}") Execution time: %3lR"

    while getopts ':hctvam' opt; do # prepend the option-string w/ ':'.
        case "$opt" in            # getopts is in silent mode.
            h) opt_show_help='1' ;;
            c) opt_print_csv='1' ;;
            t) opt_print_tab='1' ;;
            v) opt_print_header='1' ;;
            a) opt_get_asm_info='1' ;;
            m) opt_print_map='1' ;;
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
    check_if_vmware     # exit if not a VMware VM.
    check_bash_version  # exit if not bash v4.
    am_i_root           # exit if not root.

    set_path_binaries   # sets appropriate binary paths w/r/t the RHEL release.
    check_prerequisites # exit if prerequisites are not met.

    get_scsi_host_mapping # mandatory.
    if [[ "$opt_print_map" = '1' ]]; then
        print_scsi_host_mapping
    fi

    get_scsi_devices      # mandatory.

    # if requested by the `-a' option, retrieves ASM info as well.
    if [[ "$opt_get_asm_info" = '1' ]]; then
        get_asm_info
    fi

    if [[ "$opt_print_csv" = '1' ]]; then
        print_csv     # csv-only output.
    elif [[ "$opt_print_tab" = '1' ]]; then
        print_tab     # tabulated output.
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
    echo 'Displays VMware SCSI device mapping.'
    echo 'Needs to be ran as root (required by scsi_id(8), for raw device access).'
    echo ''
    echo '  -c  print csv output only.'
    echo '  -t  print tabulated output.'
    echo '  -v  print header (column descriptions, verbose).'
    echo '  -a  print ASM info as well (DG membership, DG name, and size in Mb).'
    echo '  -m  print IOport-PCI_addr and SCSI host mapping.'
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

# check_if_vmware: checks if this is a VMware VM.
check_if_vmware()
{
    declare sys_vendor

    # get the system vendor from /sys/.
    read -r sys_vendor < '/sys/class/dmi/id/sys_vendor'
    #echo_err "${c_yellow}[stderr]${c_off}" "sys_vendor: $sys_vendor" # _DEBUG.

    if [[ "$sys_vendor" =~ VMware ]]; then
        true
    else
        echo_err "${c_yellow}[stderr]${c_off}" \
            "sys_vendor: $sys_vendor" # _DEBUG.
        echo -e "${c_yellow}[stderr]${c_off}" \
            "Not running on VMware. Exiting. ${c_red}[ FAILED ]${c_off}"
        exit "$E_NO_VM"
    fi
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
#                    populates global variables: lspci_path, scsi_id_path,
#                                                dmsetup_path.
#                    WARNING: do not run this function in a subshell.
set_path_binaries()
{
    # set appropriate locations for binaries on RHEL 7 or 6.
    if [[ "$rhel_major" -eq 7 ]]; then
        lspci_path='/usr/sbin/lspci'
        scsi_id_path='/usr/lib/udev/scsi_id'
        dmsetup_path='/usr/sbin/dmsetup'
    else
        lspci_path='/sbin/lspci'
        scsi_id_path='/sbin/scsi_id'
        dmsetup_path='/sbin/dmsetup'
    fi
}

# check_prerequisites: checks for various binaries needed, exists if not met.
check_prerequisites()
{
    # check if lspci(8) is present.
    if [[ ! -f "$lspci_path" ]]; then
        echo_err "${c_yellow}[stderr]${c_off}" \
            "Missing: ${lspci_path} ${c_red}[ FAILED ]${c_off}"
        echo_err "${c_yellow}[stderr]${c_off}" \
            "Package \`pciutils' is missing. Exiting."
        exit "$E_NO_PREREQ"
    fi

    # check if scsi_id(8) is present.
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

# get_scsi_host_mapping: gets the Linux - VMware SCSI host mapping.
#                        populates global array: scsi_host_map[].
#                        WARNING: do not run this function in a subshell.
get_scsi_host_mapping()
{
    declare -i i
    declare -a pci_scsi_ctrl_addr_sorted        # PCI Bus addresses of all SCSI hosts.
    declare -a pci_scsi_ctrl_ioport      # IOport that a PCI Bus is attached to.
    declare -a pci_scsi_ctrl_ioport_hex  # IOport number in hex.
    declare -a pci_scsi_ctrl_sorted      # 
    declare -a pci_scsi_ctrl_addr_sorted # 

    # get the PIC address of all SCSI controllers (hosts).
    readarray -t pci_scsi_ctrl_addr <<< "$("$lspci_path" \
        | awk '/SCSI|scsi|storage/{print $1}'
    )"

    # retrieves the IOport number for each SCSI controller PCI address.
    # format: "ioport_number-pci_addr"
    # later used to sort the SCSI controllers by their IOport number.
    get_scsi_ctrl_ioport()
    {
        # for each SCSI controller, get its IO Port number, in hex.
        for i in "${!pci_scsi_ctrl_addr[@]}"; do
            #echo_err -n "SCSI_ctrl_${i}_addr:   " # _DEBUG.
            #echo_err "${pci_scsi_ctrl_addr[i]}"   # _DEBUG.
            pci_scsi_ctrl_ioport[i]="$("$lspci_path" -vs "${pci_scsi_ctrl_addr[i]}" \
                | awk '/I\/O ports at/{print $4}'
            )"
            #echo_err -n "SCSI_ctrl_${i}_ioport: " # _DEBUG.
            #echo_err "${pci_scsi_ctrl_ioport[i]}" # _DEBUG.
            pci_scsi_ctrl_ioport_hex[i]="$(printf '%d' 0x"${pci_scsi_ctrl_ioport[i]}")"
            #echo_err -n "SCSI_ctrl_${i}_ioport_num: " # _DEBUG.
            #echo_err "${pci_scsi_ctrl_ioport_hex[i]}" # _DEBUG.

            echo "${pci_scsi_ctrl_ioport_hex[i]}"-"${pci_scsi_ctrl_addr[i]}"
        done
    }

    # sort the SCSI controllers by their IOport number.
    # PCI Bus Enumeration:
    # a PCI device is attached to a unique address in the memory, an IOport.
    # for a PCI device to be addressed, first it must be mapped into the
    # IOport address space of a running system.
    # see '/proc/ioports' for a list of IOport address ranges used in Linux.
    # when the PCI Bus enumeration is performed at boot,
    # the PCI slots are accessed and read in the order of their IOport numbers.
    #
    # this will also be the detection order done by the kernel.
    # therefore, we get the Linux host and VMware controller association.
    readarray -t pci_scsi_ctrl_sorted < <(get_scsi_ctrl_ioport | sort -g)
    for i in "${!pci_scsi_ctrl_sorted[@]}"; do
        #echo "${pci_scsi_ctrl_sorted[i]}" # _DEBUG.
        pci_scsi_ctrl_addr_sorted[i]="$(echo "${pci_scsi_ctrl_sorted[i]}" \
            | awk -F'-' '{print $2}'
        )"
        #echo "${pci_scsi_ctrl_addr_sorted[i]}" # _DEBUG.

        # this creates a map of Linux SCSI hosts and VMware SCSI controllers.
        # i.e., the H in [H:B:T:L] --> SCSI(H:T).
        # array element content:  Linux SCSI Host.
        # array element position: VMware SCSI Controller.
        scsi_host_map[i]="$(basename \
            /sys/bus/pci/devices/0000:"${pci_scsi_ctrl_addr_sorted[i]}"/host* \
            | grep -o '[0-9]*'
        )"
        #echo "host${scsi_host_map[i]}" # _DEBUG.
    done
}

# print_scsi_host_mapping: prints the SCSI host mapping Linux:VMware.
print_scsi_host_mapping()
{
    declare -i i

    # print the vmw_pvscsi PCI device addresses and their IOports connected to.
    echo 'I/O port  : PCI dev addr'
    echo '----------+-------------'
    grep 'vmw_pvscsi' -B1 /proc/ioports | sed 's/^[ \t]*//; /--/d; /pvscsi/d'
    echo ''

    echo 'Mapping of VMware ParaVirtual SCSI controllers and Linux SCSI hosts:'
    echo 'VMware SCSI  :  Linux SCSI :   PCI Device'
    echo '-------------+---------------------------'
    for i in "${!scsi_host_map[@]}"; do
        echo -n "vmw_pvscsi ${i} : "
        echo -n "${scsi_host_map[i]}" "scsi_host : "
        # for each scsi_host, find its pci device.
        find /sys/bus/pci/devices/*/* -maxdepth 0 \
            -name "host${scsi_host_map[i]}" | awk -F'/' '{print $6}'
    done

    echo ''
}

# get_scsi_devices: gets the SCSI devices.
#                   populates global vars: oracle_asm_rules, device_list[],
#                                          dmsetup_out.
#                   WARNING: do not run this function in a subshell.
get_scsi_devices()
{
    declare devices
    declare scsi_device_dir
    declare -r oracle_asm_rules_file='/etc/udev/rules.d/99-oracle-asm.rules'

    if [[ -s "$oracle_asm_rules_file" ]]; then
        # demoggified method of populating a variable w/ the file contents.
        oracle_asm_rules="$(< "$oracle_asm_rules_file")"
    else
        oracle_asm_rules=''
    fi

    # run dmsetup(8) here so it will be executed only one time.
    # "$dmsetup_out" is a global variable.
    dmsetup_out="$("$dmsetup_path" deps -o blkdevname)"

    scsi_device_dir='/sys/class/scsi_device/'
    # change dir done right.
    cd "$scsi_device_dir" || {
        echo_err "Cannot access ${scsi_device_dir}. ${c_red}Exiting.${c_off}"
        exit "$E_NO_ACCESS"
    }

    #devices="$(ls -1Ud ./*:0 | tr -d './')"
    devices="$(find . -maxdepth 1 -name "*:0" | tr -d './')"
    #echo "$devices" # _DEBUG.
    readarray -t device_list <<< "$devices"
}

# get_asm_info: retrieves info for all ASM devices, using kfod().
#               populates global var: kfod_out.
#               WARNING: do not run this function in a subshell.
get_asm_info()
{
    declare -ri E_NO_ASM='404'

    # check if asm is running.
    # or using a more time-consuming option: `srvctl status asm'.
    if [[ "$(pgrep -f asm_ | wc -l)" -ge 1 ]]; then
        true # asm is running.
    else
        echo_err "${c_yellow}[stderr]${c_off}"\
            "ASM is not running. ${c_red}[ FAILED ]${c_off}"
        kfod_out=''
        return "$E_NO_ASM"
    fi

    # switch to the grid user and run kfod.
    # this is can be a pretty time-consuming operation.
    kfod_out="$(su - grid -c "kfod disks=all s=t ds=t" \
        | awk '/:/{print $1","$5","$4","$6","$2$3}' \
        | sed 's:/dev/oracle/::; s/p1,/,/; s/://'
    )"
    # kfod_out format:
    # asm_number,asm_name,membership_status,disk_group,size_mb.

    #echo_err "$kfod_out"; echo_err # _DEBUG.
}

# return_device_info: retrieve info for a given [H:B:T:L] device address.
# call: return_device_info <device_HBTL_addr>
return_device_info()
{
    declare -i i
    declare device_hbtl # $1.
    declare device_host
    declare device_target
    declare device_host_vmware
    declare sg_device_name
    declare block_device_name
    declare block_device_size
    declare device_vendor
    declare device_model
    declare device_wwid
    declare device_asm
    declare device_lvm

    # function arg check:
    if [[ $# -lt 1 ]]; then
        echo_err "${FUNCNAME[0]}(): no argument supplied, nothing to do."
        echo_err "usage: ${FUNCNAME[0]} <device_HBTL_addr>"
        return "$E_NO_ARGS"
    fi

    device_hbtl="$1"

    # get the H from H:B:T:L.
    device_host="${device_hbtl%%:*}"
    # get the T from H:B:T:L.
    device_target="$(echo "$device_hbtl" | awk -F':' '{print $3}')"
    # get the VMware Host number from the hosts map array:
    for i in "${!scsi_host_map[@]}"; do
        if [[ "$device_host" = "${scsi_host_map[i]}" ]]; then
            device_host_vmware="$i"
        else
            # it could be an IDE device (like CDR), keep the host number.
            device_host_vmware="$device_host"
        fi
    done

    sg_device_name="$(ls -1U \
        /sys/class/scsi_device/"$device_hbtl"/device/scsi_generic/ 2>/dev/null)"
    block_device_name="$(ls -1U \
        /sys/class/scsi_device/"$device_hbtl"/device/block/ 2>/dev/null)"

    # skip the VMware IDE CDR.
    if [[ "$block_device_name" = "sr0" ]]; then
        #echo_err "CDR" # _DEBUG.
        #return "$SUCCESS"
        true # _DEBUG.
    fi

    read -r device_vendor < /sys/class/scsi_device/"$device_hbtl"/device/vendor
    read -r device_model  < /sys/class/scsi_device/"$device_hbtl"/device/model
    device_vendor="$(trim_whitespace "$device_vendor")"
    device_model="$(trim_whitespace "$device_model")"

    if [[ -n "$block_device_name" ]]; then
        echo "$hostname"
        echo "$device_hbtl"
        echo "SCSI(${device_host_vmware}:${device_target})"
        echo "$device_vendor"
        echo "$device_model"
        echo "$sg_device_name"
        echo "$block_device_name"
        device_wwid="$("$scsi_id_path" -gud /dev/"$sg_device_name")"
        if [[ -n "$device_wwid" ]]; then
            echo "$device_wwid"
        else
            # disk.enableUUID is undefined or set to "false" in the .vmx file.
            device_wwid='NO_WWID'
            echo "$device_wwid"
        fi
        # parse the udev_rules file (also handling duplicate slashes, if any).
        # extract the ASM device name (non-partitioned: w/o "p1").
        device_asm="$(echo "$oracle_asm_rules" | grep "$device_wwid" \
            | grep -v '^#' \
            | awk '{FS=","; print $5}' \
            | grep -o '/.*$' \
            | sed 's:[/"]::g; /p1$/d'
        )"
        if [[ -n "$device_asm" ]]; then # an ASM device.
            echo "$device_asm"
            # asm_info requested via the `-a' option.
            if [[ "$opt_get_asm_info" -eq '1' ]]; then
                # fields selected: membership_status,disk_group,size_mb.
                echo "$kfod_out" | grep "$device_asm" \
                    | awk -F',' '{print $3","$4","$5}'
            fi
        else # not an ASM device, maybe LVM.
            device_lvm="$(echo "$dmsetup_out" \
                | sed "/(${block_device_name}[0-9]*/!d" \
                | sed 1q \
                | awk -F'-' '{print $1}' # get the vg_name.
            )"
            if [[ -n "$device_lvm" ]]; then # a LVM device.
                echo "$device_lvm"
            else # neither LVM, nor ASM, safe to call it a "NO_ASM" device.
                device_lvm='NO_ASM'
                echo "$device_lvm"
            fi
            # populate the rest of the 3 asm fields w/ placeholders.
            if [[ "$opt_get_asm_info" -eq '1' ]]; then
                echo 'NO_ASM'    # asm_name placeholder.
                echo 'NO_ASM_DG' # asm_disk_group placeholder.
                echo 'NO_ASM_SZ' # asm_size_mb placeholder.
            fi
        fi
        # get size of a block device, in sectors.
        # equivalent to a BLKGETSIZE ioctl request.
        # $(blockdev --getsize /dev/${block_device_name})
        read -r block_device_size < "/sys/block/${block_device_name}/size"
        if [[ -n "$block_device_size" ]]; then
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
        echo "SCSI(${device_host_vmware}:${device_target})"
        echo "$device_vendor"
        echo "$device_model"
        echo "$sg_device_name"
        echo 'NO_BLOCK_DEVICE'
    fi
}

# print_devices: prints full info for all devices.
print_devices()
{
    declare -i i

    for i in "${!device_list[@]}"; do
        echo -e "${c_yellow}Dev_${i}${c_off}"
        return_device_info "${device_list[i]}"
        echo ''
    done

    echo -e "${c_green}[Tip]${c_off}" "Use the \`-c' option for csv output."
}

# print_header: prints the header for csv and columnated output.
print_header()
{
    declare header_line_1
    declare header_line_2

    if [[ "$opt_get_asm_info" = '1' ]]; then
        header_line_1=('host,h:b:t:l,scsi(h:t),vendor,model,sg_dev,sd_dev,'
            'wwid,lvm_or_asm,status,disk_gr,size_mb,size_gb,size_gib')
        header_line_2=('----,-------,---------,------,-----,------,------,'
            '----,----------,------,-------,-------,-------,--------')
    else
        header_line_1=('host,h:b:t:l,scsi(h:t),vendor,model,sg_dev,sd_dev,'
            'wwid,lvm_or_asm,size_gb,size_gib')
        header_line_2=('----,-------,---------,------,-----,------,------,'
            '----,----------,-------,--------')
    fi

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
        return_device_info "${device_list[i]}" | tr '\n' ','
        echo ''
    done | sed 's/.$//; /^$/d' | sed n # buffered output (all text at once).
}

# print_tab: prints tabulated (columnated).
print_tab()
{
    { print_csv; } | column -s',' -t
}


# main exec entry point.
time main "$@"

### ## # eof. # ## ###.
