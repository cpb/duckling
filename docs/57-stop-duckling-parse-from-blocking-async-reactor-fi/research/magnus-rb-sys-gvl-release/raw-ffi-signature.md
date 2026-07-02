# The Raw `rb_thread_call_without_gvl` FFI Surface

This document verifies, against real source, exactly what's available for
releasing the GVL from this gem's native extension: the C API itself, how
`rb-sys` 0.9.128 exposes it in Rust, and the safety rules that apply when
calling it from inside `magnus` 0.8.2.

## Magnus 0.8.2 has no safe wrapper

Magnus's crate-level "C Function Index" doc comment (a plain `//` comment
block, not part of the published rustdoc) lists these three functions as
explicitly unimplemented, alongside the Magnus API that *would* back them if
they existed:

```
// * `rb_thread_call_without_gvl`:
// * `rb_thread_call_without_gvl2`:
// * `rb_thread_call_with_gvl`:
```

— [`magnus/src/lib.rs`](https://github.com/matsadler/magnus/blob/0.8.2/src/lib.rs#L1509-L1511)
(these three lines sit among ~20 other `rb_thread_*` entries; everything
else in that neighborhood — `rb_thread_alone`, `rb_thread_check_ints`,
`rb_thread_create`, `rb_thread_current`, `rb_thread_fd_close`,
`rb_thread_fd_writable`, `rb_thread_interrupted`, `rb_thread_kill`,
`rb_thread_local_aref`/`aset` — *is* implemented, as `//!` doc-comment
entries pointing at real `Ruby::thread_*` / `Thread::*` methods).

[`magnus/src/thread.rs`](https://github.com/matsadler/magnus/blob/0.8.2/src/thread.rs)
confirms this by omission: it backs exactly those implemented entries
(`thread_create`, `thread_create_from_fn`, `thread_current`, `thread_main`,
`thread_schedule`, `thread_wait_fd`, `thread_fd_writable`, `thread_fd_close`,
`thread_alone`, `thread_sleep`/`thread_sleep_forever`/`thread_sleep_deadly`,
`thread_stop`, `thread_check_ints`) and nothing GVL-release related.

`Ruby::thread_create_from_fn` is the closest existing analog — it's worth
noting *why* it doesn't solve this problem: it spawns a genuine Ruby
`Thread` (which itself contends for the GVL like any other Ruby thread) to
run a Rust closure; it does not release the GVL around a call happening on
the *current* thread. It's also useful as a reference for one thing this
document's sketch borrows from it: the pattern of boxing a closure/payload,
handing `Box::into_raw` across an `extern "C"` boundary as `*mut c_void`,
and reconstituting it with `Box::from_raw` on the other side (see
[`thread.rs`'s `wrap_closure`](https://github.com/matsadler/magnus/blob/0.8.2/src/thread.rs)).
One difference matters for the sketch in
[implementation-sketch.md](implementation-sketch.md): `thread_create_from_fn`'s
`func` parameter has a compiler-enforced `F: 'static + Send + FnOnce(&Ruby) -> R`
bound. `rb_thread_call_without_gvl`'s `func` is a plain C function pointer
(see below) — there is no such compiler-enforced bound; `Send`-safety of
whatever the callback touches is the caller's responsibility to reason
about, not something the type system checks for you.

## The verified C signature

Ruby's own header ([`ruby/thread.h`](https://github.com/ruby/ruby/blob/v3_3_6/include/ruby/thread.h),
matching the actual installed header this repo's toolchain builds against)
declares:

```c
void *rb_thread_call_with_gvl(void *(*func)(void *), void *data1);

void *rb_thread_call_without_gvl(void *(*func)(void *), void *data1,
                                 rb_unblock_function_t *ubf, void *data2);

void *rb_thread_call_without_gvl2(void *(*func)(void *), void *data1,
                                  rb_unblock_function_t *ubf, void *data2);

void *rb_nogvl(void *(*func)(void *), void *data1,
               rb_unblock_function_t *ubf, void *data2,
               int flags);
```

`rb_thread_call_without_gvl`'s doc comment describes its five-step
behavior verbatim:

> Allows the passed function to run in parallel with other Ruby threads.
> What this function does:
> 1. Checks (and handles) pending interrupts.
> 2. Releases the GVL. (Others can run here in parallel...)
> 3. Calls the passed function.
> 4. Blocks until it re-acquires the GVL.
> 5. Checks interrupts that happened between 2 to 4.
>
> **@warning** You cannot use most of Ruby C APIs like calling methods or
> raising exceptions from any of the functions passed to it. If that is
> dead necessary use `rb_thread_call_with_gvl()` to re-acquire the GVL.
> **@warning** In short, this API is difficult. @ko1 recommends you to use
> other ways if any. We lack experiences to use this API.
> **@warning** Releasing and re-acquiring the GVL are expensive operations.
> For a short-running `func`, it might be faster to just call `func` with
> blocking everything else. Be sure to benchmark your code to see if it is
> actually worth releasing the GVL.

Point 4 matters for the sketch: **the GVL is reacquired before
`rb_thread_call_without_gvl` returns to its caller.** The `parse` function
in `ext/duckling/src/lib.rs` can safely resume touching Ruby `Value`s
(building the `RArray`) as soon as the call returns — no `rb_thread_call_with_gvl`
round-trip is needed for that, only for calling *back into Ruby from inside
the off-GVL callback itself*, which this use case doesn't need to do.

`rb_thread_call_without_gvl2` is identical except it does not check/handle
interrupts and returns immediately if one is pending (leaving progress
tracking to the caller) — not relevant here since `duckling::parse` isn't
resumable. `rb_nogvl` is the same primitive with an additional `flags`
argument (`RB_NOGVL_INTR_FAIL`, `RB_NOGVL_UBF_ASYNC_SAFE`) for cases that
need finer control; plain `rb_thread_call_without_gvl` is the right choice
here.

### `rb_unblock_function_t` (the `ubf` parameter)

Declared in
[`ruby/internal/intern/thread.h`](https://github.com/ruby/ruby/blob/v3_3_6/include/ruby/internal/intern/thread.h#L336):

```c
typedef void rb_unblock_function_t(void *);
```

This is a **cancellation hook**, not a periodic polling callback — it is
invoked (from another OS thread, asynchronously) only if some other Ruby
thread calls `Thread#raise` or `Thread#kill` against the thread that's
currently blocked inside `rb_thread_call_without_gvl`, so that the blocking
operation has a chance to unblock itself (e.g. by closing a file descriptor
a blocking `read(2)` is waiting on). It does not fire automatically or
repeatedly while `func` runs. Passing `NULL` (`None` in Rust, see below)
means there is no way to interrupt the call from outside — it will run to
completion. See the "Open follow-ups" section of the parent
[README.md](README.md) for why the implementation sketch here intentionally
leaves this as `None` rather than trying to implement a real `ubf`.

### The exact generated Rust signature (verified against this repo's own build)

`rb-sys`'s `src/bindings.rs`
([`rb-sys/src/bindings.rs`](https://github.com/oxidize-rb/rb-sys/blob/v0.9.128/crates/rb-sys/src/bindings.rs)
— note the repo is a Cargo workspace, so the published `rb-sys` crate's
source lives under `crates/rb-sys/`, not at the repo root)
is a thin wrapper around a single line —
`include!(env!("RB_SYS_BINDINGS_PATH"));` — pulling in bindings that
`rb-sys-build` generates from the *actual installed Ruby headers* at
extension-build time, per Ruby version, via `bindgen`. That means the raw
signature isn't fixed text in the crate's own source tree; it has to be
checked against a real generated-bindings file. This repo already has one
on disk from a prior local build
(`target/release/build/rb-sys-*/out/bindings-0.9.128-mri-x86_64-darwin24-3.3.6.rs`,
generated against the Ruby 3.3.6 toolchain), and it matches the header
above exactly:

```rust
pub type rb_unblock_function_t =
    ::std::option::Option<unsafe extern "C" fn(arg1: *mut ::std::os::raw::c_void)>;

pub fn rb_thread_call_without_gvl(
    func: ::std::option::Option<
        unsafe extern "C" fn(
            arg1: *mut ::std::os::raw::c_void,
        ) -> *mut ::std::os::raw::c_void,
    >,
    data1: *mut ::std::os::raw::c_void,
    ubf: rb_unblock_function_t,
    data2: *mut ::std::os::raw::c_void,
) -> *mut ::std::os::raw::c_void;
```

Two details this confirms that a reading of the C header alone wouldn't
make obvious:

- `bindgen` wraps the raw C function pointers in `Option<...>` (its usual
  convention for C function-pointer types), so a real callback is passed as
  `Some(callback)`, and "no `ubf`" is passed as plain `None` — no manual
  null-pointer cast needed for either the `func` or `ubf` argument.
- `rb_unblock_function_t` itself is `Option<unsafe extern "C" fn(*mut c_void)>`
  — no return value — distinct from `func`'s type, which does return
  `*mut c_void`. (Magnus's own crate doc, quoted above, calls out this same
  asymmetry as "an implementation detail... [that] must be a mistake to be
  here" in its own copy of this generated doc comment — a Ruby-upstream
  oddity, not something to fix on our side.)

Because [`rb-sys`'s `src/lib.rs`](https://github.com/oxidize-rb/rb-sys/blob/v0.9.128/crates/rb-sys/src/lib.rs)
does `pub mod bindings; ... pub use bindings::*;` **unconditionally** — not
gated behind the `stable-api` feature (only the separate ABI-stability
macros in `src/stable_api.rs` are feature-gated) —
`rb_sys::rb_thread_call_without_gvl` is reachable today through this gem's
existing `Cargo.toml`:

```toml
rb-sys = { version = "*", default-features = false, features = ["stable-api-compiled-fallback"] }
```

No dependency or feature changes are required to write the sketch in
[implementation-sketch.md](implementation-sketch.md).

## Magnus's documented escape hatch: `magnus::rb_sys`

Magnus 0.8.2 ships a
[`magnus::rb_sys`](https://github.com/matsadler/magnus/blob/0.8.2/src/rb_sys.rs)
module specifically for gaps like this one. Its module doc explains when to
reach for it:

> These functions are provided to interface with the lower-level Ruby
> bindings provided by rb-sys. You may want to use rb-sys when:
> 1. Magnus does not provide access to a Ruby API because the API can not
>    be made safe & ergonomic.
> 2. Magnus exposed the API in a way that does not work for your use case.
> 3. The API just hasn't been implemented yet.

It exposes:

- **`AsRawValue` / `FromRawValue`** — convert a Magnus `Value` to/from a raw
  `rb_sys::VALUE`. Not needed for this use case: no `Value` needs to cross
  the off-GVL boundary at all (see below).
- **`protect<F>(func: F) -> Result<VALUE, Error> where F: FnOnce() -> VALUE`**
  — wraps a raw call in `rb_protect`, catching Ruby-side unwinds (exceptions,
  `throw`, `break`, `next`, `return` from a block) as an `Error`. Not
  applicable off-GVL either — `rb_protect` itself calls into the Ruby VM,
  which per the C header's own warning is exactly what you cannot safely do
  from inside a `rb_thread_call_without_gvl` callback.
- **`catch_unwind<F, T>(func: F) -> Result<T, Error> where F: FnOnce() -> T + UnwindSafe`**
  — the Rust-panic-catching counterpart. Doc comment: *"This should not be
  used to catch and discard panics... can be used to ensure Rust panics do
  not cross over to Ruby... All functions exposed by Magnus that allow Ruby
  to call Rust code already use this internally, this should only be
  required to wrap functions/closures given directly to rb-sys."* This is
  exactly the situation the off-GVL callback is in — see the panic-safety
  section below for how (and, importantly, how *not*) to use it there.
- **`resume_error(e: Error) -> !`** — re-raises a previously `protect`-caught
  error. Also VM-touching; not usable off-GVL.

## Panic safety: why the guard is required in every build profile, not just as defense-in-depth

[duckling](https://github.com/wafer-inc/duckling)'s own `parse` function
(verified at
[`wafer-inc/duckling@c96b068`, `src/lib.rs`](https://github.com/wafer-inc/duckling/blob/c96b0681ab9a097712b20fe838786a2c65efc537/src/lib.rs#L73-L99),
matching the `duckling = "0.4"` / resolved `0.4.0` this gem depends on)
wraps its internal `parse_inner` call in `std::panic::catch_unwind`, but
**only when `#[cfg(not(debug_assertions))]`**:

```rust
pub fn parse(
    text: &str,
    locale: &Locale,
    dims: &[DimensionKind],
    context: &Context,
    options: &Options,
) -> Vec<Entity> {
    #[cfg(debug_assertions)]
    {
        parse_inner(text, locale, dims, context, options)
    }

    #[cfg(not(debug_assertions))]
    {
        match catch_unwind(AssertUnwindSafe(|| {
            parse_inner(text, locale, dims, context, options)
        })) {
            Ok(entities) => entities,
            Err(payload) => {
                log::error!("duckling::parse panicked: {}", panic_payload_message(&payload));
                Vec::new()
            }
        }
    }
}
```

This is a `debug_assertions` check, not literally a `cfg!(release)` check —
and this repo's own `.env.local.example` sets `RB_SYS_CARGO_PROFILE=dev` as
the *local development default* (see the root `AGENTS.md`'s "Build and test
commands" section). Cargo's `dev` profile enables `debug-assertions = true`
by default, meaning **in ordinary local development builds,
`duckling::parse` does not catch its own panics** — only `bundle exec rake`
in CI and `rake release` (which never see `.env.local`) get
[duckling](https://github.com/wafer-inc/duckling)'s internal guard for
free. Whatever wraps the off-GVL call therefore needs
its own panic guard unconditionally, not merely as redundant
defense-in-depth for release builds.

### A subtlety worth getting right: don't let `magnus::rb_sys::catch_unwind`'s error path do VM work off-GVL

A naive first pass would wrap the inner call directly in
`magnus::rb_sys::catch_unwind`, inside the off-GVL callback, and store the
resulting `Result<Vec<Entity>, magnus::Error>` in the payload. This was
checked against `magnus::rb_sys::catch_unwind`'s real implementation
([`rb_sys.rs`](https://github.com/matsadler/magnus/blob/0.8.2/src/rb_sys.rs)):

```rust
pub fn catch_unwind<F, T>(func: F) -> Result<T, Error>
where
    F: FnOnce() -> T + UnwindSafe,
{
    std::panic::catch_unwind(func).map_err(Error::from_panic)
}
```

On the `Err` path this calls
[`Error::from_panic`](https://github.com/matsadler/magnus/blob/0.8.2/src/error.rs#L292-L306):

```rust
pub(crate) fn from_panic(e: Box<dyn Any + Send + 'static>) -> Self {
    let msg = /* downcast e to &str or String, else "panic" */;
    Self(ErrorType::Error(
        unsafe { Ruby::get_unchecked().exception_fatal() },
        msg,
    ))
}
```

`Ruby::get_unchecked()` is just an unchecked `PhantomData` marker
construction (no VM interaction), and
[`exception_fatal()`](https://github.com/matsadler/magnus/blob/0.8.2/src/exception.rs#L386-L388)
turns out to be a plain read of Ruby's `rb_eFatal` global — declared in
Ruby's own headers as
[`RUBY_EXTERN VALUE rb_eFatal;`](https://github.com/ruby/ruby/blob/v3_3_6/include/ruby/internal/globals.h#L114),
a permanently-rooted singleton class object that's immortal for the life of
the process (never GC'd, never moved). So, verified: calling
`magnus::rb_sys::catch_unwind` itself off-GVL does not, in this specific
case, call into the Ruby VM or allocate a Ruby object on its error path —
it's not the outright unsafety the C header's blanket warning ("you cannot
use most of Ruby C APIs... from any of the functions passed to it") might
suggest at first read.

That said, the sketch in [implementation-sketch.md](implementation-sketch.md)
still deliberately avoids storing a `magnus::Error` (or any other
Magnus/Ruby type) in the boxed payload that crosses the off-GVL boundary,
in favor of a plain `Option<String>` panic message, for two reasons
independent of the point above:

1. It keeps the invariant "the payload holds only fully-owned Rust data,
   zero Ruby `Value`s or Magnus wrapper types, in either direction" simple
   and mechanically checkable, rather than resting on the fact that this
   *particular* global happens to be immortal — a property of Ruby's
   internals, not something this crate's code visibly enforces.
2. It matches this project's own established rule from prior incident
   review: never stash a bare `magnus::Value` (or a type that wraps one) in
   a Rust `Vec`/`Box`/struct across Magnus call boundaries — a real
   GC-safety bug here previously caused a segfault. `magnus::Error`'s
   `ErrorType::Error` variant embeds an `ExceptionClass`, which wraps a
   `Value`; keeping it out of the payload entirely sidesteps needing to
   re-litigate that rule for this one field.

Actual exception construction/raising (`Error::new(...)`, which *does*
allocate) happens only after `rb_thread_call_without_gvl` returns and the
GVL is confirmed held again — see the sketch.
