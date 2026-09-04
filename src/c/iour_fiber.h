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
 */
#ifndef IOUR_FIBER_H
#define IOUR_FIBER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* An execution context.  For a running/suspended fiber this holds the
 * saved stack pointer; for a scheduler it holds the shard thread's own
 * stack pointer.  Opaque to Ada apart from its size. */
typedef struct iour_ctx {
    void *sp;
} iour_ctx_t;

/* Switch execution from `from` to `to`.  Saves callee-saved state into
 * `from` and resumes whatever was saved in `to`.  Returns (on the `from`
 * context) only when somebody switches back to it. */
extern void iour_ctx_switch(iour_ctx_t *from, iour_ctx_t *to);

/* Allocate a fiber stack of `size` usable bytes with a PROT_NONE guard page
 * below it, so an overrun traps instead of corrupting a neighbour.
 * Returns the mapping base, or NULL on failure. */
extern void *iour_stack_alloc(size_t size);

/* Release a stack previously returned by iour_stack_alloc. */
extern void iour_stack_free(void *base, size_t size);

/* Prime `ctx` so that the next switch to it starts a fresh call of the Ada
 * procedure exported as "iour_fiber_main", passing `arg`, on the stack at
 * `base`/`size`.  Stacks outlive the fibers that run on them: a recycled
 * fiber slot re-primes rather than re-mmaps, keeping the per-connection cost
 * at zero syscalls. */
extern void iour_ctx_prime(iour_ctx_t *ctx, void *base, size_t size, long arg);

/* Bytes of guard page placed below every fiber stack. */
extern size_t iour_ctx_guard_size(void);

/* Size of iour_ctx_t, so the Ada side can assert its mirror type matches. */
extern size_t iour_ctx_size(void);

#ifdef __cplusplus
}
#endif
#endif /* IOUR_FIBER_H */
