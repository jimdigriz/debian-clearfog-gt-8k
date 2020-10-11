SHELL = /bin/sh
.DELETE_ON_ERROR:

CLEAN =
DISTCLEAN =

# from u-boot cmd 'mmc info'
MMC_ERASE ?= $(shell echo $$((512*1024)))
MMC_READ ?= 512

GIT_TRIM ?= --single-branch --no-tags --depth 1

ROOTFS ?= $(CURDIR)/rootfs

MARVELL_ATF ?= $(CURDIR)/atf-marvell
MARVELL_DDR ?= $(CURDIR)/mv-ddr-marvell
MARVELL_BINARIES ?= $(CURDIR)/binaries-marvell

JOBS ?= $(shell echo $$(($$(getconf _NPROCESSORS_ONLN) + 1))) 

.PHONY: all
all: gpt.img boot.img rootfs.img

u-boot/.stamp: UBOOT_GIT ?= https://gitlab.denx.de/u-boot/u-boot.git
u-boot/.stamp:
ifneq ($(UBOOT_REF),)
	git clone $(GIT_TRIM) -b $(UBOOT_REF) $(UBOOT_GIT) $(@D)
else
	git clone $(UBOOT_GIT) '$(@D)'
	git -C $(@D) checkout $$(git -C $(@D) tag | sed -n -e '/^v/ { /-rc/! p }' | sort | tail -n1)
endif
	@touch $@
DISTCLEAN += u-boot

u-boot/u-boot.bin: u-boot/.stamp
	make -C $(@D) -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- clearfog_gt_8k_defconfig
	make -C $(@D) -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- tools
	make -C $(@D) -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu-

$(MARVELL_ATF)/.stamp: MARVELL_ATF_GIT ?= https://github.com/MarvellEmbeddedProcessors/atf-marvell.git
$(MARVELL_ATF)/.stamp: MARVELL_ATF_REF ?= atf-v1.5-armada-18.12
$(MARVELL_ATF)/.stamp:
	git clone $(GIT_TRIM) -b $(MARVELL_ATF_REF) $(MARVELL_ATF_GIT) '$(MARVELL_ATF)'
	git -C '$(MARVELL_ATF)' grep -l '\-Werror' | sed -e 's/^/$(MARVELL_ATF)/' | xargs -r sed -i -e 's/-Werror//g'
	@touch $@
DISTCLEAN += $(MARVELL_ATF)

$(MARVELL_DDR)/.stamp: MARVELL_DDR_GIT ?= https://github.com/MarvellEmbeddedProcessors/mv-ddr-marvell.git
$(MARVELL_DDR)/.stamp: MARVELL_DDR_REF ?= mv_ddr-armada-18.12
$(MARVELL_DDR)/.stamp:
	git clone $(GIT_TRIM) -b $(MARVELL_DDR_REF) $(MARVELL_DDR_GIT) '$(MARVELL_DDR)'
	@touch $@
DISTCLEAN += $(MARVELL_DDR)

$(MARVELL_BINARIES)/.stamp: MARVELL_BINARIES_GIT ?= https://github.com/MarvellEmbeddedProcessors/binaries-marvell.git
$(MARVELL_BINARIES)/.stamp: MARVELL_BINARIES_REF ?= binaries-marvell-armada-18.12
$(MARVELL_BINARIES)/.stamp:
	git clone $(GIT_TRIM) -b $(MARVELL_BINARIES_REF) $(MARVELL_BINARIES_GIT) '$(MARVELL_BINARIES)'
	@touch $@
DISTCLEAN += $(MARVELL_BINARIES)

$(MARVELL_ATF)/build/a80x0_mcbin/release/flash-image.bin: $(MARVELL_ATF)/.stamp $(MARVELL_DDR)/.stamp $(MARVELL_BINARIES)/.stamp u-boot/u-boot.bin 
$(MARVELL_ATF)/build/a80x0_mcbin/release/flash-image.bin:
	make -C '$(MARVELL_ATF)' -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- PLAT=a80x0_mcbin MV_DDR_PATH='$(MARVELL_DDR)' SCP_BL2='$(MARVELL_BINARIES)/mrvl_scp_bl2.img' BL33=$(CURDIR)/u-boot/u-boot.bin all fip

flash-image.bin: $(MARVELL_ATF)/build/a80x0_mcbin/release/flash-image.bin
	ln -f $< $@

boot.img: SIZE = $(shell echo $$(($(shell du -smx --apparent-size $(ROOTFS)/boot | cut -f1) * 10)))
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
ifneq ($(filter nodev,$(shell findmnt -n -o options --target $(dir $(ROOTFS)) | tr , ' ')),)
	@echo $(ROOTFS) needs to be on a non-nodev mountpoint
	@exit 1
endif
	@rm -rf "$(ROOTFS)"
	@mkdir -p "$(CACHE)"
	sudo debootstrap \
		--arch arm64 \
		--cache-dir="$(CACHE)" \
		--foreign \
		--include=$(shell cat $< | tr '\n' , | sed -e 's/\s\+//g; s/,$$//') \
		--variant=minbase \
		$(RELEASE) $(ROOTFS) $(MIRROR)
	chroot $(ROOTFS) /debootstrap/debootstrap --second-stage
	echo deb $(MIRROR) $(RELEASE)-backports main > $(ROOTFS)/etc/apt/sources.list.d/debian-backports.list
	chroot $(ROOTFS) apt-get update
	chroot $(ROOTFS) apt-get -y --option=Dpkg::options::=--force-unsafe-io install --no-install-recommends \
		linux-image-arm64/$(RELEASE)-backports
	chroot $(ROOTFS) apt-get clean
	find $(ROOTFS)/var/lib/apt/lists -type f -delete
	@touch "$@"
CLEAN += .stamp.rootfs rootfs

.PHONY: umount
umount:
	sudo findmnt -n -R -o target -l --target $(ROOTFS) | sed 1d | tac | xargs -r -n1 umount || true

.PHONY: clean
clean: umount
	make -C '$(MARVELL_ATF)' -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- PLAT=a80x0_mcbin MV_DDR_PATH='$(MARVELL_DDR)' SCP_BL2=/dev/null clean
	make -C u-boot clean
ifneq ($(CLEAN),)
	rm -rf $(CLEAN)
endif

.PHONY: distclean
distclean: clean
ifneq ($(DISTCLEAN),)
	rm -rf $(DISTCLEAN)
endif
