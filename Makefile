# io_uring async runtime for Ada/SPARK -- build, test and verification.
# Pure Ada: the context switch is GNAT inline Asm.  gcc appears below only
# to compile the ABI conformance test, which is C on purpose -- it checks the
# Ada mirrors against the real headers.
#
# The GNAT toolchain comes from Alire; env.sh puts it on PATH.

SHELL := /bin/bash
ENV   := source ./env.sh &&

.PHONY: all lib examples tests abi-check smoke multi-await demo bench prove prove-boundary clean help

all: examples abi-check

lib:
	$(ENV) gprbuild -P io_uring_async_runtime.gpr -j0

examples: lib
	$(ENV) gprbuild -P examples.gpr -j0

tests: lib
	$(ENV) gprbuild -P tests.gpr -j0

# Fails to compile if any Ada mirror of the kernel ABI ever drifts from the
# system headers.
abi-check: | bin
	$(ENV) gcc -O2 -Wall -Wextra -o bin/abi_check tests/abi_check.c -luring
	./bin/abi_check

bin obj:
	mkdir -p $@

smoke: tests abi-check
	./bin/smoke

# Many futures and many awaits inside one procedure, and proof that the core
# changes hands at every one of those await points.
multi-await: tests
	./bin/multi_await

# Two phases: a small traced run showing what the scheduler is doing, then
# 2000 simultaneous connections for the throughput figure.
demo: examples
	./scripts/run_demo.sh

# The runtime's echo demo against the Tokio and Seastar equivalents: every
# server against every client, then each server alone across core counts, then
# latency.  Needs cargo, cmake, and Seastar's CMake prerequisites.  See the
# header of scripts/bench.sh
# for the knobs, and for why running it as root and unprivileged gives
# different answers.
bench: examples
	./scripts/bench.sh

# Full proof of everything
prove: 
	alr gnatprove -P io_uring_async_runtime.gpr --mode=all --level=3 -j0

clean:
	rm -rf obj lib bin

help:
	@echo "make examples        build the library, server and client"
	@echo "make smoke           build and run the runtime self-test"
	@echo "make multi-await     many awaits in one procedure; check the handover"
	@echo "make demo            traced walkthrough, then 2000 connections"
	@echo "make bench           benchmark Ada, Tokio, and Seastar echo servers"
	@echo "make abi-check       check the Ada kernel-ABI mirrors against the headers"
	@echo "make prove           SPARK proof of everything"
