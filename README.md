# azure_sdk_core_symcrypt

Optional Microsoft SymCrypt 103.13.0 provider for
`azure_sdk_core.crypto.CryptoProvider`.

- Package version: `0.2.0`
- Release branch: `sdk/core_symcrypt`
- Core dependency: `azure_sdk_core` `0.4.0`
- Native wrapper dependency: `zig_symcrypt` `0.1.0`
- Supported targets: `x86_64-linux-gnu`, `aarch64-linux-gnu`,
  `x86_64-windows-msvc`, and `aarch64-windows-msvc`

This package is optional. Applications that use only `azure_sdk_core` do not
compile or link any C or SymCrypt symbols.

## Scope

The provider supplies secure random bytes, compatibility-only MD5, SHA-256,
HMAC-SHA256, and allocator-backed incremental SHA-256. It changes Azure SDK
hashing, integrity headers, and signing selected through `CryptoProvider`.

It **does not** replace the TLS cryptography or X.509 trust implementation
beneath `std.http.Client`. Selecting this package therefore does not make
`std.http.Client` TLS use SymCrypt.

MD5 is enabled in `zig_symcrypt` only because Azure Storage compatibility and
integrity paths require it. The adapter does not expose SHA-1 or legacy RSA.
MD5 must not be used as a security primitive.

## Provider API

```zig
const core_symcrypt = @import("azure_sdk_core_symcrypt");

var provider = try core_symcrypt.Provider.init();
defer provider.deinit();

const crypto_provider = provider.asProvider();
const digest = try crypto_provider.sha256("payload");
_ = digest;
```

`Provider` is single-owner and must not move after `asProvider`. Copyable Core
descriptors borrow it and are valid until `deinit`; calls after deinitialization
return `error.ProviderDeinitialized` while the owner storage remains alive.
`deinit` must not race an operation. Hash/HMAC/default random calls are
concurrent-safe. `initWithScratchAllocator` is also concurrent-safe only when
its borrowed random staging allocator supports concurrent allocation.

Incremental SHA-256 owns separate state allocated with the allocator supplied
to `CryptoProvider.sha256Init`. It remains valid if the provider is later
deinitialized, rejects update/final after finalization, and wipes both adapter
and SymCrypt state before freeing it. Call its `deinit` exactly once.

Initialization and primitive errors are returned unchanged. There is no
`std.crypto` fallback. Digest, MAC, and random results are staged so a failed
operation cannot expose partial caller output. Random staging allocation
failure is returned as `error.OutOfMemory`.

Dynamic initialization performs the recoverable SymCrypt API/minor handshake.
Static initialization follows upstream's process-global contract; a mismatched
static archive/header combination can terminate the process. Neither arbitrary
static builds nor this adapter are claims of FIPS validation.

## Build integration

A final application selects linkage and forwards exact native inputs when it
creates the package dependency:

```zig
const adapter = b.dependency("azure_sdk_core_symcrypt", .{
    .target = target,
    .optimize = optimize,
    .linkage = .dynamic, // or .static
    .symcrypt_libraries = libraries,
    .symcrypt_include_dir = include_dir,
    .symcrypt_system_include_dirs = system_include_dirs,
    .symcrypt_checked = false,
    .symcrypt_provenance = provenance,
});
root_module.addImport(
    "azure_sdk_core_symcrypt",
    adapter.module("azure_sdk_core_symcrypt"),
);
```

Options are forwarded to the pinned `zig_symcrypt` build:

- `linkage`: `dynamic` or `static`.
- `symcrypt_libraries`: ordered, repeated exact library files.
- `symcrypt_include_dir`: complete SymCrypt 103.13.0 public headers; omitted
  uses the exact headers bundled by pinned `zig_symcrypt`.
- `symcrypt_system_include_dirs`: ordered SDK/CRT paths for explicit
  cross-toolchains.
- `symcrypt_checked`: `true` only when headers and every library use the
  checked/`DBG` ABI; default `false` is FRE.
- `symcrypt_provenance`: exact fixture manifest used to verify source identity,
  target, roles/order, architecture, and SHA-256 hashes. Windows dynamic
  execution also verifies and stages the manifest-bound runtime DLL.
- `headers_only`: supported-target adapter/header compilation without native
  linkage.
- `target_can_run`: permits execution when the runner is native for the target
  but the Zig compiler process is another architecture under emulation.
- `source_only`: package and formatting checks without configuring SymCrypt;
  intended for macOS and other non-native validation hosts.

The adapter always forwards `legacy=true`,
`enable_legacy_rsa_pkcs1_encryption=false`, `enable_mlkem=false`, and
`enable_tls_x25519_mlkem768=false`. Consumers cannot broaden this adapter's
legacy surface.

### Exact library order

Linux dynamic:

1. `libsymcrypt_plus.a`
2. `libsymcrypt.so` or its exact versioned file

Linux static:

1. `libsymcrypt_plus.a`
2. `libsymcrypt_posixusermode.a`
3. `libsymcrypt_common.a`
4. `libsymcrypt_mlkem.a`

Windows dynamic:

1. `symcrypt_plus_NoCIL.lib`
2. import library for `symcrypt_zig_103_13.dll` (never pass the DLL as a link
   input)

Windows static:

1. `symcrypt_plus_NoCIL.lib`
2. `symcrypt_static_NoCIL.lib`

Linux dynamic applications must provide the exact SONAME through an
application rpath or controlled loader configuration. Windows dynamic
applications must verify and place the exact manifest-bound
`symcrypt_zig_103_13.dll` beside the executable.

## Validation

Native commands require exact libraries and provenance:

```bash
zig build provenance-check [linkage and fixture options]
zig build test [linkage and fixture options] --summary all
zig build example-run [linkage and fixture options]
zig build package-consumer-check [linkage and fixture options]
```

Build-only and source checks:

```bash
zig build test-compile [linkage and fixture options] --summary all
zig build headers-check -Dheaders_only=true [header options]
zig build source-check -Dsource_only=true
zig build package-check -Dsource_only=true --summary all
```

macOS and all unlisted native targets fail with a diagnostic naming the four
supported triples. They can still run `source-check` and `package-check` with
`-Dsource_only=true`.

Package CI builds SymCrypt from Microsoft tag `v103.13.0`, commit
`286762b7730e2b780678f5ab11fef2b1bad639e0`, with the pinned Jitterentropy
gitlink. It uses the released `zig_symcrypt` fixture builders and provenance
verification rather than downloading opaque native binaries.
