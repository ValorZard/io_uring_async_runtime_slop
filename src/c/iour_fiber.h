/*  iour_fiber.h -- minimal stackful-coroutine primitive for the Ada runtime.
 *
 *  This is the ONLY piece of logic that cannot be expressed in Ada/SPARK:
 *  saving and restoring a machine context.  Everything else (scheduling,
 *  futures, the reactor, the run queues) lives in SPARK Ada.
 *
 *  The context switch is deliberately tiny: it saves the SysV callee-saved
 *  registers on the outgoing stack, stores the stack pointer, loads the
 *  incoming stack pointer and pops them back.  No signal mask is touched,
 *  so a switch costs a few tens of cycles rather than the ~1us that
 *  swapcontext(3) costs (it issues an rt_sigprocmask syscall per switch).
 *
 *  The contexts themselves live HERE rather than on the Ada side, and Ada
 *  names them by slot index.  That is not an arbitrary split.  A saved
 *  stack pointer is machine state whose only accessor is the assembly
 *  below; holding it in Ada bought nothing and cost a great deal, because
 *  an array Ada must hand out addresses into can be neither a protected
 *  object nor anything SPARK will let an access type designate.  Keeping
 *  it here puts the boundary where it belongs: Ada owns the scheduling
 *  decision -- which slot runs next -- and C owns what a context is.
 */
#ifndef IOUR_FIBER_H
#define IOUR_FIBER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* An execution context.  For a running or suspended fiber this holds the
 * saved stack pointer; for a scheduler it holds the shard thread's own
 * stack pointer.  Never named from Ada. */
typedef struct iour_ctx {
    void *sp;
} iour_ctx_t;

/* Allocate the slot table.  Idempotent, and succeeds if the table already
 * covers `slots`.  Returns 0 on success, -1 on failure.
 *
 * NOT thread safe by itself: the Ada side calls this from inside a
 * protected action, which supplies the mutual exclusion, and always before
 * any fiber exists. */
extern int iour_ctx_reserve(long slots);

/* How many slots are currently reserved. */
extern long iour_ctx_slots(void);

/* Switch execution from slot `from` to slot `to`.  Saves callee-saved
 * state into `from` and resumes whatever was saved in `to`.  Returns (on
 * the `from` context) only when somebody switches back to it.
 *
 * An out-of-range or self-directed slot returns without switching rather
 * than corrupting memory.  The Ada side never generates one. */
extern void iour_ctx_switch(long from, long to);

/* Allocate a fiber stack of `size` usable bytes with a PROT_NONE guard page
 * below it, so an overrun traps instead of corrupting a neighbour.
 * Returns the mapping base, or NULL on failure. */
extern void *iour_stack_alloc(size_t size);

/* Release a stack previously returned by iour_stack_alloc. */
extern void iour_stack_free(void *base, size_t size);

/* Prime slot `slot` so that the next switch to it starts a fresh call of
 * the Ada procedure exported as "iour_fiber_main", passing `arg`, on the
 * stack at `base`/`size`.  Stacks outlive the fibers that run on them: a
 * recycled fiber slot re-primes rather than re-mmaps, keeping the
 * per-connection cost at zero syscalls. */
extern void iour_ctx_prime(long slot, void *base, size_t size, long arg);

/* Bytes of guard page placed below every fiber stack. */
extern size_t iour_ctx_guard_size(void);

#ifdef __cplusplus
}
#endif
#endif /* IOUR_FIBER_H */
