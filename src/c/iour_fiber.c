/*  iour_fiber.c -- see iour_fiber.h */
#define _GNU_SOURCE
#include "iour_fiber.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

/* The Ada entry point every fiber starts in (exported from Iour.Fibers). */
extern void iour_fiber_main(long arg);

/* Called by the assembly trampoline with the fiber argument in rdi. */
void iour_fiber_entry_c(long arg);
void iour_fiber_entry_c(long arg)
{
    iour_fiber_main(arg);
    /* A fiber body must never fall off the end: Iour.Fibers always ends by
     * switching back to its scheduler.  Getting here means the invariant
     * was broken, and returning would `ret` into garbage. */
    abort();
}

#if defined(__x86_64__)

/*  --- x86-64 SysV ---------------------------------------------------------
 *  Callee-saved: rbx, rbp, r12, r13, r14, r15.  The fiber argument travels
 *  in r12 (callee-saved, so the pop sequence restores it for us).
 *
 *  Stack image prepared by iour_ctx_prime, low address first:
 *      sp+ 0 : r15   (0)
 *      sp+ 8 : r14   (0)
 *      sp+16 : r13   (0)
 *      sp+24 : r12   (arg)
 *      sp+32 : rbx   (0)
 *      sp+40 : rbp   (0)
 *      sp+48 : return address -> iour_fiber_trampoline
 *      sp+56 : unused, keeps the ABI alignment honest
 *  `sp` is 16-byte aligned, so after the six pops and the `ret` the
 *  trampoline starts with rsp % 16 == 8, exactly as a `call` would leave it.
 */
#define IOUR_CTX_FRAME 64
#define IOUR_CTX_RETSLOT 48
#define IOUR_CTX_ARGSLOT 24

__asm__(
    ".text\n"
    ".globl iour_ctx_switch\n"
    ".hidden iour_ctx_switch\n"
    ".type iour_ctx_switch,@function\n"
    ".align 16\n"
    "iour_ctx_switch:\n"
    "    pushq %rbp\n"
    "    pushq %rbx\n"
    "    pushq %r12\n"
    "    pushq %r13\n"
    "    pushq %r14\n"
    "    pushq %r15\n"
    "    movq  %rsp, (%rdi)\n"   /* from->sp = rsp */
    "    movq  (%rsi), %rsp\n"   /* rsp = to->sp   */
    "    popq  %r15\n"
    "    popq  %r14\n"
    "    popq  %r13\n"
    "    popq  %r12\n"
    "    popq  %rbx\n"
    "    popq  %rbp\n"
    "    ret\n"
    ".size iour_ctx_switch,.-iour_ctx_switch\n"

    ".globl iour_fiber_trampoline\n"
    ".hidden iour_fiber_trampoline\n"
    ".type iour_fiber_trampoline,@function\n"
    ".align 16\n"
    "iour_fiber_trampoline:\n"
    "    .cfi_startproc\n"
    "    .cfi_undefined rip\n"   /* stop unwinders here: this is a stack base */
    "    xorq  %rbp, %rbp\n"
    "    movq  %r12, %rdi\n"     /* arg */
    "    subq  $8, %rsp\n"       /* realign to 16 before the call */
    "    call  iour_fiber_entry_c\n"
    "    ud2\n"                  /* unreachable */
    "    .cfi_endproc\n"
    ".size iour_fiber_trampoline,.-iour_fiber_trampoline\n");

extern void iour_fiber_trampoline(void);

#elif defined(__aarch64__)

/*  --- AArch64 AAPCS -------------------------------------------------------
 *  Callee-saved: x19-x28, d8-d15, plus fp(x29) and lr(x30).
 *  Frame layout (low to high): x19..x28 (10), d8..d15 (8), fp, lr = 20 slots.
 *  The fiber argument travels in x19; lr points at the trampoline.
 */
#define IOUR_CTX_FRAME 160
#define IOUR_CTX_RETSLOT 152 /* lr */
#define IOUR_CTX_ARGSLOT 0   /* x19 */

__asm__(
    ".text\n"
    ".globl iour_ctx_switch\n"
    ".hidden iour_ctx_switch\n"
    ".type iour_ctx_switch,%function\n"
    ".align 4\n"
    "iour_ctx_switch:\n"
    "    sub  sp, sp, #160\n"
    "    stp  x19, x20, [sp, #0]\n"
    "    stp  x21, x22, [sp, #16]\n"
    "    stp  x23, x24, [sp, #32]\n"
    "    stp  x25, x26, [sp, #48]\n"
    "    stp  x27, x28, [sp, #64]\n"
    "    stp  d8,  d9,  [sp, #80]\n"
    "    stp  d10, d11, [sp, #96]\n"
    "    stp  d12, d13, [sp, #112]\n"
    "    stp  d14, d15, [sp, #128]\n"
    "    stp  x29, x30, [sp, #144]\n"
    "    mov  x9, sp\n"
    "    str  x9, [x0]\n"
    "    ldr  x9, [x1]\n"
    "    mov  sp, x9\n"
    "    ldp  x19, x20, [sp, #0]\n"
    "    ldp  x21, x22, [sp, #16]\n"
    "    ldp  x23, x24, [sp, #32]\n"
    "    ldp  x25, x26, [sp, #48]\n"
    "    ldp  x27, x28, [sp, #64]\n"
    "    ldp  d8,  d9,  [sp, #80]\n"
    "    ldp  d10, d11, [sp, #96]\n"
    "    ldp  d12, d13, [sp, #112]\n"
    "    ldp  d14, d15, [sp, #128]\n"
    "    ldp  x29, x30, [sp, #144]\n"
    "    add  sp, sp, #160\n"
    "    ret\n"
    ".size iour_ctx_switch,.-iour_ctx_switch\n"

    ".globl iour_fiber_trampoline\n"
    ".hidden iour_fiber_trampoline\n"
    ".type iour_fiber_trampoline,%function\n"
    ".align 4\n"
    "iour_fiber_trampoline:\n"
    "    mov  x29, #0\n"
    "    mov  x30, #0\n"
    "    mov  x0, x19\n"
    "    bl   iour_fiber_entry_c\n"
    "    brk  #1\n"
    ".size iour_fiber_trampoline,.-iour_fiber_trampoline\n");

extern void iour_fiber_trampoline(void);

#else
#error "iour_fiber.c: unsupported architecture (need x86-64 or aarch64)"
#endif

static size_t page_size(void)
{
    long p = sysconf(_SC_PAGESIZE);
    return (p > 0) ? (size_t)p : 4096u;
}

size_t iour_ctx_guard_size(void) { return page_size(); }
size_t iour_ctx_size(void) { return sizeof(iour_ctx_t); }

void *iour_stack_alloc(size_t size)
{
    const size_t page = page_size();
    size_t usable;
    unsigned char *base;

    if (size < 4 * page)
        return NULL;
    usable = (size + page - 1) & ~(page - 1);

    base = mmap(NULL, usable + page, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
    if (base == MAP_FAILED)
        return NULL;

    /* Lowest page becomes the guard. */
    if (mprotect(base, page, PROT_NONE) != 0) {
        munmap(base, usable + page);
        return NULL;
    }
    return base;
}

void iour_stack_free(void *base, size_t size)
{
    const size_t page = page_size();
    size_t usable;

    if (base == NULL)
        return;
    usable = (size + page - 1) & ~(page - 1);
    munmap(base, usable + page);
}

void iour_ctx_prime(iour_ctx_t *ctx, void *base, size_t size, long arg)
{
    const size_t page = page_size();
    size_t usable;
    unsigned char *top, *sp;

    if (ctx == NULL || base == NULL)
        return;
    usable = (size + page - 1) & ~(page - 1);

    /* Usable region starts one guard page above the mapping base. */
    top = (unsigned char *)base + page + usable;
    top = (unsigned char *)((uintptr_t)top & ~(uintptr_t)15);
    sp = top - IOUR_CTX_FRAME;

    memset(sp, 0, IOUR_CTX_FRAME);
    *(void **)(sp + IOUR_CTX_RETSLOT) = (void *)&iour_fiber_trampoline;
    *(long *)(sp + IOUR_CTX_ARGSLOT) = arg;

    ctx->sp = sp;
}
