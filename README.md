# .NET SIGILL on Podman (Apple Silicon M4/M5)

## Summary

`dotnet build` crashes with `SIGILL` (illegal instruction, exit code 132) when running inside a Podman container on Apple Silicon M4/M5. The same container works fine on M2/M3 Macs and under Docker Desktop on any Apple Silicon Mac.

## Environment

- **Host:** macOS, Apple M4/M5
- **Podman:** podman machine using Apple Hypervisor.framework (applehv)
- **Podman VM:** Fedora CoreOS, kernel 6.x aarch64
- **Image:** `mcr.microsoft.com/dotnet/sdk:10.0` (Ubuntu 24.04 arm64, glibc)
- **.NET SDK:** 10.0.x

## Root Cause

The Podman VM's Fedora kernel advertises ARM CPU features (SME/SME2) that the Apple Hypervisor cannot properly execute. The guest CPU reports these features via `/proc/cpuinfo`:

```
sme smei16i64 smef64f64 sme2 sme2p1 smeb16b16 smef16f16 ...
```

These are ARMv9 Scalable Matrix Extensions present on M4/M5 but not on older chips. The glibc in the Ubuntu-based .NET image detects these features and emits instructions that cause SIGILL when the hypervisor fails to handle them.

Docker Desktop uses a different VM stack (LinuxKit + Virtualization.framework) that does not expose these problematic features to the guest.

## Reproduce

```bash
# 1. Ensure Podman machine is running on an Apple M4/M5 Mac
podman machine start

# 2. Verify CPU features include SME2
podman machine ssh cat /proc/cpuinfo | grep -o 'sme2'

# 3. Run the repro (may need multiple attempts - issue is intermittent)
podman build --no-cache .

# Or run in a loop until it fails:
while podman build --no-cache . 2>&1 | tail -1 | grep -q "Successfully"; do
  echo "Build succeeded, retrying..."
done
```

The build will fail with exit code 132:
```
MSBUILD : error MSB4166: Child node "N" exited prematurely.
```
or:
```
Illegal instruction (core dumped)
```

## Workaround: Use Alpine

The Alpine-based image uses musl libc instead of glibc and does not trigger the issue:

```bash
# Ubuntu (glibc) - FAILS
podman run --rm mcr.microsoft.com/dotnet/sdk:10.0 \
  sh -c 'dotnet new sln -n test && dotnet new classlib -n a && dotnet sln add a && dotnet build'

# Alpine (musl) - WORKS
podman run --rm mcr.microsoft.com/dotnet/sdk:10.0-alpine \
  sh -c 'dotnet new sln -n test && dotnet new classlib -n a && dotnet sln add a && dotnet build'
```

## Test Matrix

| Image | Mac | Result |
|-------|-----|--------|
| `sdk:10.0` (Ubuntu/glibc) | M5 | SIGILL (exit 132) |
| `sdk:10.0` (Ubuntu/glibc) | M2 | Success |
| `sdk:10.0-alpine` (musl) | M5 | Success |
| `sdk:10.0-alpine` (musl) | M2 | Success |

## Expected Behavior

`dotnet build` should succeed, as it does under Docker Desktop and on M2/M3 Macs with Podman.

## Suggested Fix

The Podman VM's kernel (or Apple Hypervisor.framework integration) should either:
1. Not advertise CPU features that the hypervisor cannot execute, or
2. Trap and emulate the unsupported instructions.

## Related

- This affects glibc-based containers, not musl (Alpine)
- The issue manifests more reliably with parallel builds (multiple MSBuild nodes)
- Environment variables like `DOTNET_EnableHWIntrinsic=0` do not fully mitigate the issue
