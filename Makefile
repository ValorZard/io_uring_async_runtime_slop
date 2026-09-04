# io_uring async runtime for Ada/SPARK -- build, test and verification.
#
# The GNAT toolchain comes from Alire; env.sh puts it on PATH.

SHELL := /bin/bash
ENV   := source ./env.sh &&

.PHONY: all lib examples tests abi-check smoke demo prove prove-core clean help

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

bin:
	mkdir -p bin

smoke: tests abi-check
	./bin/smoke

# Server and client, 2000 simultaneous connections, 10 round trips each.
demo: examples
	./scripts/run_demo.sh

# Flow analysis over the whole runtime.  Reports the address-taking sites
# that fall outside SPARK's analysable subset; see the README.
prove:
	$(ENV) gnatprove -P prove.gpr --mode=flow -j0 --output=oneline || true

# Full proof of the subset that never hands an object's address to the
# kernel.  This one is expected to come back clean.
prove-core:
	$(ENV) gnatprove -P prove_core.gpr --mode=all --level=3 -j0 --report=all

clean:
	rm -rf obj lib bin

help:
	@echo "make examples    build the library, server and client"
	@echo "make smoke       build and run the runtime self-test"
	@echo "make demo        run server and client, 2000 connections"
	@echo "make abi-check   check the Ada kernel-ABI mirrors against the headers"
	@echo "make prove-core  SPARK proof of the address-free core (expected clean)"
	@echo "make prove       SPARK flow analysis of the whole runtime"
