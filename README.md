# vivadocontainment

Takes an existing Vivado installation and puts it inside an immutable QEMU VM,
so agents on a big machine can run Vivado without the install ever being
modified and without polluting the host. Agents reach it over MQTT only:
they create a project, push sources into it, run jobs and pull artifacts back
on that project's topic. `SPEC.md` is the contract they need.

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

| path                 | backing               | survives reboot |
|----------------------|-----------------------|-----------------|
| `/` `/tmp`           | tmpfs (RAM)           | no              |
| `/scratch/projects`  | `build/scratch.qcow2` | yes, if created |

There is no host filesystem share on purpose: the only way in or out is MQTT,
so an agent needs nothing but a broker address. Run `make scratch` before
first boot, or projects live in RAM and die with the VM.

## Using it

On the machine that has Vivado:

    make check                       # what's missing
    cp config.mk.example config.mk   # then edit VIVADO_DIR, MQTT_BROKER etc.
    make rootfs                      # minutes
    make vivado                      # hours, and needs ~1x the install size free
    make scratch                     # where projects live, do this before booting
    make run                         # console on your terminal, ^A x to quit

`make run-bg` daemonizes it and logs the console to `build/console.log`;
`make stop` kills it. ssh on port 2222 still works for poking around, but it
is not how work gets submitted.

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

## Licensing

The license comes along with the install. `LICENSE_FILE` defaults to the first
of `~/.Xilinx/Xilinx.lic`, `$VIVADO_DIR/Xilinx.lic`,
`$VIVADO_DIR/.Xilinx/Xilinx.lic`; it is copied to `/etc/vivadocontainment/Xilinx.lic`
in the image and pointed at by `XILINXD_LICENSE_FILE`.

Node-locked licenses are tied to a NIC address, and FlexLM inside the guest
recomputes that from `eth0`, so **the VM has to present the host's MAC**. The
build reads `HOSTID=` out of the .lic and passes it to qemu:

    make license-mac
    license  /home/you/.Xilinx/Xilinx.lic
    hostid   00:11:22:aa:bb:cc
    guest    00:11:22:aa:bb:cc

Set `MAC` in `config.mk` to override (e.g. if the license names an interface
other than the one it lists first, or you have several INCREMENT lines with
different hostids). The kernel gets `net.ifnames=0` so the virtio NIC really is
`eth0`. Faking the MAC of a machine you own, to run a license you own, on that
same machine, is the intended use here -- it is a NAT'd VM on the licensed
host, not a way to move the license elsewhere.

For a floating license set `XILINXD_LICENSE_FILE = 2100@server` instead; it
wins over `LICENSE_FILE`. The VM is behind QEMU's user-mode NAT, so it can
reach a license server on the host at `10.0.2.2`, and nothing can reach the VM
except the forwarded ssh port.

## Jobs and projects over MQTT

Set `MQTT_BROKER` in `config.mk` and the guest runs `vc-projd`, which owns
`/scratch/projects` and answers on one topic per project:

    <base>/project/<name>/request        requests in
    <base>/project/<name>/reply/<req>    replies out
    <base>/project/<name>/job/<id>/log   job output, line by line

Ops are `create`, `put`, `get`, `rm`, `ls`, `vivado`, `tool`, `version`,
`jobs`, `cancel`, `destroy`, `status`. Files travel base64'd, chunked when
large; `vivado` and `tool` stream output to the log topic and end with a final
reply carrying `rc`, the timing and the last 50 lines, and leave a durable
record in `.vc/jobs/`. One job at a time per worker, while file operations stay
responsive. **`SPEC.md` is the full protocol** -- that is the document to hand
to another agent.

There is deliberately no way to run a command of your choosing: the worker
builds every argv itself from validated fields, so an agent can drive Vivado
without reaching a shell. Read "What is contained, and what is not" in
`SPEC.md` before treating that as a sandbox -- uploaded tcl is still arbitrary
tcl.

`scripts/vc` is the reference client:

    make vc ARGS="-p demo create"
    make vc ARGS="-p demo put build.tcl"
    make vc ARGS="-p demo put rtl/top.v src/top.v"
    make vc ARGS="-p demo vivado build.tcl --log out/vivado.log"
    make vc ARGS="-p demo jobs"
    make vc ARGS="-p demo ls -r"
    make vc ARGS="-p demo get build/top.bit top.bit"
    make vc ARGS="-p demo destroy"

It takes `VC_BROKER`, `VC_PROJECT` and friends from the environment too, so
`scripts/vc -p demo status` works standalone.

To watch the traffic rather than take part in it:

    make watch                    # everything on the base topic
    make watch PROJECT=demo       # one project

## What the guest can reach

By default the VM is on a leash that qemu holds, not the guest:

    -netdev user,restrict=on,hostfwd=tcp:127.0.0.1:2222-:22,
            guestfwd=tcp:10.0.2.100:1883-tcp:<your broker>:1883

`restrict=on` drops every packet that is not an explicit rule, so in goes the
forwarded ssh port and out goes one TCP connection to the broker -- reached
inside the guest as `10.0.2.100:1883` whatever the broker's real address is.
Nothing else: no LAN, no internet, no DNS. Since the guest cannot resolve
names, Vivado's update and WebTalk checks fail immediately rather than
hanging, which is why `resolv.conf` names no server.

This matters because a build script is arbitrary Tcl and Tcl has `exec`: the
job can run what it likes inside its project, but it cannot carry anything out
over the network. Node-locked licensing needs no connectivity, so nothing is
lost. `NET_RESTRICT=` turns it off if you need the guest online to debug, and
`GUEST_BROKER` changes the address the guest dials.

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
* **Broker limits.** Chunks are sized for a 256 KiB message limit. mosquitto's
  default is unlimited, but a broker configured with `message_size_limit`
  lower than that will reject transfers; lower `MAX_CHUNK` in
  `guest/etc/vivadocontainment/mqtt.conf` to match.
* **Host keys** are generated at build time and live in the image, so they are
  stable across boots (good for agents) but shared by anyone with the image.
* **No GUI by default.** `ssh -X` with `xauth` installed should work; the
  guest has the X client libs but no display.

## Layout

    Makefile                  everything
    config.mk.example         copy to config.mk, gitignored
    SPEC.md                   the MQTT protocol, for the agents using it
    scripts/license-mac       pull the node-lock MAC out of a .lic
    scripts/vc                reference MQTT client
    guest/                    files copied verbatim into the image
      etc/initramfs-tools/scripts/vivado   the squashfs+overlay mountroot()
      etc/vivadocontainment/mqtt.conf      generated from config.mk
      usr/local/bin/vc-exec, vivado        environment wrappers
      usr/local/sbin/vc-projd              the MQTT project and job service
      usr/local/sbin/vc-fixups             build-time chroot fixups
      usr/local/sbin/vc-scratch            first-boot scratch disk setup
