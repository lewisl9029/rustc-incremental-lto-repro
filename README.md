# Interrupting a Rust build can silently corrupt the next one

Kill a `cargo build` partway through, and the **next** build can hand you a
binary that doesn't match your source code. Rebuilding doesn't fix it. Only
`cargo clean` does.

I hit this on a build server that cancels superseded jobs, spent a while
blaming my own code, and eventually traced it into rustc's incremental cache.
Putting a small repro here because it took me a bit to believe it.

## Try it

```bash
./repro.sh
```

Takes about 25 seconds. It does a normal build, changes one constant, hits the
rebuild with Ctrl-C (`SIGINT`) a few seconds in, puts the constant back exactly
as it was, and builds again:

```
[1/6] a normal, complete build, with SALT = 1
      src/salt.rs is 116376309895ae01
          Finished `release` profile [optimized] target(s) in 9.03s
      it prints 16 module checksums, starting m0 = 8027227160451771824
      rustc's finished session: s-hlxryh1yku-17z3j5t-92vtxg21i5yz55ikztx4cckw7
      holding 26 .pre-lto.bc files, which are now supposed to be read-only

[2/6] set SALT = 2, start a build, and kill it once it has written into
      that finished session
      SIGINT 3s in, after it has rewritten 17 of them

[3/6] what the killed build did to the session it was only supposed to read
      files whose contents changed: 17 of 26
      it is still the newest finished session, so it is what the next build reads

[4/6] put the source back to SALT = 1
      src/salt.rs is now 116376309895ae01, the same bytes step 1 built
          Finished `release` profile [optimized] target(s) in 1.95s

[5/6] run it
      1,17c1,17
      < SALT in the source = 1
      < m0 = 8027227160451771824
      < m1 = 11483241686877428696
      ...
      ---
      > SALT in the source = 2
      > m0 = 8999611603857640750
      > m1 = 16466921107442681377
      ...

[6/6] and it sticks: touch the source and build again
      still the same wrong binary
      (only 'cargo clean' clears it, which is how you know the source is fine)
```

The source says `SALT: u64 = 1`. `src/salt.rs` hashes to the same bytes it did
in step 1. The binary prints 2, and every checksum in it was computed with 2.

Step 5 isn't a stale binary sitting on disk, either. Cargo really does re-run
rustc, and rustc really does produce a fresh binary. It just builds part of it
out of code you deleted.

## What's going on

rustc keeps its incremental state in `target/<profile>/incremental/<crate>-<hash>/`,
one directory per finished build, named `s-<timestamp>-<random>-<hash>`. The
whole scheme is copy-on-write: the module docs in `rustc_incremental` say that
once a cache version is finalized it is "never modified", and that a later
session works on a copy.

Here's how the copy actually happens:

1. rustc picks the newest finished session and **hard links** every file in it
   into a fresh `s-...-working` directory. Hard links, so the two names are the
   same bytes on disk.
2. For each codegen unit it has to recompile, it writes `<unit>.pre-lto.bc`
   into the working directory with a plain `fs::write`. But that name is still
   a hard link to the finished session's file, so the finished session's bytes
   get overwritten too.
3. If the build finishes, no harm done. It seals its own session, which is
   newer and internally consistent, and the old one gets cleaned up. This is
   why nobody notices.
4. If the build dies first, its working directory is abandoned, and the
   session it damaged is left behind as the newest one.

That session is now a Frankenstein. Its dependency graph, its `.o` files and
its bookkeeping all describe the code you had. Some of its bitcode is the code
you were in the middle of building.

The next build reads it, decides those codegen units are unchanged, and reuses
them at the pre-LTO level, which means it hands that bitcode to LLVM and puts
the result in your binary. Nothing checks whether the bitcode still matches
what the rest of the session says it should be.

In this repro that's a silently wrong answer. On my build server it showed up
as a link failure instead (`undefined symbol: core::ptr::drop_in_place::<...>`),
which was at least loud about it. I'd assume you can get a crash too, depending
on what ends up mixed together.

## Does this affect me?

Only if your build writes `.pre-lto.bc` files at all, which needs three things
at once: incremental compilation on, optimizations on, and more than one
codegen unit. Measured on 1.98.0 with this crate:

| profile | `.pre-lto.bc` files | exposed |
| --- | --- | --- |
| `cargo build` (dev default, `opt-level = 0`) | 0 | no |
| `cargo build --release` (incremental off by default) | 0 | no |
| `[profile.dev] opt-level = 1` | 24 | **yes** |
| `[profile.dev] opt-level = 3` | 26 | **yes** |
| `[profile.release] incremental = true` | 26 | **yes** |
| `CARGO_INCREMENTAL=1 cargo build --release` | 26 | **yes** |
| the above, plus `codegen-units = 1` | 0 | no |
| the above, plus `lto = "off"` | 0 | no |

Both defaults are safe, which is probably why this isn't better known. But the
rows that aren't safe are pretty ordinary:

- `CARGO_INCREMENTAL=1` in CI, to stop paying for full release builds
- `[profile.dev] opt-level = 1` (or 3), the standard advice for anything with
  heavy dependencies — game engines, image and audio processing, crypto. Dev
  has incremental on by default, so that one line is enough on its own.
- `[profile.release] incremental = true`, for iterating on release builds

The interruption doesn't have to be dramatic either. Ctrl-C is enough — that's
what this repro sends by default. So is a CI job cancelled by the next push, an
OOM kill, a watch-mode tool restarting your build when you save again, or
closing your laptop at the wrong moment.

## If you think you've hit it

`cargo clean`, or delete `target/<profile>/incremental/`. There's no partial
fix, because a plain rebuild will happily keep reusing the damaged session.

To stay out of range, any one of these works: `codegen-units = 1`,
`lto = "off"`, or incremental off for your optimized profiles. All three just
mean rustc never writes the bitcode files in the first place.

## Where this lives in the compiler

- `rustc_incremental/src/persist/fs.rs`, `copy_files` — hard links the previous
  session into the working directory
- `rustc_codegen_ssa/src/back/write.rs`, `execute_optimize_work_item` —
  `fs::write`s `<unit>.pre-lto.bc` straight into the session directory
- `rustc_codegen_ssa/src/base.rs`, `determine_cgu_reuse` — an unchanged unit
  plus any kind of LTO means reuse from that bitcode

As far as I can tell this is unchanged from 1.94 through 1.98 and current
master. [rust-lang/rust#159287](https://github.com/rust-lang/rust/pull/159287)
would fix it as a side effect: it builds each session from scratch instead of
copying the previous one, and links reused bitcode in per unit. It's open,
motivated by an unrelated refactor, and its own description mentions that the
pre-LTO bitcode files aren't tracked accurately today.

## Tested on

| toolchain | platform | result |
| --- | --- | --- |
| 1.98.0 | aarch64-apple-darwin | reproduces |
| 1.98.0 | x86_64 linux (`rust:1.98-slim` in Docker) | reproduces |
| 1.97.1 | aarch64-apple-darwin | reproduces |
| 1.94.0 | aarch64-apple-darwin | reproduces |
| 1.94.1 | x86_64 linux | where I first hit it |

The checksums are plain wrapping `u64` arithmetic, so `SALT = 1` really does
compute `8027227160451771824` on every platform. If a build of this source
prints anything else for `m0`, that's the bug.

## About the crate

`src/filler.rs` expands to 1120 `#[inline(never)]` functions across 16 modules.
Nothing clever — it just has to take a few seconds to codegen so there's a
window to interrupt, and every function is seeded with `SALT` so that changing
that one constant dirties every codegen unit.

`repro.sh` watches the finished session's bitcode files and only sends the
signal once the running build has actually overwritten some of them, so you
aren't racing it by hand. If the build gets away from it, it cleans and retries,
up to three times. `SIGNAL=KILL ./repro.sh` for a hard kill instead of Ctrl-C,
and `CARGO="cargo +1.97.1" ./repro.sh` to pin a toolchain.
