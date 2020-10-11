Build a [Debian 'buster' 10](https://www.debian.org/) image for the [SolidRun ClearFog GT 8k](https://www.solid-run.com/marvell-armada-family/clearfog-gt-8k/).

**N.B.** this is a work-in-progress so not ready for public consumption; it is mostly a collection of unorganised notes so far

## TODO

 * `mmc write` explodes with `"Synchronous Abort" handler`
 * `usb start` with a USB3 key (todo, test USB2 works) explodes with `BUG at drivers/usb/host/xhci-ring.c abort_td()`

## Related Links

 * SolidRun
     * [ClearFog GT 8K - Product Overview](https://developer.solid-run.com/knowledge-base/clearfog-gt-8k-getting-started/)
     * [Armada 8040 U-Boot and ATF](https://developer.solid-run.com/knowledge-base/armada-8040-machiatobin-u-boot-and-atf/)
     * [ARMADA A8040 Debian](https://developer.solid-run.com/knowledge-base/armada-8040-debian/)
 * [`binfmt_misc`](https://en.wikipedia.org/wiki/Binfmt_misc) support on the host, and loaded (`modprobe binfmt_misc`)
 * [QEMU User Mode](https://ownyourbits.com/2018/06/13/transparently-running-binaries-from-any-architecture-in-linux-with-qemu-and-binfmt_misc/)
 * [Build a Debian 'buster' 10 image for the Orange Pi Zero](https://gitlab.com/jimdigriz/debian-orangepi-zero)

# Pre-flight

## Debian/Ubuntu

    sudo apt-get update
    sudo apt-get -y install --no-install-recommends \
        binfmt-support \
        debootstrap \
        gcc-aarch64-linux-gnu \
        git \
        lrzsz \
        minicom \
        netcat-openbsd \
        pv \
        qemu-user-static \
        tftpd-hpa
    sudo systemctl stop tftpd-hpa
    sudo systemctl disable tftpd-hpa

# Build

Build the root filesystem, downloads ~100MB plus roughly 10 mins, the project should emit a single file `emmc-image.bin`.

    make

**N.B.** you will be prompted to `sudo` up as parts of the build need to create devices, create mountpoints and read root owned files in the chroot

**N.B.** the [kernel used is from Debian backports](https://packages.debian.org/buster-backports/linux-image-arm64) as [stable does not have](https://packages.debian.org/buster/linux-image-arm64) the [necessary fixes in it yet](https://developer.solid-run.com/knowledge-base/armada-8040-debian/#pure-debian-upstream)

# Deploy

## Serial Port

You need access to the unit via the serial port which is fortunately straight forward to get working as the [documentation is very clear](https://developer.solid-run.com/knowledge-base/clearfog-gt-8k-getting-started/#connecting-a-usb-to-uart-adapter-to-clearfog-gt-8k).

The problem is if you have an enclosure as:

 * you cannot reassemble the enclosure with the serial cable plugged in as typical breadboard jumpers are too tall
 * you think this is okay
 * ...until you notice the SoC is *very* hot as the chassis is used as the heat sink and is no longer attached!
 * you order a [six way female IDC with jumper pins at the other end (POPESQ #A2559)](https://www.amazon.co.uk/gp/product/B07PNLC3ZG)
 * ...the plug is still too tall
 * you take a scalpel to the IDC to remove some of the height, now the lid fits
 * ...only to find that one of the chassis screw mounts is immediately next to the serial pins and now cannot fit into place as the IDC is slightly too wide and causes mis-alignment
 * you take the scalpel and shave off the clips on the side of the IDC, now everything fits
 * meanwhile the thermal paste that *was* on the SoC is mostly gone, so you order and wait for some [thermal pads (20mm width x 0.5mm thick](https://www.amazon.co.uk/gp/product/B07YWTQVFV) (or thermal paste) to be delivered as last time I needed any was ten (10) years ago

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

As the eMMC image is ~7.3GiB (aka 8GB) we do not want to be uploading this over the serial port. This would not work anyway as the whole image would need to fit uncompressed within the 4GiB RAM that is available to the unit which is not going to happen. The final nail in the coffin is that `mmc write` in u-boot goes at a blazing ~32kiB/sec so really do not bother trying.

**N.B.** USB was not an option for two reasons, firstly the size of the image and RAM avaliable, but for me u-boot (v2020.10) crashes and reboots with the USB key I have.

Instead we will upload via a NIC (at 7MiB/s) via u-boot over TFTP.

Start by building the images:

    make emmc-image.bin initramfs.cpio.gz

From another terminal and from the product directory run:

    sudo in.tftpd -L -v -s .

Hook up the network into one of the LAN ports and run from u-boot:

    setenv ethact eth2
    setenv ethprime eth2
    setenv ipaddr 192.0.2.2
    tftpboot $kernel_addr_r 192.0.2.1:rootfs/vmlinuz
    tftpboot $ramdisk_addr_r 192.0.2.1:initramfs.cpio.gz
    tftpboot $fdt_addr_r 192.0.2.1:rootfs/boot/marvell/armada-8040-clearfog-gt-8k.dtb
    fdt addr $fdt_addr_r
    fdt resize
    fdt chosen ${ramdisk_addr_r} 0x20000000
    setenv bootargs earlyprintk panic=10 root=/dev/ram0 rw rdinit=/sbin/init
    bootefi $kernel_addr_r $fdt_addr_r

**N.B.** `fdt chosen` is setup to offer enough room for up to a 384MiB (`0x20000000 - ${ramdisk_addr_r}`) initramfs

You should see a login prompt after a while (username `root` with no password) and now should typ

    ip link set dev eth2 up
    ip link set dev lan4 up
    ip addr add 192.0.2.2/24 dev lan4

**N.B.** this assumes you are using 'LAN 1' and you should read the note on networking below if you are not

You should now be able to ping across the link.

Stop the TFTP server running in your other terminal and prepare `netcat` to do your file transfer:

    pv emmc-image.bin | nc -l -p 1234 -w 1

From your unit now run:

    busybox nc 192.0.2.1 1234 | dd bs=1M of=/dev/mmcblk0

The eMMC image has now been burnt and if you restart the system, from u-boot you should now see:

    => mmc part
    Partition Map for MMC device 0  --   Partition Type: EFI
    
    Part    Start LBA       End LBA         Name
            Attributes
            Type GUID
            Partition GUID
      1     0x00001000      0x00e127ff      "root"
            attrs:  0x0000000000000000
            type:   0fc63daf-8483-4772-8e79-3d69d8477de4
            guid:   2bc44c3b-619e-3348-a6a2-586abadf7483
      2     0x00e12800      0x00e8f7ff      "boot"
            attrs:  0x0000000000000000
            type:   0fc63daf-8483-4772-8e79-3d69d8477de4
            guid:   fba41e57-1b69-094e-a651-9f5ecdc87b5d
    
    => ls mmc 0:2
    <DIR>       1024 .
    <DIR>       1024 ..
    <DIR>      12288 lost+found
                  83 System.map-5.8.0-0.bpo.2-arm64
              245879 config-5.8.0-0.bpo.2-arm64
            22159216 vmlinuz-5.8.0-0.bpo.2-arm64
            27038636 initrd.img-5.8.0-0.bpo.2-arm64
    <SYM>         27 vmlinuz
    <SYM>         30 initrd.img
    <DIR>       1024 marvell

**N.B.** root filesystem partition is formatted with [F2FS](https://en.wikipedia.org/wiki/F2FS) and is not readable to u-boot

    load mmc 0:2 $kernel_addr_r vmlinuz
    load mmc 0:2 $ramdisk_addr_r initrd.img
    load mmc 0:2 $fdt_addr_r marvell/armada-8040-clearfog-gt-8k.dtb
    fdt addr $fdt_addr_r
    fdt resize
    fdt chosen ${ramdisk_addr_r} 0x20000000
    setenv bootargs earlyprintk panic=10 root=/dev/mmcblk0p1 rootdelay=10 ro
    bootefi $kernel_addr_r $fdt_addr_r

The vanilla Debian kernel and initramfs should now boot and your rootfs mount.

...TODO fix u-boot to boot automatically

# Usage

 * there is no password for the `root` user, so you can log in trivially with the serial console
 * though `systemd-timesyncd` should automatically handle this for you, if you are too quick typing `apt-get update` you may find you need to fix up the current date time with `date -s 2019-09-25`
 * networking is configured through [`systemd-networkd`](https://wiki.archlinux.org/index.php/Systemd-networkd)
   * DHCP and IPv6 auto-configuration is setup for Ethernet

This is a stock regular no-frills Debian installation, of significant note is that it does not have an SSH server and you will need to manually configured the networking to match your needs.

## Network

There are three network interfaces (`eth[0-2]`):

 * **`eth0`:** SFP port
 * **`eth1`:** WAN port
 * **`eth2`:** connected to a switch that provides the four LAN ports
     * each port is directly controllable from Linux
     * labelling seems to be reversed (ie. `lan1` is actually 'LAN 4' on the chassis)

The output looks like:

    root@clearfog:~# ip addr
    1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
        link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
        inet 127.0.0.1/8 scope host lo
           valid_lft forever preferred_lft forever
        inet6 ::1/128 scope host
           valid_lft forever preferred_lft forever
    2: eth0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN group default qlen 2048
        link/ether b2:3b:6c:b3:ee:d2 brd ff:ff:ff:ff:ff:ff
    3: eth1: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN group default qlen 2048
        link/ether 52:90:26:7a:e8:6c brd ff:ff:ff:ff:ff:ff
    4: eth2: <BROADCAST,MULTICAST> mtu 1508 qdisc noop state DOWN group default qlen 2048
        link/ether 02:a2:20:59:69:2d brd ff:ff:ff:ff:ff:ff
    5: lan2@eth2: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN group default qlen 1000
        link/ether 02:a2:20:59:69:2d brd ff:ff:ff:ff:ff:ff
    6: lan1@eth2: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN group default qlen 1000
        link/ether 02:a2:20:59:69:2d brd ff:ff:ff:ff:ff:ff
    7: lan4@eth2: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN group default qlen 1000
        link/ether 02:a2:20:59:69:2d brd ff:ff:ff:ff:ff:ff
    8: lan3@eth2: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN group default qlen 1000
        link/ether 02:a2:20:59:69:2d brd ff:ff:ff:ff:ff:ff

To bring up the `lanX` ports you first need to bring up it's 'parent' interface `eth2`:

    root@clearfog:~# ip link set dev eth2 up

Now you can configure the `lanX` ports as usual:

    root@clearfog:~# ip link set dev lan1 up
    root@clearfog:~# ip addr add 192.0.2.2/24 dev lan1

### SFP

Annoyingly my [VDSL2 SFP Modem](https://www.proscend.com/en/product/VDSL2-SFP-Modem-for-Telco/180-T.html) is ~3mm too high to fit in the SFP slot...so I am probably going to have to cut into the chassis.
