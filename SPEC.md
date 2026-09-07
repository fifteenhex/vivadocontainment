# vivadocontainment MQTT protocol

Version 1. This is the whole interface to a Vivado worker: an agent needs a
broker address and a project name, nothing else. There is no shared
filesystem, no ssh requirement and no host access -- sources go in over MQTT,
jobs run inside the VM, artifacts come back over MQTT.

## Vocabulary

| term | meaning |
|------|---------|
| worker | one VM running `vc-projd`, identified by `<worker>` (default `vivado1`) |
| base | topic prefix, `<base>` (default `vivado`) |
| project | a directory owned by an agent, named `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, case-sensitive (`demo` and `Demo` are two projects) |
| request | one JSON message from an agent |
| reply | one or more JSON messages back, the last one flagged `final` |

## Topics

| topic | direction | payload |
|-------|-----------|---------|
| `<base>/project/<project>/request` | agent -> worker | request object |
| `<base>/project/<project>/reply/<req>` | worker -> agent | reply object |
| `<base>/project/<project>/job/<job>/log` | worker -> agent | one output line, UTF-8 |
| `<base>/worker/<worker>/state` | worker -> all | `online` / `offline`, retained |
| `<base>/worker/<worker>/status` | worker -> all | status object, retained |

Rules:

* Publish requests with **QoS 1** and **retain = false**. A retained request
  is refused and logged, since the broker would replay it at every reconnect.
* Subscribe to `<base>/project/<project>/reply/<req>` **before** publishing the
  request, or the reply can beat the subscription.
* Replies are QoS 1 and not retained. Log lines are QoS 0 and may be dropped
  under load -- the authoritative log is the file named in the run result, and
  can be fetched with `get`.
* Tolerate traffic you did not ask for. Brokers hand out retained messages
  generously on subscribe, so a client can receive `worker/<w>/state` (the
  bare string `online`, not JSON) even when it only subscribed to its own
  reply topic. Filter on the topic and ignore anything that does not parse;
  never let a stray payload kill the client.
* A worker answers for every project name it is asked about; projects are
  created on demand by `create` and are not owned or locked. Coordination
  between agents is by convention: one project per agent task.

## Request envelope

```json
{"req": "unique-id", "op": "put", "...": "op-specific fields"}
```

A request may also carry `"worker": "<worker>"`. Every worker on a broker
listens to the same project topics, so without it they would all answer the
same request; name one when more than one is connected.

`req` is any string unique to the caller; it names the reply topic, so it must
be a string of 1..128 characters containing no `/`, `+`, `#` or whitespace. A
request whose `req` is missing, not a string, or unusable is **dropped and
logged** -- there is no topic to answer it on, and inventing one would put the
reply somewhere nobody is listening. Silence is therefore a possible response
to a malformed request; every other failure comes back as `ok: false`.

## Reply envelope

```json
{"req": "unique-id", "op": "put", "ok": true, "final": true,
 "worker": "vivado1", "...": "op-specific fields"}
```

* `boot` identifies the worker's current boot. It changes when the machine
  reboots and not when the daemon restarts, so a client that records it
  alongside a project can tell whether the worker went away underneath it --
  see "Knowing whether your work survived" below.
* `ok: false` means the request was rejected or failed; `error` is a human
  readable string. Treat it as terminal for that request.
* `ok: true` says the worker did what was asked. **A failed build is still
  `ok: true`** -- success of the work is `rc`, not `ok`.
* `final: false` marks progress messages; keep listening until `final: true`.
  Progress states arrive in order (`queued`, `running`, `done`), but treat the
  `final` reply as the only authority on what happened.

## Operations

### create

```json
{"req": "1", "op": "create"}
-> {"ok": true, "final": true, "path": "/scratch/projects/demo", "existed": false}
```

Idempotent. Creates the project directory and its `.vc` bookkeeping dir.

### destroy

```json
{"req": "2", "op": "destroy"}
-> {"ok": true, "final": true, "path": "/scratch/projects/demo"}
```

Removes the project and everything in it, including any jobs of its own
still queued, which are cancelled. Refused only while one of its jobs is
actually running: cancel that first, rather than have the directory deleted
out from under a live build.

### put

Writes one file, creating parent directories, replacing it if it exists.

| field | type | notes |
|-------|------|-------|
| `path` | string | relative to the project root, required; absolute is refused |
| `b64` | string | base64 of the file content |
| `text` | string | alternative to `b64` for text files |
| `mode` | string | octal, e.g. `"755"`, optional |
| `chunk` | object | `{"id": "...", "index": 0, "count": 3}`, optional |

```json
{"req": "3", "op": "put", "path": "src/top.v", "text": "module top(); endmodule\n"}
-> {"ok": true, "final": true, "path": "src/top.v", "size": 24, "complete": true}
```

Files larger than the broker's message limit must be chunked: send `count`
messages with the same `chunk.id` and `index` `0..count-1`. Order does not
matter, parts are staged on disk. Every chunk gets its own reply with
`complete: false` until the last part lands, then the file is assembled and
`complete: true` is returned. An `index` outside the range, or a `count` that
disagrees with an upload already in progress under the same `chunk.id`, is
refused rather than accepted into a partial that could never assemble.
Abandoned partials are visible under `.vc/incoming/<chunk.id>` and can be
dropped with `rm -r`. The `path` in the final reply is the path actually
written, which for a rejected or rewritten path is not necessarily the one you
sent. Keep payloads under ~256 KiB; base64 inflates by
4/3, so 192 KiB of file data per message is a safe chunk.

### get

```json
{"req": "4", "op": "get", "path": "build/top.bit"}
-> {"ok": true, "final": false, "size": 2247, "b64": "...",
    "chunk": {"index": 0, "count": 2}}
-> {"ok": true, "final": true,  "size": 2247, "b64": "...",
    "chunk": {"index": 1, "count": 2}}
```

The worker splits by `MAX_CHUNK` (256 KiB by default). Concatenate the decoded
chunks in `index` order. `get` on a directory is an error; use `ls`.

### rm

```json
{"req": "5", "op": "rm", "path": "build", "recursive": true}
```

`recursive` is required to remove a directory. Removing the project root is an
error -- use `destroy`.

### ls

```json
{"req": "6", "op": "ls", "path": "", "recursive": true}
-> {"ok": true, "final": true, "entries": [
     {"path": "src", "size": 60, "mtime": 1788753148, "dir": true},
     {"path": "src/top.v", "size": 24, "mtime": 1788753148, "dir": false}]}
```

`path` defaults to the project root. The `.vc` directory is hidden from a
listing of the root, but it is not secret: `ls` it explicitly (`"path":
".vc/jobs"`) to enumerate past jobs, and `get` their `.log` and `.json`. That
is how an agent picking up someone else's project finds out what has already
been run.

`.vc` is **read-only**: `put` and `rm` into it are refused. It holds the job
records and the staging area for chunked uploads, and a client that could
rewrite those could forge its own results.

### vivado

Runs Vivado in batch mode on a tcl script from the project. The worker builds
the command line; there is no way to pass it an argv of your own.

| field | type | notes |
|-------|------|-------|
| `tcl` | string | project-relative path to the script, must exist, required |
| `tclargs` | array | strings passed after `-tclargs`, opaque to the worker |
| `log` | string | project-relative path for `-log`, optional; parent directories are created |
| `journal` | string or bool | path for `-journal`; `false` (default) means `-nojournal`; parent directories are created |
| `cwd` | string | project-relative working directory, default the project root |
| `timeout` | number | seconds; **absent means unbounded**, so always send it |
| `job` | string | job id, `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, generated if absent |

```json
{"req": "7", "op": "vivado", "tcl": "fpga/nitefury/build.tcl",
 "tclargs": ["-core_div", "40", "-pcie", "-ddr3"],
 "log": "out/vivado.log", "journal": false, "timeout": 7200}
-> {"ok": true, "final": false, "job": "j178875...", "state": "queued",
    "log": "vivado/project/demo/job/j178875.../log"}
-> {"ok": true, "final": false, "job": "j178875...", "state": "running", "log": "..."}
-> {"ok": true, "final": true,  "job": "j178875...", "state": "done",
    "rc": 0, "seconds": 812.4, "log": ".vc/jobs/j178875....log",
    "tail": ["...", "last 50 lines"]}
```

That becomes, exactly:

    vivado -mode batch -source <project>/fpga/nitefury/build.tcl \
           -log <project>/out/vivado.log -nojournal \
           -tclargs -core_div 40 -pcie -ddr3

Notes for the caller:

* Subscribe to the `log` topic from the first reply to stream output live. The
  final reply's `log` is a **path inside the project**, fetchable with `get`.
* `rc` is Vivado's exit status. A process killed by a signal reports a
  negative `rc`; on expiry it also carries `"error": "timeout"`, which is what
  distinguishes a timeout from a `cancel`.
* One job runs at a time per worker; further jobs queue. File operations are
  served immediately even while a job runs.
* The queue is **round-robin over projects**, FIFO within a project. Queueing
  ten builds does not push a neighbour's single build behind all ten: each
  project takes one turn at a time, and a project that has just appeared is
  served next rather than last. So your own jobs run in the order you sent
  them, and the wait before the first one depends on how many *projects* are
  busy, not on how many jobs they have.
* `tclargs` entries are handed to `execve` as separate arguments. No shell is
  involved, so quoting, `;`, `$(...)` and backticks have no special meaning --
  they arrive at Tcl verbatim.
* There is no way to set an environment variable for the job. A tcl that reads
  `::env(SOMETHING)` has to be changed to read `argv` instead, and the value
  passed in `tclargs`. Nor is the project a git checkout, so a script that
  stamps itself with `git rev-parse` gets nothing useful -- pass the stamp in.
* Vivado opens `-log` before it runs your script, so the script cannot create
  that directory itself; the worker creates the parents for `log` and
  `journal`. `put` likewise creates the parents of the file it writes, which
  is the only way to make a directory -- there is no `mkdir` op.

### tool

The simulation binaries, same shape, for the `xvlog` / `xelab` / `xsim` flow.

| field | type | notes |
|-------|------|-------|
| `tool` | string | one of `xvlog`, `xelab`, `xsim`; anything else is refused |
| `args` | array | strings, passed as-is |
| `cwd`, `timeout`, `job` | | as for `vivado` |

```json
{"req": "8", "op": "tool", "tool": "xvlog",
 "args": ["--sv", "-L", "unisims_ver", "-f", "files.list"], "timeout": 600}
```

Replies are identical to `vivado`, including the durable job record.

### version

```json
{"req": "9", "op": "version"}
-> {"ok": true, "final": true, "rc": 0,
    "version": "Vivado v2023.2 (64-bit)", "output": "..."}
```

Fixed argv, no input, answered immediately rather than queued. `version` is
null when no version line could be found, and `stderr` carries any warnings
separately, so a diagnostic is never mistaken for a version.

Note that `vivado -version` exits before some of the startup a real build
does: **rc 0 alone does not promise a working worker.** Require both `rc: 0`
and a non-null `version`.

### jobs

Every job leaves a record at `.vc/jobs/<job>.json`, so a result outlives the
client that asked for it.

```json
{"req": "10", "op": "jobs"}
-> {"ok": true, "final": true, "jobs": [
     {"id": "j178875...", "op": "vivado", "cmd": ["vivado", "..."],
      "state": "done", "rc": 0, "seconds": 812.4, "queued": 178875...,
      "started": 178875..., "ended": 178876...,
      "log": ".vc/jobs/j178875....log"}]}
```

`state` is `queued`, `running`, `done` or `interrupted`; the last means the
worker restarted mid-job, so no exit status was ever collected.

Most recent first; pass `"job": "<id>"` for one. The whole list comes in one
message, roughly 350 bytes per job, so a project accumulating more than about
750 jobs will outgrow a 256 KiB broker limit. **This is how you recover
from a dropped connection**: replies are not retained and the broker will not
redeliver them, so if you are away when a job finishes, `jobs` is the only
place the exit status still exists. Poll it after reconnecting rather than
trying to infer success from the log text.

### cancel

```json
{"req": "8", "op": "cancel", "job": "j1788753148189"}
-> {"ok": true, "final": true, "cancelled": true}
```

Terminates the job if it is running **in this project**, or drops it from
the queue if it has not started yet -- in which case its own request gets a
final reply with `state: "cancelled"`, so a client waiting on it is not left
waiting. You cannot cancel another project's job; anything else comes back
`ok: false`. The whole process group is signalled, so a tcl that spawned
children with `exec` does not leave them behind holding the job slot. The
job's own request then gets its final reply with a negative `rc`.

### status

```json
{"req": "9", "op": "status"}
-> {"ok": true, "final": true, "exists": true, "path": "...", "busy": true,
    "current": {"job": "j178875...", "project": "demo", "op": "vivado",
                "started": 1788786326},
    "queued": 0, "queued_here": 0, "projects": ["demo", "second"]}
```

The retained `<base>/worker/<worker>/status` carries the same worker-level
fields plus `root` and `free` (bytes free on the project filesystem), so an
agent can pick an idle worker without sending anything.

`queued` counts every waiting job on the worker, `queued_here` only this
project's. With round-robin scheduling the second is what predicts your own
wait.

`current` is `null` when idle, and otherwise names the job, **the project
that owns it**, and when it started. The owner is there so that a busy worker
does not read as a stuck one: a job of someone else's, running for twenty
minutes, is a synthesis, not a fault. You cannot cancel it, and you should
not go looking for someone who can.

## A complete session

```
subscribe vivado/project/demo/reply/+
publish   vivado/project/demo/request  {"req":"1","op":"create"}
publish   vivado/project/demo/request  {"req":"2","op":"put","path":"src/top.v","text":"..."}
publish   vivado/project/demo/request  {"req":"3","op":"put","path":"build.tcl","text":"..."}
publish   vivado/project/demo/request  {"req":"4","op":"vivado",
                                        "tcl":"build.tcl","log":"out/vivado.log",
                                        "timeout":7200}
subscribe vivado/project/demo/job/+/log            # live output
   ... wait for reply 4 with final:true, check rc ...
   ... if the connection dropped: {"req":"4b","op":"jobs"} and read rc ...
publish   vivado/project/demo/request  {"req":"5","op":"get","path":"build/top.bit"}
publish   vivado/project/demo/request  {"req":"6","op":"destroy"}
```

`scripts/vc` in this repo does exactly this and is the reference
implementation; `scripts/vc -p demo vivado build.tcl --log out/vivado.log`
is one command's worth of it.

## Knowing whether your work survived

Every reply and every job record carries `boot`, and the retained
`worker/<w>/status` carries `boot` and `persistent`. Between them:

| what you see | what it means |
|---|---|
| same `boot` as before | nothing was lost; a queued job is still queued |
| new `boot`, `persistent: true` | the worker rebooted: files are intact, but any job that was running is dead and its record says `interrupted` |
| new `boot`, `persistent: false` | the worker rebooted with no persistent disk: **the project and everything in it is gone** |

So record the `boot` you saw when you created a project, and compare it on
your next reply. If it changed, `jobs` tells you what happened to anything
that was running, and `ls` tells you whether your files are still there.
`persistent: false` means an operator has not attached a scratch disk, and
nothing you upload will outlive the VM.

## What is contained, and what is not

The worker will not run a command of your choosing. There is no `run` op, no
`cmd` field, no shell, and no caller-supplied environment (`env` is refused
outright rather than ignored, since `LD_PRELOAD` alone would undo the point).
The only binaries reachable are `vivado` and the three simulation tools, with
argv the worker assembles from validated fields. Paths are confined to the
project: absolute paths are refused and `../` cannot escape.

**The tcl you upload is arbitrary Tcl, and Tcl has `exec`.** Real build
scripts use it -- `exec find`, `file delete -force`, `file copy` are all in
the scripts this was built for -- so it is not filtered, and no attempt is
made to parse your way out of the problem. A job can therefore reach other
programs in the guest, and the isolation boundary is the VM: a read-only
Vivado and a root filesystem thrown away at poweroff.

The broker needs credentials and a topic ACL too, since publishing to a
project topic is what grants all of this in the first place.

The same applies to the broker. Anyone who can publish to
`<base>/project/+/request` can drive Vivado on that machine and read and write
anything in a project, so the broker needs credentials and a topic ACL. An
open broker on a routable address is the whole security story, not the ops
below.

## What the VM is like

* Read-only Debian with a tmpfs overlay: **anything outside the project
  directory is lost at poweroff**, including installed packages.
* Projects live under `/scratch/projects/<name>` on a persistent disk. If the
  operator did not attach one, `/scratch` is RAM and dies with the VM; the
  worker logs a warning at startup and `status.root`/`free` will show it.
* Vivado is mounted read-only at the path it was installed at on the host. Do
  not try to write to it or install IP into it.
* The guest has outbound NAT (it can fetch from the internet) but nothing can
  connect in except the operator's forwarded ssh port.
* One worker is one Vivado at a time. Do not expect parallel synthesis on a
  single worker; ask the operator for more workers instead, each with its own
  `<worker>` id on the same broker.

## Conventions worth keeping

* One project per task, destroyed when the task is done. Project directories
  are not garbage collected.
* Put sources under `src/`, scripts at the root, let Vivado write to `build/`.
  Nothing enforces this; it just makes `ls`/`get` predictable for the next
  agent that picks the project up.
* Keep the reports: `get` the run log and any `*.rpt` before `destroy`, since
  the tail in the final reply is only the last 50 lines.
* Use `timeout` on every job. Without one a wedged Vivado holds the worker's
  single job slot until someone cancels it.
* Upload sources file by file. There is no archive op and no `tar`: 74 files
  of a real board build take about three seconds, which is nothing against a
  synthesis measured in tens of minutes.
