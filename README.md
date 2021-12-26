Build a [Debian 'bullseye' 11](https://www.debian.org/) image for the [SolidRun ClearFog GT 8k](https://www.solid-run.com/arm-servers-networking-platforms/macchiatobin/#gt8k).

## TODO

 * do something with the [`dmesg` output](dmesg)
 * u-boot (v2020.10) problems
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
        f2fs-tools \
        gcc-aarch64-linux-gnu \
        git \
        lrzsz \
        minicom \
        qemu-user-static \
        tftpd-hpa
    sudo systemctl stop tftpd-hpa
    sudo systemctl disable tftpd-hpa

# Deploy

## Serial Port

You need access to the unit via the serial port which is fortunately straight forward to get working as the [documentation is very clear](https://developer.solid-run.com/knowledge-base/clearfog-gt-8k-getting-started/#connecting-a-usb-to-uart-adapter-to-clearfog-gt-8k).

Connection settings are 115200n8.

### IDC

When using an IDC cable ([six way female IDC with jumper pins at the other end, POPESQ #A2559](https://www.amazon.co.uk/gp/product/B07PNLC3ZG)), orientate the red wire (wire 1) next to the marked arrow on the board next to the pins which points to the GND pin.

When plugging it into your [(FTDI) USB to TTL cable jumper serial adapter](https://ftdi-uk.shop/collections/usb-cables-ttl), connect wire 1 (red) to GND, wire 3 to TDX and wire 5 to RXD.

### Enclosure

There are problems if you have the enclosure:

 * you cannot reassemble the enclosure with the serial cable plugged in as typical breadboard jumpers are too tall
 * you think this is okay
 * ...until you notice the SoC is *very* hot as the chassis is used as the heat sink and is no longer attached!
 * you order yourself a female IDC with jumper pins thinking it looks like it will just fit
 * ...the plug is still too tall
 * you take a scalpel to the IDC to remove some of the height, now the lid fits
 * ...only to find that one of the chassis screw mounts is immediately next to the serial pins and now cannot fit into place as the IDC is slightly too wide and causes mis-alignment
 * you take the scalpel and shave off the clips on the side of the IDC, now everything fits
 * meanwhile the thermal paste that *was* on the SoC is mostly gone, so you order and wait for some [thermal pads (20mm width x 0.5mm thick)](https://www.amazon.co.uk/gp/product/B07YWTQVFV) to be delivered as last time I needed any was over a decade ago

Fortunately after all this nonsense (bet those non-enclosure users are smugly smiling) you can run the ribbon cable through one of the open holes on the side of the unit (or the rear if you prefer).

## rootfs

As the eMMC image is ~7.3GiB (aka 8GB) we do not want to be uploading this over the serial port. This would not work anyway as the whole image would need to fit uncompressed within the 4GiB RAM that is available to the unit which is not going to happen. The final nail in the coffin is that `mmc write` in u-boot goes at a blazing ~32kiB/sec so really do not bother trying.

**N.B.** USB was not an option for two reasons, firstly again due to the size of the image and RAM available, but that USB does not work under u-boot

Instead we will upload using the network via u-boot using TFTP.

Start by building the rootfs and needed images using (you need 500MiB of space on an `exec,suid,dev` mountpoint located at `rootfs` in the project directory):

    make emmc-image.bin initramfs.cpio.gz

**N.B.** you will be prompted to `sudo` up as parts of the build need to create devices, create mount points and read root owned files in the chroot

**N.B.** the [kernel used is from Debian backports](https://packages.debian.org/buster-backports/linux-image-arm64) as [stable does not have](https://packages.debian.org/bullseye/linux-image-arm64) the [necessary fixes for the DSA interfaces and `systemd-networkd` to work well together in it yet](https://github.com/systemd/systemd/issues/7478) found in kernel version 5.12 and later

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

You should see a login prompt after a while (username `root` with no password) and now should type:

    ip link set dev eth2 up
    ip link set dev lan4 up
    ip addr add 192.0.2.2/24 dev lan4

**N.B.** this assumes you are using 'LAN 1' and you should read the note on networking below if you are not

You should now be able to ping across the link.

    busybox ping 192.0.2.1

From your unit now run:

    busybox tftp -g -r emmc-image.bin -l /dev/mmcblk0 192.0.2.1

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

You now can boot into your stock Debian kernel and initramfs and use your new rootfs mount by typing:

    load mmc 0:2 $kernel_addr_r vmlinuz
    load mmc 0:2 $ramdisk_addr_r initrd.img
    load mmc 0:2 $fdt_addr_r marvell/armada-8040-clearfog-gt-8k.dtb
    fdt addr $fdt_addr_r
    fdt resize
    fdt chosen ${ramdisk_addr_r} 0x20000000
    setenv bootargs earlyprintk panic=10 root=/dev/mmcblk0p1 rootdelay=10 ro
    bootefi $kernel_addr_r $fdt_addr_r

If everything works, you can set u-boot to autoboot this with:

    setenv distro_bootcmd 'load mmc 0:2 $kernel_addr_r vmlinuz; load mmc 0:2 $ramdisk_addr_r initrd.img; load mmc 0:2 $fdt_addr_r marvell/armada-8040-clearfog-gt-8k.dtb; fdt addr $fdt_addr_r; fdt resize; fdt chosen ${ramdisk_addr_r} 0x20000000; setenv bootargs earlyprintk panic=10 root=/dev/mmcblk0p1 rootdelay=10 ro; bootefi $kernel_addr_r $fdt_addr_r'
    saveenv
    reset

**N.B.** use single quotes!

## u-boot

You do not need to update u-boot, but if you wish to, I have detailed how to do this for you.

A slightly different approach is used compared to what is [outlined by SolidRun on their website](https://developer.solid-run.com/knowledge-base/armada-8040-machiatobin-u-boot-and-atf/#from-u-boot):

 * using a USB stick for a 1.5MB image seems excessive
     * USB does not work under u-boot for me anyway
 * this approach covers what you need to do even when your unit is bricked
 * no need to use [`download-serial.sh`](https://github.com/SolidRun/u-boot-armada38x/blob/u-boot-2013.01-15t1-clearfog/download-serial.sh) when avaliable is [`mrvl_uart.sh`](https://gitlab.denx.de/u-boot/u-boot/-/blob/master/tools/mrvl_uart.sh) supplied with u-boot which I found easier to get working

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

# Usage

Be aware of the follow:

 * there is no password for the `root` user, so you can log in trivially with the serial console
 * if you need to edit files before you are able to install packages you can use `busybox vi ...`
 * though `systemd-timesyncd` should automatically handle this for you, if you are too quick typing `apt-get update` you may find you need to fix up the current date time with `date -s 2019-09-25`
 * networking is unconfigured, it is recommended you use [`systemd-networkd` as described below](#systemd-networkd)

This is a stock regular no-frills Debian installation, of significant note is that it does not have an SSH server and you will need to manually configured the networking to match your needs.

## Network

There are three network interfaces (`eth[0-2]`):

 * **`eth0`:** SFP port
 * **`eth1`:** WAN port
 * **`eth2`:** connected to a switch that provides the four LAN ports
     * each port is directly controllable from Linux
     * labelling seems to be reversed (ie. `lan1` is actually 'LAN 4' on the chassis)
     * though each `lanX` port is 1Gbps the CPU access to this is only 2.5Gbps

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

Annoyingly my [Proscend 180-T VDSL2 SFP Modem](https://www.proscend.com/en/product/VDSL2-SFP-Modem-for-Telco/180-T.html) is ~3mm too high to fit in the SFP slot...instead I will have to plug it into my [Cisco Catalyst 3750-X](https://www.cisco.com/c/en/us/support/switches/catalyst-3750-x-series-switches/series.html) switch instead.

#### PPPoE

Running a xDSL PPPoE connection over the SFP should be otherwise straight forward with something like

    root@clearfog:~# ip link add link eth0 vlan101 type vlan id 101
    root@clearfog:~# ip link set vlan101 up
    root@clearfog:~# pppd plugin rp-pppoe.so user USERNAME password PASSWORD nodetach vlan101
    Plugin rp-pppoe.so loaded.
    PPP session is 5876
    Connected to 11:22:33:44:55:66 via interface vlan101
    Using interface ppp0
    Connect: ppp0 <--> vlan101
    CHAP authentication succeeded
    CHAP authentication succeeded
    peer from calling number 11:22:33:44:55:66 authorized
    local  IP address 198.51.100.1
    remote IP address 198.51.100.0

### `systemd-networkd`

Whether you like it or not, [systemd-networkd](https://wiki.archlinux.org/index.php/Systemd-networkd) is what is expected.

My topology is:

    vlan10 [untagged] --\
    vlanX  [tagged] ----|
    vlanY  [tagged] ----|
    vlanZ  [tagged] ----|
    vlan.  [tagged] ----|
                        |
    lan1 [eth2] --\     |
    lan2 [eth2] --+--- lan --- switch trunk port native VLAN 10
    lan3 [eth2] --|
    lan4 [eth2] --/
    
    wan [pppoe] -- eth1 ------ switch access port VLAN 101
    
    eth0  [sfp] -- UNUSED

Notes:

 * **`lan`:** carries tagged VLANs except for VLAN 10 (local LAN) which is untagged ('native')
 * **`wan`:** my [VDSL connection uses PPPoE](https://scarff.id.au/blog/2021/internode-ipv6-on-linux-with-systemd-networkd/)
     * `eth1` is connected to an access port set to VLAN 101 that is passed to my VDSL2 SFP Modem plugged into my switch as a tagged VLAN
 * **`vlan10`:** not actually created, as the IP address is set directly on `bond0`
 * **`vlan...`:** any number of tagged VLAN interfaces

Enable `systemd-networkd` (and `systemd-resolved`) with:

    ln -f -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl enable systemd-resolved
    systemctl enable systemd-networkd

#### Configuration Files

After creating the following files (and editing to suit you local site) you should run:

    systemctl restart systemd-resolved
    systemctl restart systemd-networkd

##### `/etc/systemd/network/lan.netdev`

    [NetDev]
    Name=lan
    Kind=bond
    MACAddress=00:11:22:33:44:55
    
    [Bond]
    Mode=802.3ad
    TransmitHashPolicy=encap2+3

##### `/etc/systemd/network/lan.network`

    [Match]
    Name=lan
    
    [Network]
    BindCarrier=lan1 lan2 lan3 lan4
    VLAN=vlan20
    LinkLocalAddressing=ipv6
    IPv6AcceptRA=no
    IPv6PrefixDelegation=yes
    Address=192.168.1.2/24
    Gateway=192.168.1.1
    DNS=1.1.1.1
    
    [IPv6PrefixDelegation]
    RouterLifetimeSec=3600

    [Link]
    RequiredForOnline=no

###### `/etc/modules`

Run the following:

    printf 'bonding\n8021q\n' >> /etc/modules

This is used to resolve a race do DSA interfaces.

##### `/etc/systemd/network/eth2-lan.network`

    [Match]
    Name=lan1 lan2 lan3 lan4
    
    [Network]
    Bond=lan
    
    [Link]
    RequiredForOnline=no

##### `/etc/systemd/network/vlan20.netdev`

    [NetDev]
    Name=vlan20
    Kind=vlan
    MACAddress=00:11:22:33:44:55
    
    [VLAN]
    Id=20

##### `/etc/systemd/network/vlan20.network`

    [Match]
    Name=vlan20
    
    [Network]
    BindCarrier=lan
    Address=192.0.2.1/24
    
    [Link]
    RequiredForOnline=no

##### `/etc/systemd/network/wan.network`

    [Match]
    Name=wan
    Type=ppp
    
    [Network]
    BindCarrier=eth1
    DHCP=ipv6
    
    [DHCP]
    ForceDHCPv6PDOtherInformation=yes
    
    [Link]
    RequiredForOnline=yes

##### `/etc/ppp/peers/wan`

    username someusername
    password somepassword
    +ipv6

Set the permissions of the file with:

    chmod 640 /etc/ppp/peers/eth1

##### `/etc/systemd/system/pppd-eth1@wan.service`

    # https://scarff.id.au/blog/2021/internode-ipv6-on-linux-with-systemd-networkd/
    # https://github.com/systemd/systemd/issues/481#issuecomment-544337575
    [Unit]
    Description=PPP connection for %I
    Documentation=man:pppd(8)
    BindsTo=sys-subsystem-net-devices-%j.device
    After=sys-subsystem-net-devices-%j.device
    After=network.target
    
    [Service]
    Type=forking
    ExecStart=/usr/sbin/pppd plugin rp-pppoe.so %j call %i linkname %j ifname %i updetach
    ExecStop=/bin/kill $MAINPID
    ExecReload=/bin/kill -HUP $MAINPID
    StandardOutput=null
    # https://github.com/systemd/systemd/issues/481#issuecomment-544341423
    Restart=always
    PrivateTmp=yes
    ProtectHome=yes
    ProtectSystem=strict
    ReadWritePaths=/run/
    # https://github.com/systemd/systemd/issues/481#issuecomment-610951209
    #ProtectKernelTunables=yes
    ProtectControlGroups=yes
    SystemCallFilter=~@mount
    SystemCallArchitectures=native
    LockPersonality=yes
    MemoryDenyWriteExecute=yes
    RestrictRealtime=yes
    
    [Install]
    WantedBy=sys-devices-virtual-net-%i.device

Enable the service with:

    systemctl enable pppd-eth1@wan.service

## Kernel Upgrade

When upgrading the kernel, make sure you symlink in the `/boot/{vmlinuz,initrd.img}` and update `/boot/marvell/armada-8040-clearfog-gt-8k.dtb.orig`:

    apt-get install linux-image-arm64
    ln -f -s vmlinuz-5.14.0-0.bpo.2-arm64 /boot/vmlinuz
    ln -f -s initrd.img-5.14.0-0.bpo.2-arm64 /boot/initrd.img
    cp /boot/marvell/armada-8040-clearfog-gt-8k.dtb /boot/marvell/armada-8040-clearfog-gt-8k.dtb.orig
    cp /usr/lib/linux-image-5.14.0-0.bpo.2-arm64/marvell/armada-8040-clearfog-gt-8k.dtb /boot/marvell

Once done you should be able to reboot.
