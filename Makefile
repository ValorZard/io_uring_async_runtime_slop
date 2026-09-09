# io_uring / IoRing async runtime for Ada/SPARK -- build, test and
# verification.
#
# Pure Ada: the context switch is GNAT inline Asm.  gcc appears below only
# to compile the ABI conformance test, which is C on purpose -- it checks
# the Ada mirrors against the real Linux headers, and so only runs there.
#
# The GNAT toolchain comes from Alire; alr exec puts it on PATH.
#
# Both systems build with the same commands.  The project file picks the
# backend from the OS environment variable, which Windows sets for every
# process and no Unix does; override it with IOUR_OS if you need to.

SHELL := /bin/bash

# Windows builds get a .exe on every binary.  Nothing else below cares.
ifeq ($(OS),Windows_NT)
  EXE := .exe
  HOST := windows
else
  EXE :=
  HOST := linux
endif

.PHONY: all lib examples tests abi-check smoke multi-await demo demo-http bench \
        prove prove-consumers check-linux check-aarch64 clean help

all: examples abi-check

lib:
	alr exec -- gprbuild -P io_uring_async_runtime.gpr -j0

examples: lib
	alr exec -- gprbuild -P examples.gpr -j0

tests: lib
	alr exec -- gprbuild -P tests.gpr -j0

# Fails to compile if any Ada mirror of the kernel ABI ever drifts from the
# system headers.  Linux only: it is io_uring's UAPI that is being checked,
# and the Windows backend mirrors no structure the kernel owns -- IoRing's
# submission and completion queues are reached through calls, not memory.
abi-check: | bin
ifeq ($(HOST),linux)
	gcc -O2 -Wall -Wextra -o bin/abi_check tests/abi_check.c -luring
	./bin/abi_check
else
	@echo "abi-check: Linux only -- nothing to check against on $(HOST)"
endif

bin obj:
	mkdir -p $@

smoke: tests abi-check
	./bin/smoke$(EXE)

# Many futures and many awaits inside one procedure, and proof that the core
# changes hands at every one of those await points.
multi-await: tests
	./bin/multi_await$(EXE)

# Two phases: a small traced run showing what the scheduler is doing, then
# 2000 simultaneous connections for the throughput figure.
demo: examples
	./scripts/run_demo.sh

# One bounded HTTP request through the repository's own server and client.
# The server itself is intentionally unbounded, so the recipe owns its PID.
demo-http: examples
ifeq ($(HOST),windows)
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/demo_http.ps1
else
	@./bin/http_server$(EXE) > obj/http_server_demo.log 2>&1 & server=$$!; \
	trap 'kill $$server 2>/dev/null || true' EXIT; \
	until grep -q "listening on port" obj/http_server_demo.log; do sleep 0.05; done; \
	./bin/http_client$(EXE)
endif

# The runtime's echo demo against the Tokio and Go equivalents: every
# server against every client, then each server alone across core counts,
# then latency.  Needs cargo and go.  Runs on both systems, but Windows
# lacks the controls that make the numbers strictly comparable -- taskset,
# ip_local_port_range and ListenOverflows -- so read the Windows caveats in
# the header of scripts/bench.sh before comparing across systems.  That
# header also has the knobs, and why running it as root and unprivileged
# gives different answers on Linux.
bench: examples
	./scripts/bench.sh

# Full proof of everything.  The Linux backend is the one written in SPARK
# throughout; the Windows reactor is a trusted body, like the context
# switch, and is proved against its spec rather than through it.
prove:
	alr gnatprove -P io_uring_async_runtime.gpr --mode=all --level=3 -j0

# Proof of the library's *consumers*: the echo server and client, the smoke
# test and the await test, all of which are SPARK_Mode => On and none of
# which "make prove" ever looked at.
#
# This is the target that answers "can a program that uses this library be
# proved too", and it is not a formality.  Until it was first run the answer
# was no: Iour.Fibers.Spawn took an access-to-subprogram, and SPARK rejects
# 'Access of any subprogram with global effects -- which every fiber body
# has, since doing I/O is the point.  Every spawn site in this repository
# was illegal SPARK and nothing said so, because nothing asked.  See *Fiber
# bodies are numbers, not pointers* in CLAUDE.md.
#
# -U, and not by accident: without it gnatprove analyses only the units
# reachable from "for Main use", and multi_await.adb is not one of them --
# so the target silently skipped a quarter of what it claims to cover.
#
# Keep it green.  A consumer-visible API that only the library's own proof
# exercises will drift back out of SPARK without a single warning.
prove-consumers:
	alr gnatprove -P examples.gpr --mode=all --level=2 -j0 -U

# Compile the other system's backend without running it: catches anything
# that would only break over there, and needs no cross toolchain because
# nothing is generated.  Run it before pushing a change to shared code.
check-linux:
	alr exec -- gprbuild -P examples.gpr -XIOUR_OS=linux \
	  --subdirs=crosscheck -j0 -c -f -cargs -gnatc

# The AArch64 backend, checked without an AArch64 toolchain.  -gnatc is
# semantic analysis only -- no code generation -- so the host compiler
# does it, the same trick check-linux uses for the other backend.  It
# catches everything the language can catch, the static-string rule an
# Asm template has to meet included.
#
# What it cannot catch is whether the instruction text assembles: that
# needs a real aarch64 `as`, and so needs the VM.  The proof and the
# start-up render check cover the model; this covers the Ada.
check-aarch64:
	alr exec -- gprbuild -P examples.gpr -XIOUR_OS=linux \
	  -XIOUR_ARCH=aarch64 --subdirs=aarch64check -j0 -c -f -cargs -gnatc

clean:
	rm -rf obj lib bin

help:
	@echo "make examples        build the library, server and client"
	@echo "make smoke           build and run the runtime self-test"
	@echo "make multi-await     many awaits in one procedure; check the handover"
	@echo "make demo            traced walkthrough, then 2000 connections"
	@echo "make bench           benchmark Ada, Tokio, and Go echo servers"
	@echo "make abi-check       check the Ada kernel-ABI mirrors against the headers (Linux)"
	@echo "make check-linux     compile the Linux backend from anywhere"
	@echo "make check-aarch64   compile the AArch64 backend from anywhere"
	@echo "make prove           SPARK proof of the library"
	@echo "make prove-consumers SPARK proof of the examples and tests"
	@echo
	@echo "host detected as $(HOST)"
