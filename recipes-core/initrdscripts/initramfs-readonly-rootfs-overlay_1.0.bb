require readonly-rootfs-overlay-init-script.inc

do_install:append() {
        install -d ${D}/dev
        mknod -m 622 ${D}/dev/console c 5 1
}

FILES:${PN} += "/dev"
