#!/bin/sh

# Enable strict shell mode
set -euo pipefail

PATH=/sbin:/bin:/usr/sbin:/usr/bin

MOUNT="/bin/mount"
UMOUNT="/bin/umount"

INIT="/sbin/init"
ROOT_ROINIT="/sbin/init"

ROOT_MOUNT="/mnt"
ROOT_RODEVICE=""
ROOT_RWDEVICE=""
ROOT_ROMOUNT="/media/rfs/ro"
ROOT_RWMOUNT="/media/rfs/rw"
ROOT_RWRESET="no"

early_setup() {
    mkdir -p /proc
    mkdir -p /sys
    $MOUNT -t proc proc /proc
    $MOUNT -t sysfs sysfs /sys
    grep -w "/dev" /proc/mounts >/dev/null || $MOUNT -t devtmpfs none /dev
}

read_args() {
    [ -z "${CMDLINE+x}" ] && CMDLINE=`cat /proc/cmdline`
    for arg in $CMDLINE; do
        optarg=`expr "x$arg" : 'x[^=]*=\(.*\)'`
        case $arg in
            root=*)
                ROOT_RODEVICE=$optarg ;;
            rootfstype=*)
                modprobe $optarg 2> /dev/null ;;
            rootinit=*)
                ROOT_ROINIT=$optarg ;;
            rootrw=*)
                ROOT_RWDEVICE=$optarg ;;
            rootrwfstype=*)
                modprobe $optarg 2> /dev/null ;;
            rootrwreset=*)
                ROOT_RWRESET=$optarg ;;
            init=*)
                INIT=$optarg ;;
        esac
    done
}

fatal() {
    echo $1 >$CONSOLE
    echo >$CONSOLE
    exec sh
}

early_setup

[ -z "${CONSOLE+x}" ] && CONSOLE="/dev/console"

read_args

mount_and_boot() {
    mkdir -p $ROOT_MOUNT $ROOT_ROMOUNT $ROOT_RWMOUNT

    # Build mount options for read only root filesystem.
    # If no read-only device was specified via kernel commandline, use current
    # rootfs.
    if [ -z "${ROOT_RODEVICE}" ]; then
	ROOT_ROMOUNTOPTIONS="--bind,ro /"
    else
	ROOT_ROMOUNTOPTIONS="-o ro,noatime,nodiratime $ROOT_RODEVICE"
    fi

    # Mount rootfs as read-only to mount-point
    if ! $MOUNT $ROOT_ROMOUNTOPTIONS $ROOT_ROMOUNT ; then
        fatal "Could not mount read-only rootfs"
    fi

    # If future init is the same as current file, use $ROOT_ROINIT
    # Tries to avoid loop to infinity if init is set to current file via
    # kernel commandline
    if cmp -s "$0" "$INIT"; then
	INIT="$ROOT_ROINIT"
    fi

    # Build mount options for read write root filesystem.
    # If no read-write device was specified via kernel commandline, use tmpfs.
    if [ -z "${ROOT_RWDEVICE}" ]; then
	ROOT_RWMOUNTOPTIONS="-t tmpfs -o rw,noatime,mode=755 tmpfs"
    else
	ROOT_RWMOUNTOPTIONS="-o rw,noatime,mode=755 $ROOT_RWDEVICE"
    fi

    # Mount read-write filesystem into initram rootfs
    if ! $MOUNT $ROOT_RWMOUNTOPTIONS $ROOT_RWMOUNT ; then
	fatal "Could not mount read-write rootfs"
    fi

    # Reset read-write filesystem if specified
    if [ "yes" == "$ROOT_RWRESET" -a -n "${ROOT_RWMOUNT}" ]; then
	rm -rf $ROOT_RWMOUNT/*
    fi

    # Determine which unification filesystem to use
    union_fs_type=""
    if grep -w "overlay" /proc/filesystems >/dev/null; then
	union_fs_type="overlay"
    elif grep -w "aufs" /proc/filesystems >/dev/null; then
	union_fs_type="aufs"
    else
	union_fs_type=""
    fi

    # Create/Mount overlay root filesystem 
    case $union_fs_type in
	"overlay")
	    mkdir -p $ROOT_RWMOUNT/upperdir $ROOT_RWMOUNT/work
	    $MOUNT -t overlay overlay -o "lowerdir=$ROOT_ROMOUNT,upperdir=$ROOT_RWMOUNT/upperdir,workdir=$ROOT_RWMOUNT/work" $ROOT_MOUNT
	    ;;
	"aufs")
	    $MOUNT -t aufs -o "dirs=$ROOT_RWMOUNT=rw:$ROOT_ROMOUNT=ro" aufs $ROOT_MOUNT
	    ;;
	"")
	    fatal "No overlay filesystem type available"
	    ;;
    esac

    # Move read-only and read-write root filesystem into the overlay filesystem
    mkdir -p $ROOT_MOUNT/$ROOT_ROMOUNT $ROOT_MOUNT/$ROOT_RWMOUNT
    $MOUNT -n --move $ROOT_ROMOUNT ${ROOT_MOUNT}/$ROOT_ROMOUNT
    $MOUNT -n --move $ROOT_RWMOUNT ${ROOT_MOUNT}/$ROOT_RWMOUNT

    $MOUNT -n --move /proc ${ROOT_MOUNT}/proc
    $MOUNT -n --move /sys ${ROOT_MOUNT}/sys
    $MOUNT -n --move /dev ${ROOT_MOUNT}/dev

    cd $ROOT_MOUNT

    # busybox switch_root supports -c option
    exec chroot $ROOT_MOUNT $INIT ||
        fatal "Couldn't chroot, dropping to shell"
}

mount_and_boot