# vivadocontainment

Takes an existing Vivado installation and puts it inside an immutable QEMU VM,
so you can run Vivado on a big machine without the install ever being
modified, and without polluting the host.

Nothing is installed: the Vivado tree you already have is squashed as-is.

## Shape of the thing

    build/vivado.erofs      your $VIVADO_DIR, compressed, read-only  -> /dev/vdb
    build/rootfs.squashfs   minimal Debian + Vivado's runtime deps   -> /dev/vda
    build/vmlinuz           Debian kernel, extracted from the rootfs
    build/initrd.img        same, with a custom mountroot()

`VIVADO_COMP` takes mkfs.erofs's `-z` syntax: `zstd,19` for the smallest
image, `lz4` when you would rather not wait hours for one, `lz4hc,9` in
between. lz4 also decompresses faster at runtime, so it is not purely a
build-time trade.

The Vivado image is EROFS rather than squashfs. Squashfs decompresses a whole
block to serve any read inside it, which is a poor match for what Vivado
actually does -- thousands of small files at startup, mmap'd libraries, random
reads into the part database -- while EROFS decompresses per cluster. The
rootfs stays squashfs: it is small, its access pattern is trivial, and
`sqfstar` builds it from mmdebstrap's tar without root on any distro.

At boot the initramfs mounts `/dev/vda` read-only and stacks a tmpfs on top
with overlayfs, so the running system is writable but every change is gone at
poweroff. The Vivado image is mounted at the same path it had on the host
(`VIVADO_MNT`, defaults to `VIVADO_DIR`), which sidesteps the parts of Vivado
that bake absolute paths into scripts.

Writable places inside the guest:

| path       | backing               | survives reboot |
|------------|-----------------------|-----------------|
| `/` `/tmp` | tmpfs (RAM)           | no              |
| `/scratch` | `build/scratch.qcow2` | yes, if created |

Everything written outside `/scratch` is gone at poweroff, so `make scratch`
before first boot if you want to keep anything.

## Using it

On the machine that has Vivado:

    make check                       # what's missing
    cp config.mk.example config.mk   # then edit VIVADO_DIR etc.
    make rootfs                      # minutes
    make vivado                      # hours, and needs ~1x the install size free
    make scratch                     # persistent disk, do this before booting
    make run                         # console on your terminal, ^A x to quit

`make run-bg` daemonizes it and logs the console to `build/console.log`;
`make stop` kills it, and `make ssh` gets you in:

    make ssh
    vc-exec vivado -mode batch -source /scratch/build.tcl

Every `make rootfs` builds a fresh guest, so the ssh host key changes with it
and your known_hosts will object. `make ssh` ignores known_hosts for that
reason; if you connect by hand, clear the old key first:

    ssh-keygen -R '[127.0.0.1]:2222'

Host packages needed (Debian/Ubuntu):

    apt install mmdebstrap erofs-utils squashfs-tools qemu-system-x86 qemu-utils uidmap

No root required for the build: `mmdebstrap --mode=unshare` and `sqfstar` both
work as a normal user.

## Vivado environment

Login shells get it from `/etc/profile.d/vivado.sh`. Non-login shells (the
usual `ssh host cmd` case, which is what agents do) will not, so there are two
wrappers:

    vc-exec CMD ...   # run CMD with settings64.sh sourced
    vivado ...        # same, for Vivado itself

## What the guest can reach

By default the VM is on a leash that qemu holds, not the guest:

    -netdev user,restrict=on,hostfwd=tcp:127.0.0.1:2222-:22

`restrict=on` drops every packet that is not an explicit rule, so in goes the
forwarded ssh port and out goes nothing at all: no LAN, no internet, no DNS.
Since the guest cannot resolve names, Vivado's update and WebTalk checks fail
immediately rather than hanging, which is why `resolv.conf` names no server.
Node-locked licensing needs no connectivity, so nothing is lost.
`NET_RESTRICT=` turns it off if you need the guest online to debug.

## Trimming the image

Most of a Vivado install is of no use to a headless batch worker.
`VIVADO_EXCLUDE_RE` is a list of extended regexes matched against every path;
the default drops documentation, DocNav, third-party simulator models, JTAG
cable drivers (the VM has no USB) and the installer's own metadata.
`VIVADO_EXCLUDES` takes exact paths for whole tools you do not want, e.g.
`Vitis Model_Composer`.

    make sizes        # biggest directories, and what each pattern is worth

Device families are the other big lever -- `data/parts/xilinx/<family>` is
tens of GB -- but excluding the wrong one makes Vivado fail while enumerating
parts, so measure with `make sizes` and add them deliberately rather than
taking a guess from here.

Changing the filter does not rebuild the image on its own; `rm
build/vivado.erofs` or `make -B vivado`.

## Rebuilding

`make rootfs` is cheap and re-runs whenever anything in `guest/` or `config.mk`
changes. `make vivado` deliberately has no dependencies, since squashing tens
of GB takes hours -- force it with `make -B vivado` or by deleting the image.

## Known rough edges

* **ncurses 5.** Vivado wants `libtinfo.so.5` / `libncurses.so.5`, gone from
  Debian since bullseye. `guest/usr/local/sbin/vc-fixups` symlinks the .6
  sonames, which usually works. If your version crashes on startup, add the
  real bullseye debs: put them somewhere and add
  `EXTRA_PACKAGES` / a `copy-in` hook, or switch `SUITE` to `bullseye`.
* **Suite choice.** Default is `trixie`, which is what a 2026.x Vivado
  wants; its glibc is 2.41 against bookworm's 2.36. Older Vivado releases are
  happier on an older base, so `SUITE=bookworm` (or `bullseye` for the
  2019-2021 era) is the fallback -- and the ncurses-5 note above applies to
  those, not to 2026.x.
* **Overlay size.** `OVERLAY_SIZE=50%` of guest RAM. Vivado writes a lot to
  `$HOME` (`.Xilinx`, journal files); if you hit ENOSPC, raise it or point
  `HOME` at `/scratch`.
* **Host keys** are generated at build time and live in the image, so they are
  stable across boots (good for agents) but shared by anyone with the image.
* **No GUI by default.** `ssh -X` with `xauth` installed should work; the
  guest has the X client libs but no display.

## Layout

    Makefile                  everything
    config.mk.example         copy to config.mk, gitignored
    guest/                    files copied verbatim into the image
      etc/initramfs-tools/scripts/vivado   the squashfs+overlay mountroot()
      usr/local/bin/vc-exec, vivado        environment wrappers
      usr/local/sbin/vc-fixups             build-time chroot fixups
      usr/local/sbin/vc-scratch            first-boot scratch disk setup
