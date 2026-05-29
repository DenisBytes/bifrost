package bifrost

import "base:intrinsics"

// Phase 8.4: Once. once_do(o, fn) runs fn at most once across all callers; later
// (and concurrent) calls block until the first fn has returned, then return
// without invoking their own fn. The fast path is a single atomic load on the
// hot side after the first call. Mirrors sync.Once (src/sync/once.go).
//
// DEVIATION from sync.Once: Go's is zero-value-usable (its embedded
// sync.Mutex is); bifrost's Once embeds a Mutex that requires explicit init,
// so Once needs once_init for the same reason. Functionally equivalent.

Once :: struct {
	done: u32,
	m:    Mutex,
}

// once_init prepares o for use. Must be called once before any once_do.
once_init :: proc(o: ^Once) {
	o.done = 0
	mutex_init(&o.m)
}

// once_do runs fn exactly once per Once, regardless of how many callers
// invoke it. Other callers block until the running call finishes, then return.
once_do :: proc(o: ^Once, fn: proc()) {
	// Fast path: if we've already run, no lock, no work.
	if intrinsics.atomic_load(&o.done) != 0 {
		return
	}
	once_do_slow(o, fn)
}

// once_do_slow is the contended path: take the mutex, recheck done under it,
// run fn if we won, then mark done. The defer pair sets done even if fn panics
// (so subsequent once_do calls don't retry on the panicked path) and always
// releases the mutex. Mirrors Go's Once.doSlow (src/sync/once.go).
@(private)
once_do_slow :: proc(o: ^Once, fn: proc()) {
	mutex_lock(&o.m)
	defer mutex_unlock(&o.m)
	if intrinsics.atomic_load(&o.done) == 0 {
		// Order matters: defers fire LIFO, so the "set done" defer runs BEFORE
		// the mutex unlock. A panic in fn still marks done — sync.Once
		// guarantees fn is never re-attempted, even after a panic.
		defer intrinsics.atomic_store(&o.done, u32(1))
		fn()
	}
}
