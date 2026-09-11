# vivadocontainment -- put an existing Vivado install inside an immutable
# QEMU VM backed by a compressed, read-only filesystem.
#
#   make check      -- report missing host tools
#   make rootfs     -- build the Debian guest system image (small)
#   make vivado     -- squash the Vivado install (big, slow, do this once)
#   make all        -- both, plus kernel + initrd
#   make run        -- boot it
#   make ssh        -- ssh into a running VM
#
# Override anything below in config.mk (see config.mk.example).

-include config.mk

# ---------------------------------------------------------------- inputs ---

# Where Vivado is installed on this host. This whole tree gets squashed.
VIVADO_DIR      ?= /tools/Xilinx
# Where it is mounted inside the guest. Keep it identical to VIVADO_DIR
# unless you know your install is relocatable.
VIVADO_MNT      ?= $(VIVADO_DIR)
# Exact paths inside VIVADO_DIR to leave out, relative to VIVADO_DIR.
# e.g. VIVADO_EXCLUDES = Vitis Model_Composer
VIVADO_EXCLUDES ?=

# Extended regexes matched against every path in the tree. This is where the
# bulk of the savings are, because the layout differs between installs and
# versions. The default drops what a headless batch worker cannot use; run
# "make sizes" to see what each pattern is worth on your install, and set
# this in config.mk to override the lot. Patterns may not contain spaces,
# and a $ must be written $$.
# Nothing here is reachable over the protocol: it can invoke vivado, xvlog,
# xelab and xsim, and nothing else. Note the [^.] on Vitis: the bulk goes,
# but Vivado's settings64.sh sources its siblings' .settings64-*.sh
# fragments, and those are a few KB each. An IDE's language server, an Electron
# app and a RISC-V toolchain cannot be called and are not loaded by the
# tools that can. Simulation data and device families are NOT dropped -- see
# config.mk.example for those, which need a decision rather than a default.
# No doc/ or docs/ pattern here on purpose. Xilinx keep functional files in
# directories with those names: mig_7series/data/docs/mig.xml is the wizard's
# device database, and every IP in the catalogue lists a changelog under doc/
# as a generation deliverable, which Vivado treats a missing one as fatal.
# Stripping them broke all 604 IPs for about 800 MB in 21 GB.
VIVADO_EXCLUDE_RE ?= \
	[Dd]oc[Nn]av \
	(^|/)simmodels/ \
	cable_drivers \
	(^|/)\.xinstall \
	(^|/)uninstall \
	(^|/)Vitis/[^.] \
	(^|/)gnu/ \
	(^|/)clangd-

# Public key that may ssh in as root.
SSH_PUBKEY      ?= $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_rsa.pub))

# Node-locked license to bake into the image. Node-locked licenses are tied to
# a NIC address, so the VM is given the same MAC (see MAC below).
LICENSE_FILE    ?= $(firstword $(wildcard $(HOME)/.Xilinx/Xilinx.lic \
                     $(VIVADO_DIR)/Xilinx.lic $(VIVADO_DIR)/.Xilinx/Xilinx.lic))
# Or a floating license server, e.g. 2100@licserver.example.com. Takes
# precedence over LICENSE_FILE for XILINXD_LICENSE_FILE.
XILINXD_LICENSE_FILE ?=
GUEST_LICENSE   := /etc/vivadocontainment/Xilinx.lic
LICENSE_SPEC     = $(if $(XILINXD_LICENSE_FILE),$(XILINXD_LICENSE_FILE),$(if $(LICENSE_FILE),$(GUEST_LICENSE)))

# MAC address for the guest NIC. Empty means "read it out of LICENSE_FILE",
# which is what makes a node-locked license valid inside the VM. Override if
# your license is tied to a different interface than the one it names first.
MAC             ?=
GUEST_MAC        = $(if $(MAC),$(MAC),$(shell cat $(BUILD)/mac 2>/dev/null))

# --------------------------------------------------------------- mqtt job ---

# Where agents queue jobs. Empty disables the job runner entirely (ssh still
# works). See README for the message format.
MQTT_BROKER     ?=
MQTT_PORT       ?= 1883
MQTT_TOPIC      ?= vivado
MQTT_USER       ?=
MQTT_PASS       ?=
# Identifies this worker in topics and its client id; several VMs can share
# a broker as long as this differs.
MQTT_WORKER     ?= vivado1
# Where projects live in the guest. Keep this on the scratch disk (make
# scratch) or they die with the VM, since everything else is a tmpfs overlay.
MQTT_ROOT       ?= /scratch/projects
# The guest reaches the broker at this address whatever its real one is; qemu
# maps it. Fixed, so changing brokers is a restart rather than an image
# rebuild.
GUEST_BROKER    ?= 10.0.2.100
# Empty this to give the guest the run of the network again. On, it can reach
# exactly one thing -- the broker, on one port -- and nothing can reach it but
# the forwarded ssh port. qemu enforces it, so a job that somehow got root in
# the guest still could not talk to your LAN.
NET_RESTRICT    ?= 1

# ------------------------------------------------------------ guest build ---

# trixie rather than bookworm: Vivado 2026.x is built against a much newer
# glibc than bookworm's 2.36, and its erofs-utils is the first in Debian that
# can compress with zstd.
SUITE           ?= trixie
MIRROR          ?= http://deb.debian.org/debian
COMPONENTS      ?= main
ARCH            ?= amd64

# Kept deliberately short; add your own with EXTRA_PACKAGES in config.mk.
PACKAGES        ?= linux-image-$(ARCH) initramfs-tools systemd-sysv udev \
                   openssh-server ca-certificates iproute2 iputils-ping \
                   e2fsprogs rsync curl unzip xz-utils file less procps \
                   psmisc python3 make xauth busybox \
                   gcc g++ \
                   libtinfo6 libncurses6 libx11-6 libxext6 libxrender1 \
                   libxtst6 libxi6 libxft2 libfontconfig1 libfreetype6 \
                   libglib2.0-0 libsm6 libice6 libstdc++6 zlib1g \
                   libpixman-1-0 \
                   fontconfig fonts-dejavu-core locales \
                   python3-paho-mqtt
EXTRA_PACKAGES  ?=

# ---------------------------------------------------------------- images ---

BUILD           ?= build
# Compression for the Vivado image, in mkfs.erofs's own -z syntax:
#   zstd,19   smallest, and hours to build on a full install
#   lz4       fastest to build and to read, appreciably bigger
#   lz4hc,9   in between; same fast decompression, slower to build
# lz4 is the original EROFS algorithm and needs nothing recent in the guest.
# Changing this does not rebuild the image on its own: rm it, or make -B.
VIVADO_COMP     ?= zstd,19
# The rootfs is squashfs and small enough that this rarely matters.
ROOTFS_COMP     ?= zstd
ROOTFS_COMP_LEVEL ?= 19
# EROFS compresses in clusters rather than whole blocks. Bigger clusters
# compress better and cost more per random read; 64K is a middle setting.
PCLUSTER        ?= 65536
JOBS            ?= $(shell nproc)

ROOTFS_TAR      := $(BUILD)/rootfs.tar
ROOTFS_IMG      := $(BUILD)/rootfs.squashfs
VIVADO_IMG      := $(BUILD)/vivado.erofs
KERNEL          := $(BUILD)/vmlinuz
INITRD          := $(BUILD)/initrd.img
GUEST           := $(BUILD)/guest

# ------------------------------------------------------------------- run ---

MEM             ?= 16G
SMP             ?= 8
SSH_PORT        ?= 2222
SSH_HOST        ?= 127.0.0.1
# Persistent disk, formatted ext4 on first boot, mounted at /scratch. This is
# where projects live, so you want one.
SCRATCH_IMG     ?= $(BUILD)/scratch.qcow2
SCRATCH_SIZE    ?= 64G
# Swap for the guest. Raw and fully allocated on purpose: it takes its space
# once, at creation, and can never grow past it -- and swapping into a sparse
# file on a host that later fills up means I/O errors in the middle of a
# build, which is worse than having no swap at all.
SWAP_IMG        ?= $(BUILD)/swap.img
SWAP_SIZE       ?= 16G
# Size of the tmpfs holding all writes to the root filesystem.
OVERLAY_SIZE    ?= 50%
PIDFILE         ?= $(BUILD)/qemu.pid

QEMU            ?= qemu-system-x86_64
ACCEL           := $(shell test -w /dev/kvm && echo kvm || echo tcg)
ifeq ($(ACCEL),kvm)
CPU             ?= host
else
CPU             ?= max
endif

# PANIC= (empty) halts on panic instead of rebooting, which is what you want
# the first time; BREAK=mount drops to the initramfs shell before mountroot.
PANIC           ?= 10
BREAK           ?=
CMDLINE_EXTRA   ?=
# ttyS0 LAST: the kernel broadcasts printk to every console= it is given,
# but /dev/console -- where the initramfs, panics and systemd write -- is the
# last one named. With tty0 last, everything userspace says disappears into a
# screen that -display none never shows.
CMDLINE = root=/dev/vda boot=vivado overlay_size=$(OVERLAY_SIZE) \
          console=tty0 console=ttyS0,115200 net.ifnames=0 \
          $(if $(PANIC),panic=$(PANIC)) $(if $(BREAK),break=$(BREAK)) \
          $(CMDLINE_EXTRA)

comma := ,
space := $(subst ,, )

# serial= gives each a stable /dev/disk/by-id name, so the guest does not
# have to guess whether it is vdc or vdd today. It has to go on the device
# rather than the drive: -drive serial= was deprecated in qemu 2.10 and is
# gone, and the error it gives ("format 'qcow2' does not support the option
# 'serial'") points at the format rather than the spelling.
# Every disk is attached the same way, in this order, because mixing
# if=virtio with explicit devices reorders them: qemu creates the explicit
# ones first, /dev/vda stopped being the rootfs, and the initramfs tried to
# mount the scratch disk as squashfs.
ROOTFS_ARG  = -drive file=$(ROOTFS_IMG)$(comma)if=none$(comma)id=rootdrv$(comma)format=raw$(comma)readonly=on -device virtio-blk-pci$(comma)drive=rootdrv$(comma)serial=vcroot
VIVADO_ARG  = -drive file=$(VIVADO_IMG)$(comma)if=none$(comma)id=vivadodrv$(comma)format=raw$(comma)readonly=on -device virtio-blk-pci$(comma)drive=vivadodrv$(comma)serial=vcvivado
SCRATCH_ARG = $(if $(wildcard $(SCRATCH_IMG)),-drive file=$(SCRATCH_IMG)$(comma)if=none$(comma)id=scratchdrv$(comma)format=qcow2 -device virtio-blk-pci$(comma)drive=scratchdrv$(comma)serial=vcscratch)
SWAP_ARG    = $(if $(wildcard $(SWAP_IMG)),-drive file=$(SWAP_IMG)$(comma)if=none$(comma)id=swapdrv$(comma)format=raw -device virtio-blk-pci$(comma)drive=swapdrv$(comma)serial=vcswap)
# restrict=on drops everything not named here; hostfwd is the way in and
# guestfwd the way out, and both are explicit rules that survive it.
NET_ARGS = $(if $(NET_RESTRICT),$(comma)restrict=on)$(comma)hostfwd=tcp:$(SSH_HOST):$(SSH_PORT)-:22$(if $(MQTT_BROKER),$(comma)guestfwd=tcp:$(GUEST_BROKER):$(MQTT_PORT)-tcp:$(MQTT_BROKER):$(MQTT_PORT))
MAC_ARG     = $(if $(GUEST_MAC),$(comma)mac=$(GUEST_MAC))

QEMU_ARGS = \
	-machine q35,accel=$(ACCEL) -cpu $(CPU) -smp $(SMP) -m $(MEM) \
	-kernel $(KERNEL) -initrd $(INITRD) -append "$(CMDLINE)" \
	$(ROOTFS_ARG) $(VIVADO_ARG) $(SCRATCH_ARG) $(SWAP_ARG) \
	-netdev user,id=n0$(NET_ARGS) \
	-device virtio-net-pci,netdev=n0$(MAC_ARG) \
	-device virtio-rng-pci \
	$(QEMU_EXTRA)

# ----------------------------------------------------------------- rules ---

.PHONY: all rootfs vivado run run-bg stop ssh vc watch license-mac sizes deps \
        scratch swap check clean clean-all info

all: rootfs vivado

rootfs: $(ROOTFS_IMG) $(KERNEL) $(INITRD)

vivado: $(VIVADO_IMG)

$(BUILD):
	mkdir -p $@

# --- the Vivado tree ---------------------------------------------------

# Deliberately has no prerequisites: this takes hours, rebuild it by hand
# (make -B vivado, or rm build/vivado.erofs) when the install changes.
$(VIVADO_IMG): | $(BUILD)
	@test -d "$(VIVADO_DIR)" || { echo "VIVADO_DIR=$(VIVADO_DIR) is not a directory"; exit 1; }
	@command -v mkfs.erofs >/dev/null || { echo "need erofs-utils"; exit 1; }
	rm -f $@
	mkfs.erofs -z$(VIVADO_COMP) -C$(PCLUSTER) -T 0 --all-root \
		$(patsubst %,--exclude-path='%',$(VIVADO_EXCLUDES)) \
		$(patsubst %,--exclude-regex='%',$(VIVADO_EXCLUDE_RE)) \
		$@ "$(VIVADO_DIR)"

# --- the guest system --------------------------------------------------

# Files copied into the guest, with build-time substitutions applied.
GUEST_SRC := $(shell find guest -type f 2>/dev/null)

$(GUEST): $(GUEST_SRC) Makefile $(wildcard config.mk) $(LICENSE_FILE) | $(BUILD)
	rm -rf $@ $@.tmp
	cp -a guest $@.tmp
	sed -i 's|@VIVADO_MNT@|$(VIVADO_MNT)|g; s|@LICENSE@|$(LICENSE_SPEC)|g' \
		$@.tmp/etc/fstab $@.tmp/etc/profile.d/vivado.sh
	@# the guest always dials the mapped address; qemu decides where it lands
	sed -i -e 's|@BROKER@|$(GUEST_BROKER)|' -e 's|@PORT@|$(MQTT_PORT)|' \
		-e 's|@TOPIC@|$(MQTT_TOPIC)|' -e 's|@WORKER@|$(MQTT_WORKER)|' \
		-e 's|@ROOT@|$(MQTT_ROOT)|' -e 's|@LICENSE@|$(LICENSE_SPEC)|' \
		$@.tmp/etc/vivadocontainment/mqtt.conf
	@# credentials are appended with printf, not sed: a password containing
	@# & or | would otherwise be mangled into something that silently fails
	sed -i -e '/^USER=@USER@$$/d' -e '/^PASS=@PASS@$$/d' \
		$@.tmp/etc/vivadocontainment/mqtt.conf
	printf 'USER=%s\nPASS=%s\n' '$(MQTT_USER)' '$(MQTT_PASS)' \
		>> $@.tmp/etc/vivadocontainment/mqtt.conf
	@# it holds broker credentials and every job user can read the image
	chmod 600 $@.tmp/etc/vivadocontainment/mqtt.conf
	@test -n "$(SSH_PUBKEY)" || { echo "SSH_PUBKEY is empty and no key found in ~/.ssh"; exit 1; }
	@test -r "$(SSH_PUBKEY)" || { echo "cannot read SSH_PUBKEY=$(SSH_PUBKEY)"; exit 1; }
	mkdir -p $@.tmp/root/.ssh
	cp "$(SSH_PUBKEY)" $@.tmp/root/.ssh/authorized_keys
	chmod 700 $@.tmp/root/.ssh; chmod 600 $@.tmp/root/.ssh/authorized_keys
	@# A node-locked license only works if the guest NIC matches its HOSTID.
	rm -f $(BUILD)/mac
	@if [ -n "$(LICENSE_FILE)" ]; then \
		mkdir -p $@.tmp/etc/vivadocontainment; \
		cp "$(LICENSE_FILE)" $@.tmp$(GUEST_LICENSE); \
		chmod 644 $@.tmp$(GUEST_LICENSE); \
		mac=$$(scripts/license-mac "$(LICENSE_FILE)"); \
		if [ -n "$$mac" ]; then \
			echo "$$mac" > $(BUILD)/mac; \
			echo "license $(LICENSE_FILE) is node-locked to $$mac, guest NIC will use it"; \
		else \
			echo "license $(LICENSE_FILE) has no node-lock HOSTID, not faking a MAC"; \
		fi; \
	else \
		echo "no LICENSE_FILE found, expecting a license server or one inside $(VIVADO_DIR)"; \
	fi
	mv $@.tmp $@

INCLUDE := $(subst $(space),$(comma),$(strip $(PACKAGES) $(EXTRA_PACKAGES)))

# Stamps that change only when a value the step actually uses changes. Without
# them every edit to config.mk -- including one that only affects the Vivado
# image -- would rerun mmdebstrap, which is minutes and a network round trip.
GUEST_VARS  = $(VIVADO_MNT) $(LICENSE_SPEC) $(GUEST_BROKER) $(MQTT_PORT) \
              $(MQTT_TOPIC) $(MQTT_USER) $(MQTT_PASS) $(MQTT_WORKER) \
              $(MQTT_ROOT) $(SSH_PUBKEY)
ROOTFS_VARS = $(SUITE) $(MIRROR) $(COMPONENTS) $(ARCH) $(INCLUDE) \
              $(VIVADO_MNT) $(MQTT_BROKER)

.PHONY: FORCE
FORCE:

$(BUILD)/guest.vars: FORCE | $(BUILD)
	$(file >$@.tmp,$(GUEST_VARS))
	@cmp -s $@.tmp $@ || mv -f $@.tmp $@
	@rm -f $@.tmp

$(BUILD)/rootfs.vars: FORCE | $(BUILD)
	$(file >$@.tmp,$(ROOTFS_VARS))
	@cmp -s $@.tmp $@ || mv -f $@.tmp $@
	@rm -f $@.tmp

# The guest tree is regenerated whenever anything it is built from changes,
# which is cheap. The tar is not: it depends on the same inputs directly, and
# on the tree only in order-only form, so a rebuilt-but-identical tree does
# not cost a debootstrap.
$(ROOTFS_TAR): $(GUEST_SRC) $(BUILD)/guest.vars $(BUILD)/rootfs.vars \
               $(LICENSE_FILE) $(SSH_PUBKEY) | $(GUEST)
	@command -v mmdebstrap >/dev/null || { echo "need mmdebstrap"; exit 1; }
	rm -f $@
	mmdebstrap --mode=unshare --variant=important --arch=$(ARCH) \
		--components=$(COMPONENTS) --include=$(INCLUDE) \
		--customize-hook='sync-in $(GUEST) /' \
		--customize-hook='chroot "$$1" mkdir -p "$(VIVADO_MNT)" /scratch' \
		--customize-hook='chroot "$$1" /usr/local/sbin/vc-fixups' \
		--customize-hook='chroot "$$1" systemctl enable ssh systemd-networkd vc-scratch.service vc-swap.service $(if $(MQTT_BROKER),vc-projd.service)' \
		--customize-hook='chroot "$$1" update-initramfs -u -k all' \
		$(SUITE) $@ $(MIRROR)

$(ROOTFS_IMG): $(ROOTFS_TAR)
	@command -v sqfstar >/dev/null || { echo "need squashfs-tools >= 4.5 (sqfstar)"; exit 1; }
	rm -f $@
	sqfstar -comp $(ROOTFS_COMP) -Xcompression-level $(ROOTFS_COMP_LEVEL) -no-xattrs \
		-processors $(JOBS) $@ < $<

$(KERNEL): $(ROOTFS_TAR)
	rm -rf $(BUILD)/boot
	tar -xf $< -C $(BUILD) --wildcards './boot/vmlinuz-*' './boot/initrd.img-*'
	@# version sort: 6.10 is newer than 6.9, lexical order disagrees
	cp $$(ls -1 $(BUILD)/boot/vmlinuz-* | sort -V | tail -1) $(KERNEL)
	cp $$(ls -1 $(BUILD)/boot/initrd.img-* | sort -V | tail -1) $(INITRD)

# Both come out of one extraction, so if only this one is missing, redo it.
$(INITRD): $(KERNEL)
	@test -f $@ || { rm -f $<; $(MAKE) --no-print-directory $<; }

# --- running -----------------------------------------------------------

# 16G of swap costs 16G of host disk the moment you make it, and nothing
# after that.
swap: | $(BUILD)
	@test ! -f $(SWAP_IMG) || { echo "$(SWAP_IMG) exists; delete it by hand if you mean to resize it"; exit 1; }
	@# preallocation=falloc for the same reason fallocate is tried first:
	@# the space is taken now, not discovered missing mid-build.
	fallocate -l $(SWAP_SIZE) $(SWAP_IMG) 2>/dev/null \
		|| qemu-img create -f raw -o preallocation=falloc $(SWAP_IMG) $(SWAP_SIZE)
	@ls -lh $(SWAP_IMG) | awk '{print "  " $$5 " allocated at " $$9}'

scratch: | $(BUILD)
	@test ! -f $(SCRATCH_IMG) || { echo "$(SCRATCH_IMG) exists -- it holds every project; delete it by hand if you really mean to"; exit 1; }
	qemu-img create -f qcow2 $(SCRATCH_IMG) $(SCRATCH_SIZE)

# qemu's own message for a taken port does not say what has it.
PORT_CHECK = @command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ':$(SSH_PORT) ' && { \
	echo "port $(SSH_PORT) is already in use -- another VM still running?"; \
	echo "  make stop            if it was make run-bg"; \
	echo "  make run SSH_PORT=2223   to use another port"; \
	ss -ltnp 2>/dev/null | grep ':$(SSH_PORT) ' || true; exit 1; } || true

run:
	@test -f $(ROOTFS_IMG) || { echo "no $(ROOTFS_IMG), run: make rootfs"; exit 1; }
	@test -f $(VIVADO_IMG) || { echo "no $(VIVADO_IMG), run: make vivado"; exit 1; }
	$(PORT_CHECK)
	$(QEMU) $(QEMU_ARGS) -nographic -serial mon:stdio -display none

run-bg:
	$(PORT_CHECK)
	$(QEMU) $(QEMU_ARGS) -display none -daemonize -pidfile $(PIDFILE) \
		-serial file:$(BUILD)/console.log
	@echo "started, console log in $(BUILD)/console.log, ssh on port $(SSH_PORT)"

stop:
	@test -f $(PIDFILE) && kill $$(cat $(PIDFILE)) && rm -f $(PIDFILE) && echo stopped || echo "not running"

SSH_OPTS = -p $(SSH_PORT) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR
ssh:
	ssh $(SSH_OPTS) root@$(SSH_HOST)

# Everything the agents do, from the host:
#   make vc ARGS="-p demo create"
#   make vc ARGS="-p demo put build.tcl"
#   make vc ARGS="-p demo vivado build.tcl"
vc:
	@test -n "$(ARGS)" || { echo 'usage: make vc ARGS="-p PROJECT op ..."'; exit 1; }
	scripts/vc --broker $(if $(MQTT_BROKER),$(MQTT_BROKER),localhost) \
		--port $(MQTT_PORT) --topic $(MQTT_TOPIC) \
		$(if $(MQTT_USER),--user $(MQTT_USER) --password $(MQTT_PASS)) $(ARGS)

# Watch what the agents and the worker are saying:
#   make watch                  -- everything on the base topic
#   make watch PROJECT=demo     -- just one project
# MQTT_PASS lands in the process list; put "-P secret" in
# ~/.config/mosquitto_sub instead if that matters here.
WATCH_TOPIC = $(MQTT_TOPIC)/$(if $(PROJECT),project/$(PROJECT)/,)\#
watch:
	@command -v mosquitto_sub >/dev/null || { echo "need mosquitto-clients"; exit 1; }
	mosquitto_sub -h $(if $(MQTT_BROKER),$(MQTT_BROKER),localhost) -p $(MQTT_PORT) \
		$(if $(MQTT_USER),-u $(MQTT_USER) -P $(MQTT_PASS)) \
		-F '%I %t %p' -t '$(WATCH_TOPIC)'

license-mac:
	@echo "license  $(if $(LICENSE_FILE),$(LICENSE_FILE),<none found>)"
	@echo "hostid   $(if $(LICENSE_FILE),$(shell scripts/license-mac $(LICENSE_FILE)),)"
	@echo "guest    $(if $(GUEST_MAC),$(GUEST_MAC),<qemu default>)"

# --- housekeeping ------------------------------------------------------

check:
	@ok=0; for t in mmdebstrap mkfs.erofs mksquashfs sqfstar $(QEMU) qemu-img; do \
		if command -v $$t >/dev/null; then echo "ok      $$t"; \
		else echo "MISSING $$t"; ok=1; fi; done; \
	test -w /dev/kvm && echo "ok      /dev/kvm" || echo "note    no /dev/kvm, will run under tcg (very slow)"; \
	test -d "$(VIVADO_DIR)" && echo "ok      VIVADO_DIR=$(VIVADO_DIR)" || echo "MISSING VIVADO_DIR=$(VIVADO_DIR)"; \
	test -n "$(SSH_PUBKEY)" && echo "ok      SSH_PUBKEY=$(SSH_PUBKEY)" || echo "MISSING SSH_PUBKEY"; \
	test $$ok -eq 0 || { echo; echo "Debian/Ubuntu: apt install mmdebstrap erofs-utils squashfs-tools qemu-system-x86 qemu-utils uidmap"; exit 1; }

# Shared libraries Vivado needs that the guest image does not have. Vivado
# loads some of these lazily, so a missing one shows up as an abort in the
# middle of a build rather than at startup; this finds the lot in one pass.
deps:
	@test -f $(ROOTFS_TAR) || { echo "run make rootfs first"; exit 1; }
	@test -d "$(VIVADO_DIR)" || { echo "VIVADO_DIR=$(VIVADO_DIR) is not a directory"; exit 1; }
	@command -v readelf >/dev/null || { echo "need binutils"; exit 1; }
	@echo "reading the guest's libraries..."
	@tar -tf $(ROOTFS_TAR) | sed -n 's|.*/\(lib[^/]*\.so[^/]*\)$$|\1|p' \
		| sort -u > $(BUILD)/have.sonames
	@echo "reading what Vivado asks for..."
	@find "$(VIVADO_DIR)" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null \
		| xargs -0 -r readelf -d 2>/dev/null \
		| sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | sort -u > $(BUILD)/need.sonames
	@find "$(VIVADO_DIR)" -type f \( -name '*.so' -o -name '*.so.*' \) -printf '%f\n' 2>/dev/null \
		| sort -u >> $(BUILD)/have.sonames
	@sort -u $(BUILD)/have.sonames -o $(BUILD)/have.sonames
	@echo
	@echo "needed by Vivado, provided by neither the guest nor Vivado itself:"
	@comm -23 $(BUILD)/need.sonames $(BUILD)/have.sonames | sed 's/^/  /'
	@echo
	@echo "map those to packages with: apt-file search <soname>"

# What is in there, and what the filter is worth. Walks the whole tree, so
# it takes a while on a real install.
sizes:
	@test -d "$(VIVADO_DIR)" || { echo "VIVADO_DIR=$(VIVADO_DIR) is not a directory"; exit 1; }
	@echo "biggest directories:"
	@du -h --max-depth=3 "$(VIVADO_DIR)" 2>/dev/null | sort -rh | head -25
	@echo
	@echo "what each exclude pattern would drop:"
	@all=""; for re in $(patsubst %,'%',$(VIVADO_EXCLUDE_RE)); do \
		sz=$$(find "$(VIVADO_DIR)" -regextype posix-extended -regex ".*$$re.*" \
			-type f -printf '%s\n' 2>/dev/null | awk '{s+=$$1} END {print s+0}'); \
		printf '  %10s  %s\n' "$$(numfmt --to=iec $$sz 2>/dev/null || echo $$sz)" "$$re"; \
		all="$${all:+$$all|}($$re)"; \
	done; \
	tot=$$(find "$(VIVADO_DIR)" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$$1} END {print s+0}'); \
	drop=$$(find "$(VIVADO_DIR)" -regextype posix-extended -regex ".*($$all).*" \
		-type f -printf '%s\n' 2>/dev/null | awk '{s+=$$1} END {print s+0}'); \
	printf '\n  %10s in the install\n  %10s dropped by the filter\n  %10s goes into the image, before compression\n' \
		"$$(numfmt --to=iec $$tot)" "$$(numfmt --to=iec $$drop)" \
		"$$(numfmt --to=iec $$((tot - drop)))"

info:
	@echo "vivado dir   $(VIVADO_DIR)  ($$(du -sh $(VIVADO_DIR) 2>/dev/null | cut -f1))"
	@echo "guest mount  $(VIVADO_MNT)"
	@ls -lh $(BUILD)/*.squashfs $(KERNEL) $(INITRD) 2>/dev/null || true

clean:
	rm -rf $(BUILD)/guest $(BUILD)/boot $(ROOTFS_TAR) $(ROOTFS_IMG) $(KERNEL) $(INITRD)

# Also drops the (very expensive) Vivado image.
clean-all:
	rm -rf $(BUILD)
