SHELL = /bin/sh
.DELETE_ON_ERROR:

CLEAN =
DISTCLEAN =

GIT_TRIM ?= --single-branch --no-tags --depth 1

JOBS ?= $(shell echo $$(($$(getconf _NPROCESSORS_ONLN) + 1)))

.PHONY: all
all: gpt.img boot.img rootfs.img

u-boot/.stamp: UBOOT_GIT ?= https://gitlab.denx.de/u-boot/u-boot.git
u-boot/.stamp:
ifneq ($(UBOOT_REF),)
	git clone $(GIT_TRIM) -b $(UBOOT_REF) $(UBOOT_GIT) $(@D)
else
	git clone $(UBOOT_GIT) $(@D)
	git -C $(@D) checkout $$(git -C $(@D) tag | sed -n -e '/^v/ { /-rc/! p }' | sort | tail -n1)
endif
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
	git -C $(@D) grep -l '\-Werror' | sed -e 's/^/atf-marvell/' | xargs -r sed -i -e 's/-Werror//g'
	@touch $@
DISTCLEAN += atf-marvell

mv-ddr-marvell/.stamp: MARVELL_DDR_GIT ?= https://github.com/MarvellEmbeddedProcessors/mv-ddr-marvell.git
mv-ddr-marvell/.stamp: MARVELL_DDR_REF ?= mv_ddr-armada-18.12
mv-ddr-marvell/.stamp:
	git clone $(GIT_TRIM) -b $(MARVELL_DDR_REF) $(MARVELL_DDR_GIT) $(@D)
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
	make -C atf-marvell -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- USE_COHERENT_MEM=0 LOG_LEVEL=20 PLAT=a80x0_mcbin MV_DDR_PATH='$(CURDIR)/mv-ddr-marvell' SCP_BL2='$(CURDIR)/binaries-marvell/mrvl_scp_bl2.img' BL33='$(CURDIR)/u-boot/u-boot.bin' all fip

flash-image.bin: atf-marvell/build/a80x0_mcbin/release/flash-image.bin
	ln -f $< $@

boot.img: SIZE = $(shell echo $$(($(shell du -smx --apparent-size rootfs/boot | cut -f1) * 10)))
boot.img: .stamp.rootfs
	sudo /usr/sbin/mkfs.ext4 -d
CLEAN ?= boot.img

# partition table lives in here
F2FS_SEGMENT_SIZE_MB = 2

# uboot> mmc info
# User Capacity
EMMC_SIZE_MB ?= 7475

# supports roughly four pairs of kernel/initramfs
BOOT_IMG_SIZE_MB ?= 250
ROOT_IMG_SIZE_MB ?= $(shell echo $$(($(EMMC_SIZE_MB) - $(BOOT_IMG_SIZE_MB) - $(F2FS_SEGMENT_SIZE_MB) - 1)))

mmc-image.bin: gpt.img boot.img rootfs.img
	cp --sparse=always $< $@
	dd bs=1M conv=notrunc seek=$(F2FS_SEGMENT_SIZE_MB) if=boot.img of=$@
	dd bs=1M conv=notrunc seek=$$(($(F2FS_SEGMENT_SIZE_MB) + $(BOOT_IMG_SIZE_MB))) if=rootfs.img of=$@

gpt.img: boot.img
	truncate -s $(EMMC_SIZE_MB)M $@
	printf 'label: gpt\nstart=2048,size=2048,name=gpt\nsize=%d,name=boot,bootable\nsize=%d,name=root\n' \
			$$(($(BOOT_IMG_SIZE_MB) * 1024 * 1024 / 512)) \
			$$(($(ROOT_IMG_SIZE_MB) * 1024 * 1024 / 512)) \
		| /sbin/sfdisk --no-reread --no-tell-kernel $@

boot.img: .stamp.rootfs
	sudo /sbin/mkfs.ext4 -L boot -d rootfs/boot $@ $(BOOT_IMG_SIZE_MB)M

rootfs.img: .stamp.rootfs
	truncate -s $$(($(ROOT_IMG_SIZE_MB) - $(F2FS_SEGMENT_SIZE_MB)))M $@
	/sbin/mkfs.f2fs -l root $@
	export MOUNTDIR=$$(mktemp -t -d) \
		&& sudo mount -o loop $@ $$MOUNTDIR \
		&& sudo tar cC rootfs --exclude='boot/*' . | sudo tar xC $$MOUNTDIR \
		&& sudo umount $$MOUNTDIR \
		&& rmdir $$MOUNTDIR

CLEAN ?= rootfs.img

.stamp.rootfs: MIRROR ?= http://deb.debian.org/debian
.stamp.rootfs: RELEASE ?= $(shell . /etc/os-release && echo $$VERSION_CODENAME)
.stamp.rootfs: CACHE ?= $(CURDIR)/cache
.stamp.rootfs: packages | umount
ifneq ($(filter nodev,$(shell findmnt -n -o options --target rootfs | tr , ' ')),)
	@echo rootfs needs to be on a non-nodev mountpoint
	@exit 1
endif
	@rm -rf "rootfs"
	@mkdir -p "$(CACHE)"
	sudo debootstrap \
		--arch arm64 \
		--cache-dir="$(CACHE)" \
		--foreign \
		--include=$(shell cat $< | tr '\n' , | sed -e 's/\s\+//g; s/,$$//') \
		--variant=minbase \
		$(RELEASE) rootfs $(MIRROR)
	chroot rootfs /debootstrap/debootstrap --second-stage
	echo deb $(MIRROR) $(RELEASE)-backports main > rootfs/etc/apt/sources.list.d/debian-backports.list
	chroot rootfs apt-get update
	chroot rootfs apt-get -y --option=Dpkg::options::=--force-unsafe-io install --no-install-recommends \
		linux-image-arm64/$(RELEASE)-backports
	chroot rootfs apt-get clean
	find rootfs/var/lib/apt/lists -type f -delete
	@touch "$@"
CLEAN += .stamp.rootfs rootfs

.PHONY: umount
umount:
	sudo findmnt -n -R -o target -l --target rootfs | sed 1d | tac | xargs -r -n1 umount || true

.PHONY: clean
clean: umount
	make -C atf-marvell -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- PLAT=a80x0_mcbin MV_DDR_PATH='$(CURDIR)/mv-ddr-marvell' SCP_BL2=/dev/null clean
	make -C u-boot clean
ifneq ($(CLEAN),)
	rm -rf $(CLEAN)
endif

.PHONY: distclean
distclean: clean
ifneq ($(DISTCLEAN),)
	rm -rf $(DISTCLEAN)
endif
