Build a [Debian 'buster' 10](https://www.debian.org/) image for the [SolidRun ClearFog GT 8k](https://www.solid-run.com/marvell-armada-family/clearfog-gt-8k/).

## TODO

 * need to include `fsck.ext4` in first initramfs build
   * `Warning: couldn't identify filesystem type for fsck hook, ignoring`
   * [looks like this, but suggested fix seems not to work](https://isolated.site/2019/02/17/update-initramfs-fails-to-include-fsck-in-initrd/)

## Related Links

 * [Build a Debian 'buster' 10 image for the Orange Pi Zero](https://gitlab.com/jimdigriz/debian-orangepi-zero)
 * SolidRun
     * Armada 8040 U-Boot and ATF](https://developer.solid-run.com/knowledge-base/armada-8040-machiatobin-u-boot-and-atf/)

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

    make

After a while, downloading ~150MB plus roughly 10 mins, the project should emit a single file `rootfs.img`.

# Deploy

## Serial Port

You need access to the unit via the serial port which is fortunately straight forward to get working as the [documentation is very clear](https://developer.solid-run.com/knowledge-base/clearfog-gt-8k-getting-started/#connecting-a-usb-to-uart-adapter-to-clearfog-gt-8k).

The problem is if you have an enclosure as:

 * you cannot reassemble the enclosure with the serial cable plugged in with readily avaliable breadboard jumpers
 * you think this is okay
 * ...until you notice the SoC is *very* hot as the chassis is used as the heatsink and is no longer attached!
 * you order an [six (6) way female IDC with jumper pins at the other end](https://www.amazon.co.uk/gp/product/B07PNLC3ZG)
 * ...the plug is still too high
 * you take a scalpel to the IDC port to remove some of the height, now the lid fits
 * ...only to find that one of the chassis screw mounts is immediately next to the serial post and now cannot fit into place as the IDC port is also slightly too wide
 * you take the scalpel and shave off the clips on the side of the IDC port, now everything fits
 * meanwhile the thermal paste that *was* on the SoC is mostly gone, so you order and wait for some [thermal pads](https://www.amazon.co.uk/gp/product/B07YWTQVFV) (or thermal paste) to be delivered as last time I needed any was ten (10) years ago

Fortunatey, after all this nonsense (bet those non-enclosure users are smugly smiling) you can run the ribbon cable through one of the open holes on the side of the unit (or the rear if you prefer).

## rootfs

### Usage

 * the root filesystem will [automatically grow to fill the SD card on first boot](https://copyninja.info/blog/grow_rootfs.html)
 * there is no password for the `root` user, so you can log in trivially with the serial console
 * though `systemd-timesyncd` should automatically handle this for you, if you are too quick typing `apt-get update` you may find you need to fix up the current date time with `date -s 2019-09-25`
 * networking is configured through [`systemd-networkd`](https://wiki.archlinux.org/index.php/Systemd-networkd)
   * DHCP and IPv6 auto-configuration is setup for Ethernet

This is a stock regular no-frills Debian installation, of significant note is that it does not have an SSH server and you will need to manually configured the wireless networking to match your needs.

## u-boot

It is not necessary to do this stage but it is described for completeness.

We use a slightly different approach that what is [outlined by SolidRun on their website](https://developer.solid-run.com/knowledge-base/armada-8040-machiatobin-u-boot-and-atf/#from-u-boot):

 * using a USB stick for a 1.5MB image seems excessive
 * this approach covers what you need to do even when oyur unit is bricked
 * no need to use `download-serial.sh` when u-boot already has `mrvl_uart.sh` which is easily to get working

Start by building the firmware, downloading ~450MB plus roughly 10 mins:

    make flash-image.bin

We now upload the u-boot image via the serial port by running the following (it will walk you through the process):

    ./u-boot/tools/mrvl_uart.sh /dev/ttyUSB0 flash-image.bin

**N.B.** I was not able to get the accelerated upload functionality working

After the transfer you should see u-boot running and you can start pressing Ctrl-C to break out to the prompt.

We know now this image works, so it is time to burn it to the SPI flash by typing at the u-boot prompt:

    loadx $kernel_addr_r

To start the XMODEM transfer use `Ctrl-A`+`S` to select `flash-image.bin`.

    sf probe
    # optionally erase, usually not needed
    #sf erase 0 0x800000
    sf write $kernel_addr_r 0 0x$filesize
