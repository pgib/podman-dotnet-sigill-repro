# .NET 10 SIGILL on Podman (Apple Silicon M5)

## Summary

`dotnet build` crashes with `SIGILL` (illegal instruction, exit code 132) when running inside a Podman container on Apple Silicon M5 (and likely M4+). The same container works fine on Apple M2 and under Docker Desktop on any Apple Silicon Mac.

## Environment

- **Host:** macOS (Darwin 25.3.0), Apple M5
- **Podman:** podman machine using Apple Hypervisor.framework
- **Podman VM:** Fedora CoreOS, kernel 6.18.10-200.fc43.aarch64
- **Image:** `mcr.microsoft.com/dotnet/sdk:10.0` (Ubuntu 24.04 arm64)
- **.NET SDK:** 10.0.201, Runtime 10.0.5

## Root Cause

The Podman VM's Fedora kernel advertises ARM CPU features that the Apple Hypervisor cannot properly execute. The guest CPU reports these features via `/proc/cpuinfo`:

```
sme smei16i64 smef64f64 sme2 sme2p1 smeb16b16 smef16f16 ...
```

These are newer ARMv9 Scalable Matrix Extensions present on the M5 but not on the M2. The .NET runtime (or glibc) detects these features and emits instructions that cause SIGILL when the hypervisor fails to handle them.

Docker Desktop uses a different VM stack (LinuxKit + Virtualization.framework) that does not expose these problematic features to the guest, so the same workload succeeds.

## Observations

- A trivial `dotnet new console && dotnet build` crashes with exit code 132.
- The Alpine-based image (`sdk:10.0-alpine`, musl libc) does **not** crash for simple builds, suggesting glibc's ARM feature detection is involved.
- Even with Alpine, parallel MSBuild nodes (≥4) crash. Limiting to `-m:3` or `DOTNET_PROCESSOR_COUNT=2` avoids the crash.
- `DOTNET_ReadyToRun=0` and `DOTNET_EnableHWIntrinsic=0` reduce but do not eliminate the crashes.
- On the same Mac with Docker Desktop, everything works with default settings.
- On an M2 Mac with Podman, everything works with default settings.

## Reproduce

```bash
# 1. Ensure Podman machine is running on an Apple M5 Mac
podman machine start

# 2. Verify CPU features include SME2
podman machine ssh cat /proc/cpuinfo | grep -o 'sme2'

# 3. Run the repro
cd podman-dotnet-sigill-repro
podman compose up --build
```

The build will fail with:
```
MSBUILD : error MSB4166: Child node "N" exited prematurely.
```
or:
```
Illegal instruction (core dumped)
```

### Workaround verification

```bash
# Alpine image builds simple projects but still fails with parallelism:
podman run --rm mcr.microsoft.com/dotnet/sdk:10.0-alpine \
  sh -c 'mkdir /t && cd /t && dotnet new console -o . && dotnet build'
# ✅ succeeds

# Ubuntu image fails even for trivial builds:
podman run --rm mcr.microsoft.com/dotnet/sdk:10.0 \
  sh -c 'mkdir /t && cd /t && dotnet new console -o . && dotnet build'
# ❌ SIGILL
```

## Expected Behavior

`dotnet build` should succeed, as it does under Docker Desktop and on M2 Macs with Podman.

## Suggested Fix

The Podman VM's kernel (or Apple Hypervisor.framework integration) should either:
1. Not advertise CPU features that the hypervisor cannot execute, or
2. Trap and emulate the unsupported instructions.
