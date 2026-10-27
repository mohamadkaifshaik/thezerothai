# Runbook: two emulator suites on one machine (shared Storage blob directory)

Applies to local development and agent test runs: `make emulators`, `make test-int`, `make dev` and any raw
`firebase emulators:*` command. Not a production failure mode. Found by the W3-20 tester (defect D-2 in
`docs/reviews/test-report-w3.md`, which lands with PR #355).

## 1. Symptom

An emulator suite dies in the middle of a run while another suite on the same machine starts or stops. In the
firebase-tools output (`firebase-debug.log`, or the console with `--debug`):

```
Error: ENOENT: no such file or directory, open '...\Temp\firebase\storage\blobs\<uuid>'
    at Persistence.appendBytes (...\firebase-tools\lib\emulator\storage\persistence.js)
    at UploadService.multipartUpload (...\firebase-tools\lib\emulator\storage\upload.js)
Error: An unexpected error has occurred.
```

Then every call to the Auth emulator is "connection refused" (it lives in the same Node process as the Storage
emulator), the test that was uploading sees a 500 from the object store (the account-export delivery in the W3-20
end-to-end test), and the rest of the suite fails. It looks intermittent because it needs the second suite to start or
stop during an upload. The firebase-tools warning "you are running multiple instances of the emulator suite for
project ..." appears in the same runs.

## 2. Cause

The Storage emulator keeps its blobs in `os.tmpdir()/firebase/storage/blobs` (firebase-tools also writes its hub
locator file, `hub-<project>.json`, directly in `os.tmpdir()`). That location is shared by every emulator suite on the
machine: different ports and different project ids do not help, only a different temp directory does. A second suite
starting or stopping clears the directory under the first one. We routinely run several agents' suites at once.

## 3. The fix in this repo (nothing to do for `make` targets)

`scripts/with-private-tmp.sh <command...>` creates a run-unique directory (`mktemp -d`, named `dzeroth-emu.XXXXXX`,
under the caller's `TMPDIR` or `/tmp`; on Windows Git Bash that is the user's Temp), exports `TEMP`, `TMP` and
`TMPDIR` pointing at it for `<command>` and everything it starts, and removes it when the command ends (exit,
Ctrl+C or SIGTERM). The caller's own environment is not changed. On Windows `TEMP` and `TMP` get the native `C:\...`
form (Node's `os.tmpdir()` reads them there); on Linux CI, Node reads `TMPDIR`.

The Makefile targets that start emulators (`emulators`, `test-int`, `dev`) run behind it, and CI's
`make test-int (Firebase emulators)` job goes through the same target, so Linux CI and local runs behave the same
(the workflow file is unchanged). `make loadtest` starts no emulator (it runs k6 against ones you started with
`make emulators`), so it needs nothing. `go test` and `go run` started by the emulator script inherit the private
directory too, so `t.TempDir()` and Go's build work directory also land there.

**Raw `firebase` calls must use the wrapper**, otherwise they share the machine's Temp again:

```sh
export GOWORK=off
bash scripts/with-private-tmp.sh firebase emulators:exec --project demo-dzeroth-local \
  --only firestore,auth,pubsub,storage 'cd backend && go test -tags=integration -count=1 -run TestX ./internal/...'
```

Proof that it works (what a probe run as the `emulators:exec` script printed, Windows, firebase-tools 15.31):
`os.tmpdir()` was the private directory, the Storage emulator had created `firebase\storage\blobs` inside it, a
test upload put one blob there, and the directory was gone when the command returned.

## 4. Running two suites side by side

The private temp directory removes the file collision; ports are still yours to separate.

1. Put a copy of the emulator config **at the repo root** (the `firebase/*.rules` and index paths are relative to the
   config file). `firebase.graph-loadtest.json` already uses 14400 / 14500 / 18080 / 19099 / 18085 / 19199 with the UI
   off; copy it and change the ports if that set is busy too. Keep `hub` and `logging` set explicitly (as that file
   does) as well as the four emulators, so nothing falls back to the default 4400 / 4500 the other suite may hold. Do
   not commit the copy.
2. `make test-int FIREBASE="firebase --config <your-copy>.json"`. A top-level `--config` is honoured by
   `emulators:exec`. The project id stays `demo-dzeroth-local`; the Go tests read the hosts from the environment
   `emulators:exec` sets, so they follow your ports.
3. On this Windows machine `make` needs `FIREBASE=firebase` (or the line above): `command -v firebase` yields a `/c/...`
   path make cannot spawn (D-T17-2 of the graph test report); a bare `make test-int` there expands `$(FIREBASE)` to
   nothing and fails with "command not found".

## 5. Leftovers

- Windows can leave an emulator `java.exe` behind after `emulators:exec`. Find the one listening on **your** ports
  (`netstat -ano | grep -E ':(<your ports>) '`) and kill that PID (`taskkill //PID <pid> //F`). Never kill by image name:
  other agents' suites run on the same machine.
- If a leftover process still holds files when the command ends, the wrapper prints
  `with-private-tmp: could not remove <dir>` and leaves the directory (the exit status of your command is
  unchanged). It is safe to delete `dzeroth-emu.*` directories in Temp once no emulator is running.

## 6. What this does not isolate

- **Ports.** Two suites on the same ports still collide ("port taken"); use section 4.
- **A running hub seen from another shell.** `firebase emulators:export` and similar commands find a running hub
  through `hub-<project>.json` in `os.tmpdir()`. A wrapped suite keeps that file in its private directory, so a raw
  command in another terminal will not see it. Use `--export-on-exit` on the suite instead.
- **The emulator JAR cache** (`~/.cache/firebase/emulators`) stays shared: it is only read once downloaded.
- **The Go build cache** stays shared (Go makes it safe for concurrent use).
