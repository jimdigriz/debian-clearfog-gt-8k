Build a [Debian 'buster' 10](https://www.debian.org/) image for the [SolidRun ClearFog GT 8k](https://www.solid-run.com/marvell-armada-family/clearfog-gt-8k/).

**N.B.** this is a work-in-progress so not ready for public consumption; it is mostly a collection of unorganised notes so far

## TODO

 * need to include `fsck.ext4` in first initramfs build
   * `Warning: couldn't identify filesystem type for fsck hook, ignoring`
   * [looks like this, but suggested fix seems not to work](https://isolated.site/2019/02/17/update-initramfs-fails-to-include-fsck-in-initrd/)
 * `mmc write` explodes with `"Synchronous Abort" handler`
 * `usb start` with a USB3 key (todo, test USB2 works) explodes with `BUG at drivers/usb/host/xhci-ring.c abort_td()`
 * figure out why `ROOT_IMG_SIZE_MB` needs the `-1`

## Related Links

 * [Build a Debian 'buster' 10 image for the Orange Pi Zero](https://gitlab.com/jimdigriz/debian-orangepi-zero)
 * SolidRun
     * [ClearFog GT 8K - Product Overview](https://developer.solid-run.com/knowledge-base/clearfog-gt-8k-getting-started/)
     * [Armada 8040 U-Boot and ATF](https://developer.solid-run.com/knowledge-base/armada-8040-machiatobin-u-boot-and-atf/)
     * [ARMADA A8040 Debian](https://developer.solid-run.com/knowledge-base/armada-8040-debian/)

# Pre-flight

 * [`binfmt_misc`](https://en.wikipedia.org/wiki/Binfmt_misc) support on the host, and loaded (`modprobe binfmt_misc`)
 * [QEMU User Mode](https://ownyourbits.com/2018/06/13/transparently-running-binaries-from-any-architecture-in-linux-with-qemu-and-binfmt_misc/)

## Debian/Ubuntu

    sudo apt-get update
    sudo apt-get -y install --no-install-recommends \
        binfmt-support \
        debootstrap \
        gcc-aarch64-linux-gnu \
        git \
        lrzsz \
        minicom \
        qemu-user-static

# Build

Build the root filesystem, downloads ~100MB plus roughly 10 mins, the project should emit a single file `mmc-image.bin`.

    make

**N.B.** you will be prompted to `sudo` up as parts of the build need to create devices, create mountpoints and read root owned files in the chroot

# Deploy

## Serial Port

You need access to the unit via the serial port which is fortunately straight forward to get working as the [documentation is very clear](https://developer.solid-run.com/knowledge-base/clearfog-gt-8k-getting-started/#connecting-a-usb-to-uart-adapter-to-clearfog-gt-8k).

The problem is if you have an enclosure as:

 * you cannot reassemble the enclosure with the serial cable plugged in as typical breadboard jumpers are too tall
 * you think this is okay
 * ...until you notice the SoC is *very* hot as the chassis is used as the heat sink and is no longer attached!
 * you order a [six way female IDC with jumper pins at the other end (POPESQ #A2559)](https://www.amazon.co.uk/gp/product/B07PNLC3ZG)
 * ...the plug is still too tall
 * you take a scalpel to the IDC port to remove some of the height, now the lid fits
 * ...only to find that one of the chassis screw mounts is immediately next to the serial post and now cannot fit into place as the IDC port is also slightly too wide
 * you take the scalpel and shave off the clips on the side of the IDC port, now everything fits
 * meanwhile the thermal paste that *was* on the SoC is mostly gone, so you order and wait for some [thermal pads](https://www.amazon.co.uk/gp/product/B07YWTQVFV) (or thermal paste) to be delivered as last time I needed any was ten (10) years ago

Fortunate, after all this nonsense (bet those non-enclosure users are smugly smiling) you can run the ribbon cable through one of the open holes on the side of the unit (or the rear if you prefer).

## u-boot

You do not need to update u-boot, but if you wish to, I have detailed how to do this for you.

We use a slightly different approach that what is [outlined by SolidRun on their website](https://developer.solid-run.com/knowledge-base/armada-8040-machiatobin-u-boot-and-atf/#from-u-boot):

 * using a USB stick for a 1.5MB image seems excessive
 * this approach covers what you need to do even when your unit is bricked
 * no need to use `download-serial.sh` when u-boot already has `mrvl_uart.sh` which is easily to get working

Start by building the firmware, downloading ~200MB plus roughly 5 mins:

    make flash-image.bin

We now upload the u-boot image via the serial port by running the following (it will walk you through the process):

    ./u-boot/tools/mrvl_uart.sh /dev/ttyUSB0 flash-image.bin

**N.B.** I was not able to get the accelerated upload functionality working

After the transfer you should see u-boot running and you should interrupt the boot sequence to break out to the prompt.

We know now this image works, so it is time to burn it to the SPI flash by typing at the u-boot prompt:

    loadx $ramdisk_addr_r

Now start the XMODEM transfer by using `Ctrl-A`+`S` and select `flash-image.bin` from the project directory. Once complete you will be able to burn your new u-boot image to flash with:

    sf probe
    sf erase 0 0x800000
    sf write $ramdisk_addr_r 0 0x$filesize

## rootfs

    make
    make initramfs.cpio.gz

    setenv ethact eth2
    setenv ethprime eth2
    setenv ipaddr 192.0.2.2
    tftpboot $kernel_addr_r 192.0.2.1:rootfs/vmlinuz
    tftpboot $ramdisk_addr_r 192.0.2.1:initramfs.cpio.gz
    tftpboot $fdt_addr_r 192.0.2.1:u-boot/arch/arm/dts/armada-8040-clearfog-gt-8k.dtb
    fdt addr $fdt_addr_r
    fdt resize
    fdt chosen ${ramdisk_addr_r} 0x20000000
    setenv bootargs earlyprintk panic=10
    bootefi $kernel_addr_r $fdt_addr_r

### Network

    sudo in.tftpd -L -v -s .

http://wiki.macchiatobin.net/tiki-index.php?page=Use+network+in+U-Boot

    make mmc-image.bin

    setenv ethact eth2
    setenv ethprime eth2
    setenv ipaddr 192.0.2.2
    tftpboot $ramdisk_addr_r 192.0.2.1:mmc-image.bin
    mmc dev 0
    mmc erase 0 0x$filesize
    mmc write $ramdisk_addr_r 0 0x$filesize

The `mmc {erase,write} ...` commands takes a *long* time and provides no feedback.

### USB

...copy to USB key

uboot:

    usb start
    

### Usage

 * the root filesystem will [automatically grow to fill the SD card on first boot](https://copyninja.info/blog/grow_rootfs.html)
 * there is no password for the `root` user, so you can log in trivially with the serial console
 * though `systemd-timesyncd` should automatically handle this for you, if you are too quick typing `apt-get update` you may find you need to fix up the current date time with `date -s 2019-09-25`
 * networking is configured through [`systemd-networkd`](https://wiki.archlinux.org/index.php/Systemd-networkd)
   * DHCP and IPv6 auto-configuration is setup for Ethernet

This is a stock regular no-frills Debian installation, of significant note is that it does not have an SSH server and you will need to manually configured the wireless networking to match your needs.

