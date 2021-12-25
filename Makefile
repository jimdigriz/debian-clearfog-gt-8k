SHELL = /bin/sh
.DELETE_ON_ERROR:

CLEAN =
DISTCLEAN =

GIT_TRIM ?= --single-branch --no-tags --depth 1

JOBS ?= $(shell echo $$(($$(getconf _NPROCESSORS_ONLN) + 1)))

# partition table lives in the first chunk and we want the F2FS to be block aligned
F2FS_SEGMENT_SIZE_MB = 2
# u-boot cmd 'mmc write $ramdisk_addr_r 0x2000000 0x1000'
EMMC_SIZE_MB ?= 7456

# supports roughly four pairs of kernel/initramfs
BOOT_IMG_SIZE_MB ?= 250
# -1 as the alternative GPT table lives at the end of the device
ROOT_IMG_SIZE_MB ?= $(shell echo $$(($(EMMC_SIZE_MB) - $(BOOT_IMG_SIZE_MB) - $(F2FS_SEGMENT_SIZE_MB) - 1)))

.PHONY: all
all:

initramfs.cpio.gz: rootfs/.stamp
	{ cd $(dir $<) && sudo find . ! -path './boot/*' ! -path ./etc/fstab | sudo cpio --quiet -H newc -o; } | gzip -1 -n -c > $@
CLEAN += initramfs.cpio.gz

u-boot/.stamp: UBOOT_GIT ?= https://gitlab.denx.de/u-boot/u-boot.git
u-boot/.stamp: UBOOT_REF ?= $(shell git ls-remote --tags $(UBOOT_GIT) | cut -f 2 | cut -d / -f 3 | sed -n -E -e '/^v[0-9]{4}\.[0-9]{2}$$/ p' | sort | tail -n1)
u-boot/.stamp:
	git clone $(GIT_TRIM) -b $(UBOOT_REF) $(UBOOT_GIT) $(@D)
	@touch $@
DISTCLEAN += u-boot

u-boot/u-boot.bin: u-boot/.stamp
	make -C $(@D) -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- clearfog_gt_8k_defconfig
	make -C $(@D) -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- tools
	make -C $(@D) -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu-

atf-marvell/.stamp: MARVELL_ATF_GIT ?= https://github.com/MarvellEmbeddedProcessors/atf-marvell.git
atf-marvell/.stamp: MARVELL_ATF_REF ?= atf-v1.5-armada-18.12
atf-marvell/.stamp:
	git clone $(GIT_TRIM) -b $(MARVELL_ATF_REF) $(MARVELL_ATF_GIT) $(@D)
	@touch $@
DISTCLEAN += atf-marvell

mv-ddr-marvell/.stamp: MARVELL_DDR_GIT ?= https://github.com/MarvellEmbeddedProcessors/mv-ddr-marvell.git
mv-ddr-marvell/.stamp: MARVELL_DDR_REF ?= mv_ddr-armada-18.12
mv-ddr-marvell/.stamp:
	git clone $(GIT_TRIM) -b $(MARVELL_DDR_REF) $(MARVELL_DDR_GIT) $(@D)
	# https://github.com/MarvellEmbeddedProcessors/mv-ddr-marvell/pull/19
	git -C $(@D) remote add pr19 https://github.com/philhofer/mv-ddr-marvell.git
	git -C $(@D) fetch pr19 mv_ddr-armada-18.12
	git -C $(@D) cherry-pick 1e4cd057a61000cf7d29f7047b68c2cade604465
	@touch $@
DISTCLEAN += mv-ddr-marvell

binaries-marvell/.stamp: MARVELL_BINARIES_GIT ?= https://github.com/MarvellEmbeddedProcessors/binaries-marvell.git
binaries-marvell/.stamp: MARVELL_BINARIES_REF ?= binaries-marvell-armada-18.12
binaries-marvell/.stamp:
	git clone $(GIT_TRIM) -b $(MARVELL_BINARIES_REF) $(MARVELL_BINARIES_GIT) $(@D)
	@touch $@
DISTCLEAN += binaries-marvell

atf-marvell/build/a80x0_mcbin/release/flash-image.bin: atf-marvell/.stamp mv-ddr-marvell/.stamp binaries-marvell/.stamp u-boot/u-boot.bin
atf-marvell/build/a80x0_mcbin/release/flash-image.bin:
	make -C atf-marvell -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- PLAT=a80x0_mcbin MV_DDR_PATH='$(CURDIR)/mv-ddr-marvell' SCP_BL2='$(CURDIR)/binaries-marvell/mrvl_scp_bl2.img' BL33='$(CURDIR)/u-boot/u-boot.bin' all fip

flash-image.bin: atf-marvell/build/a80x0_mcbin/release/flash-image.bin
	ln -f $< $@

emmc-image.bin: gpt.img boot.img rootfs.img
	cp --sparse=always $< $@
	dd bs=1M conv=notrunc,sparse seek=$(F2FS_SEGMENT_SIZE_MB) if=rootfs.img of=$@
	dd bs=1M conv=notrunc,sparse seek=$$(($(F2FS_SEGMENT_SIZE_MB) + $(ROOT_IMG_SIZE_MB))) if=boot.img of=$@
CLEAN += emmc-image.bin

gpt.img: boot.img
	truncate -s $(EMMC_SIZE_MB)M $@
	printf 'label: gpt\nstart=4096,size=%d,name=root\nsize=%d,name=boot,bootable\n' \
			$$(($(ROOT_IMG_SIZE_MB) * 1024 * 1024 / 512)) \
			$$(($(BOOT_IMG_SIZE_MB) * 1024 * 1024 / 512)) \
		| /sbin/sfdisk --no-reread --no-tell-kernel $@
CLEAN += gpt.img

boot.img: rootfs/.stamp
	truncate -s $(BOOT_IMG_SIZE_MB)M $@
	sudo /sbin/mkfs.ext4 -L boot -d rootfs/boot $@
CLEAN += boot.img

rootfs.img: rootfs/.stamp
	truncate -s $$(($(ROOT_IMG_SIZE_MB) - $(F2FS_SEGMENT_SIZE_MB)))M $@
	/sbin/mkfs.f2fs -l root $@
	export MOUNTDIR=$$(mktemp -t -d) \
		&& sudo mount -o loop $@ $$MOUNTDIR \
		&& sudo tar cC rootfs --exclude=.stamp --exclude='boot/*' . | sudo tar xC $$MOUNTDIR \
		&& sudo umount $$MOUNTDIR \
		&& rmdir $$MOUNTDIR
CLEAN += rootfs.img

rootfs/.stamp: MIRROR ?= http://deb.debian.org/debian
rootfs/.stamp: RELEASE ?= $(shell . /etc/os-release && echo $$VERSION_CODENAME)
rootfs/.stamp: CACHE ?= $(CURDIR)/cache
rootfs/.stamp: packages | umount
	@mkdir -p "$(@D)"
	@findmnt -n -o options --target $(@D) | grep -q -v nodev || { \
		echo '$(@D)' needs to be on a non-nodev mountpoint >&2; \
		exit 1; \
	}
	@sudo find "$(@D)" -mindepth 1 -delete
	@mkdir -p "$(CACHE)"
	sudo debootstrap \
		--arch arm64 \
		--cache-dir="$(CACHE)" \
		--foreign \
		--include=$(shell cat $< | tr '\n' , | sed -e 's/\s\+//g; s/,$$//') \
		--variant=minbase \
		$(RELEASE) $(@D) $(MIRROR)
	sudo chroot $(@D) /debootstrap/debootstrap --second-stage
	sudo chroot $(@D) apt-get clean
	sudo find $(@D)/var/lib/apt/lists -type f -delete
	printf "/dev/mmcblk0p1 / f2fs defaults,rw 0 1\n/dev/mmcblk0p2 /boot ext4 defaults,rw,discard 0 2\n" \
		| sudo chroot $(@D) tee /etc/fstab >/dev/null
	cat modules | sudo chroot $(@D) tee -a /etc/initramfs-tools/modules >/dev/null
	export VERSION=$$(sudo chroot $(@D) dpkg-query -W -f '$${Depends}' linux-image-arm64 | sed -e 's/linux-image-\([^ ]\+\).*/\1/') \
		&& sudo chroot $(@D) ln -s vmlinuz-$$VERSION /boot/vmlinuz \
		&& sudo chroot $(@D) ln -s initrd.img-$$VERSION /boot/initrd.img \
		&& sudo chroot $(@D) mkdir /boot/marvell \
		&& sudo chroot $(@D) ln /usr/lib/linux-image-$$VERSION/marvell/armada-8040-clearfog-gt-8k.dtb /boot/marvell
	echo clearfog | sudo chroot $(@D) tee /etc/hostname >/dev/null
	sudo chroot $(@D) passwd -d root
	sudo chroot $(@D) systemctl enable serial-getty@ttyS0
	sudo chroot $(@D) systemctl enable systemd-networkd
	sudo chroot $(@D) systemctl enable systemd-resolved
	sudo sed -ie 's/^#\(watchdog-device\)/\1/' $(@D)/etc/watchdog.conf
	@sudo touch $@
CLEAN += rootfs
DISTCLEAN += cache

.PHONY: umount
umount:
	@findmnt -n -R -o target -l --target rootfs | sed 1d | tac | xargs -r -n1 sudo umount || true

.PHONY: clean
clean: umount
	test ! -f atf-marvell/.stamp || make -C atf-marvell -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- PLAT=a80x0_mcbin MV_DDR_PATH='$(CURDIR)/mv-ddr-marvell' SCP_BL2=/dev/null clean
	test ! -f u-boot/.stamp || make -C u-boot clean
ifneq ($(CLEAN),)
	sudo rm -rf $(CLEAN)
endif

.PHONY: distclean
distclean: clean
ifneq ($(DISTCLEAN),)
	rm -rf $(DISTCLEAN)
endif
