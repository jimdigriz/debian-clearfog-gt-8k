SHELL = /bin/sh
.DELETE_ON_ERROR:

CLEAN =
DISTCLEAN =

DEBOOTSTRAP ?= /usr/sbin/debootstrap
ROOTFS ?= $(CURDIR)/rootfs

UBOOT ?= $(CURDIR)/u-boot

MARVELL_ATF ?= $(CURDIR)/atf-marvell
MARVELL_DDR ?= $(CURDIR)/mv-ddr-marvell
MARVELL_BINARIES ?= $(CURDIR)/binaries-marvell

JOBS ?= $(shell echo $$(($$(getconf _NPROCESSORS_ONLN) + 1))) 

.PHONY: all
all: rootfs.bin flash-image.bin

flash-image.bin: $(UBOOT)/u-boot.bin

$(UBOOT)/.stamp: UBOOT_GIT ?= https://gitlab.denx.de/u-boot/u-boot.git
$(UBOOT)/.stamp:
	git clone $(UBOOT_GIT) '$(UBOOT)'
	git -C '$(UBOOT)' checkout $$(git -C '$(UBOOT)' tag | sed -n -e '/^v/ { /-rc/! p }' | sort | tail -n1)
	@touch $@
DISTCLEAN += $(UBOOT)
	
$(UBOOT)/u-boot.bin: $(UBOOT)/.stamp
	make -C '$(UBOOT)' -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- clearfog_gt_8k_defconfig tools
	make -C '$(UBOOT)' -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu-

$(MARVELL_ATF)/.stamp: MARVELL_ATF_GIT ?= https://github.com/MarvellEmbeddedProcessors/atf-marvell.git
$(MARVELL_ATF)/.stamp: MARVELL_ATF_REF ?= atf-v1.5-armada-18.12
$(MARVELL_ATF)/.stamp:
	git clone --single-branch --no-tags -b $(MARVELL_ATF_REF) $(MARVELL_ATF_GIT) '$(MARVELL_ATF)'
	git -C '$(MARVELL_ATF)' grep -l '\-Werror' | sed -e 's/^/$(MARVELL_ATF)/' | xargs -r sed -i -e 's/-Werror//g'
	@touch $@
DISTCLEAN += $(MARVELL_ATF)

$(MARVELL_DDR)/.stamp: MARVELL_DDR_GIT ?= https://github.com/MarvellEmbeddedProcessors/mv-ddr-marvell.git
$(MARVELL_DDR)/.stamp: MARVELL_DDR_REF ?= mv_ddr-armada-18.12
$(MARVELL_DDR)/.stamp:
	git clone --single-branch --no-tags -b $(MARVELL_DDR_REF) $(MARVELL_DDR_GIT) '$(MARVELL_DDR)'
	@touch $@
DISTCLEAN += $(MARVELL_DDR)

$(MARVELL_BINARIES)/.stamp: MARVELL_BINARIES_GIT ?= https://github.com/MarvellEmbeddedProcessors/binaries-marvell.git
$(MARVELL_BINARIES)/.stamp: MARVELL_BINARIES_REF ?= binaries-marvell-armada-18.12
$(MARVELL_BINARIES)/.stamp:
	git clone --single-branch --no-tags -b $(MARVELL_BINARIES_REF) $(MARVELL_BINARIES_GIT) '$(MARVELL_BINARIES)'
	@touch $@
DISTCLEAN += $(MARVELL_BINARIES)

$(MARVELL_ATF)/build/a80x0_mcbin/release/flash-image.bin: $(MARVELL_ATF)/.stamp $(MARVELL_DDR)/.stamp $(MARVELL_BINARIES)/.stamp $(UBOOT)/u-boot.bin 
$(MARVELL_ATF)/build/a80x0_mcbin/release/flash-image.bin:
	make -C '$(MARVELL_ATF)' -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- PLAT=a80x0_mcbin MV_DDR_PATH='$(MARVELL_DDR)' SCP_BL2='$(MARVELL_BINARIES)/mrvl_scp_bl2.img' BL33='$(UBOOT)/u-boot.bin' all fip

flash-image.bin: $(MARVELL_ATF)/build/a80x0_mcbin/release/flash-image.bin
	ln -f $< $@

rootfs.bin: $(ROOTFS)/.stamp

$(ROOTFS)/.stamp: MIRROR ?= http://deb.debian.org/debian
$(ROOTFS)/.stamp: RELEASE ?= $(shell . /etc/os-release && echo $$VERSION_CODENAME)
$(ROOTFS)/.stamp: CACHE ?= $(CURDIR)/cache
$(ROOTFS)/.stamp: packages | umount
ifneq ($(filter nodev,$(shell findmnt -n -o options --target . | tr , ' ')),)
	@echo $(ROOTFS) needs to be on a non-nodev mountpoint
	@exit 1
endif
	@rm -rf "$(@D)"
	@mkdir -p "$(CACHE)"
	$(DEBOOTSTRAP) \
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

.PHONY: umount
umount:
	findmnt -n -R -o target -l --target $(ROOTFS) | sed 1d | tac | xargs -r -n1 umount || true

.PHONY: clean
clean: umount
	make -C '$(MARVELL_ATF)' -j$(JOBS) CROSS_COMPILE=aarch64-linux-gnu- PLAT=a80x0_mcbin MV_DDR_PATH='$(MARVELL_DDR)' SCP_BL2=/dev/null clean
	make -C '$(UBOOT)' clean
ifneq ($(CLEAN),)
	rm -rf $(CLEAN)
endif

.PHONY: distclean
distclean: clean
ifneq ($(DISTCLEAN),)
	rm -rf $(DISTCLEAN)
endif
