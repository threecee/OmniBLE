# T.1 Pod Simulator — Local Dev Runbook

This runbook covers the T.1 pod simulator integration test suite that lives in
`OmniBLETests/Integration/`. These tests spin up a real Go pod-simulator process
(`Vendor/omnipod-pod-simulator-bridge`) and drive OmniBLE's Bluetooth stack
through a mock peripheral, verifying end-to-end behavior without physical hardware.

The marquee test is
`PodHandoffEncryptedTests/testFullPhoneToWatchToPhoneRoundTripWithEncryption`,
which proves the phone-Watch-phone encrypted handoff path (B.2.e verification).

---

## 1. One-time setup

### Install Go 1.21+

The OmniBLETests Run Script Phase builds the pod-sim binary via `go build`. You
need Go on PATH before running tests.

**Standard install (recommended):**

```bash
brew install go
go version   # expect go1.21 or later
```

**Non-standard install (Carl's machine):** Go lives at `~/go-local/go/bin/go`.
The Run Script Phase already includes that path in its PATH export, so no extra
configuration is needed — just make sure the binary exists:

```bash
ls ~/go-local/go/bin/go && echo OK
```

If either path works, `xcodebuild test` will find it automatically.

### Initialize submodules

The pod-simulator bridge lives in `Vendor/omnipod-pod-simulator-bridge`, which
is a git submodule. It must be initialized before the first build:

```bash
cd ~/dev/LoopWorkspace/OmniBLE
git submodule update --init --recursive
```

Verify:

```bash
ls Vendor/omnipod-pod-simulator-bridge/main.go   # should exist
```

### Verify the pod-sim binary builds

```bash
cd ~/dev/LoopWorkspace/OmniBLE/Vendor/omnipod-pod-simulator-bridge
go build -o /tmp/pod-sim .
/tmp/pod-sim -h
```

Expected: usage text including `-fresh`, `-no-auto-disconnect`, `-v` flags.

---

## 2. Running the tests

All integration tests use the scheme `OmniBLETests` inside `LoopWorkspace.xcworkspace`.

### Full test run (all 9 test classes):

```bash
cd ~/dev/LoopWorkspace
xcodebuild test \
  -workspace LoopWorkspace.xcworkspace \
  -scheme OmniBLETests \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

### Run a single class:

```bash
xcodebuild test \
  -workspace LoopWorkspace.xcworkspace \
  -scheme OmniBLETests \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:OmniBLETests/PodHandoffEncryptedTests \
  CODE_SIGNING_ALLOWED=NO
```

### Run the marquee test by itself:

```bash
xcodebuild test \
  -workspace LoopWorkspace.xcworkspace \
  -scheme OmniBLETests \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:OmniBLETests/PodHandoffEncryptedTests/testFullPhoneToWatchToPhoneRoundTripWithEncryption \
  CODE_SIGNING_ALLOWED=NO
```

### Test classes in the suite:

| Class | Tests |
|---|---|
| `PodConnectionTests` | connect, disconnect, reconnect, timeout |
| `PodActivationTests` | full activation, bad LTK, resume after interruption |
| `PodStatusTests` | basic status, detailed status, status during bolus/temp basal |
| `PodBolusTests` | immediate bolus, extended bolus, cancel, insufficient insulin |
| `PodBasalTests` | enact/cancel temp basal |
| `PodSuspendResumeTests` | suspend, resume, preserve schedule |
| `PodAlertsTests` | acknowledge alert, faulted pod reporting, acknowledge fault |
| `PodDeactivationTests` | deactivate active pod, deactivate faulted pod |
| `PodHandoffEncryptedTests` | **marquee**: phone-Watch-phone round-trip with encryption; reservoir change between legs; stale LTK rejection |

---

## 3. Debugging a failing test

### Read `stderrTail()` output

When a test fails, the error message includes a snippet of pod-sim stderr via
`bridge.stderrTail()`. This is the first place to look:

```
XCTAssertEqual failed — … stderr:
2026/04/25 12:34:56 [bridge] received CONNECT_REQ
2026/04/25 12:34:56 [bridge] ERROR unexpected frame type 0x42
```

### Run pod-sim manually with verbose logging

```bash
cd ~/dev/LoopWorkspace/OmniBLE/Vendor/omnipod-pod-simulator-bridge
go build -o /tmp/pod-sim .

# Start with -fresh (blank pod state) and -v (verbose logging)
/tmp/pod-sim -fresh -no-auto-disconnect -v 2>&1 | tee /tmp/pod-sim.log
```

In another terminal you can send raw frames (extracted from XCTest failure
output in Xcode's Report Navigator) to reproduce the exact failure.

### Read an xcresult bundle

After a test run, Xcode saves the result to a path printed in the xcodebuild
output (e.g. `~/Library/Developer/Xcode/DerivedData/.../Logs/Test/*.xcresult`).
Open in Xcode via **File > Open** or:

```bash
open /path/to/result.xcresult
```

The Report Navigator shows per-test stdout/stderr and failure details.

### Enable verbose pod-sim logging in tests

`PodSimulatorBridge` is initialized by `PodSimulatorTestCase.setUp()`. To get
more output, temporarily add `-v` to the bridge launch arguments (in the Swift
source) and re-run the failing test.

---

## 4. Adding a new test

1. Decide which test class to extend, or create a new one in
   `OmniBLETests/Integration/` (e.g., `PodXxxTests.swift`).

2. Subclass `PodSimulatorTestCase`. This base class provides:
   - `bridge: PodSimulatorBridge` — a fresh pod-sim subprocess, started in `setUp()`
   - `mockPeripheral: MockOmnipodPeripheral` — fake BLE peripheral wired to the bridge
   - `pairFreshPod()` — completes the standard pairing dance, returns an `OmniBLEPumpManager`

3. Structure: **ARRANGE → ACT → ASSERT**

   ```swift
   func testMyNewBehavior() throws {
       // ARRANGE
       let manager = try pairFreshPod()

       // ACT
       let result = try manager.doSomething(...)

       // ASSERT
       switch result {
       case .success(let value):
           XCTAssertEqual(value.someField, expectedValue)
       case .failure(let error):
           XCTFail("\(error); stderr: \(bridge.stderrTail())")
       }
   }
   ```

4. Run just your new test for fast iteration:
   ```bash
   xcodebuild test \
     -workspace LoopWorkspace.xcworkspace \
     -scheme OmniBLETests \
     -destination 'platform=iOS Simulator,name=iPhone 16' \
     -only-testing:OmniBLETests/PodXxxTests/testMyNewBehavior \
     CODE_SIGNING_ALLOWED=NO
   ```

5. Add the new file to the `OmniBLETests` target in Xcode (Target Membership
   checkbox) if it is a new file.

---

## 5. CI

### How it works

The GitHub Actions workflow (`.github/workflows/build.yml`) runs `test-ios` on
`macos-15`:

1. Checks out `threecee/LoopWorkspace` (the consumer workspace) with `submodules: recursive`
2. Points the `OmniBLE` submodule at the triggering commit, then runs
   `git submodule update --init --recursive` to pull in `omnipod-pod-simulator-bridge`
3. Runs `actions/setup-go@v5` to put Go on PATH
4. Runs `xcodebuild test -scheme OmniBLETests`

The Run Script Phase's PATH export (`/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$HOME/go-local/go/bin`) picks up the CI Go automatically — `/usr/local/go/bin` is where `setup-go` installs Go on macOS runners.

### Trigger branches

The workflow runs on push to `watchos-support`, `t1-implementation`, and on
pull requests targeting `watchos-support`, `dev`, `main`, or `t1-implementation`.

### CI cost note

The first `go build` of pod-sim adds roughly 60-90 seconds to the test job.
The `setup-go` cache (`cache-dependency-path: go.sum`) shortens subsequent
runs. Total wall-clock for the `test-ios` job (including Go build and all 226+
tests): approximately 2-4 minutes.

### If CI fails

Common issues and fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `error: 'go' not found on PATH` | setup-go step missing or wrong PATH | Verify `Set up Go` step is in `test-ios` job |
| `no such file or directory: pod-sim` | submodule not initialized | Verify `git submodule update --init --recursive` step is present |
| `xcodebuild: error: 'OmniBLETests' scheme not found` | workspace clone failed or wrong branch | Check `WORKSPACE_REPO`/`WORKSPACE_BRANCH` env vars |
| Xcode version mismatch | SDK not found | Check `sudo xcode-select` step; may need `Xcode_17.x.app` |
