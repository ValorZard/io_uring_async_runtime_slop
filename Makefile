# io_uring async runtime for Ada/SPARK -- build, test and verification.
#
# The GNAT toolchain comes from Alire; env.sh puts it on PATH.

SHELL := /bin/bash
ENV   := source ./env.sh &&

.PHONY: all lib examples tests abi-check smoke demo prove prove-boundary clean help

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

# Two phases: a small traced run showing what the scheduler is doing, then
# 2000 simultaneous connections for the throughput figure.
demo: examples
	./scripts/run_demo.sh

# Full proof of everything inside SPARK's analysable subset.  Expected to
# come back clean: zero unproved checks, zero warnings.
#
# gnatprove reports on stderr, and narrates every inlined call and unrolled
# loop as an "info:" line.  Those are filtered so what remains is what needs
# a human; the exit status is gnatprove's own.
prove: | obj
	@$(ENV) gnatprove -P prove_core.gpr --mode=all --level=2 -j0 --output=oneline \
	  > obj/prove_core.log 2>&1; status=$$?; \
	  grep -v "info:" obj/prove_core.log || true; \
	  grep -A14 "Summary of SPARK analysis" obj/prove_core/gnatprove/gnatprove.out; \
	  exit $$status

# Flow analysis over the WHOLE runtime, including the three bodies that must
# hand an object's address to the kernel.  Expected to end in "error during
# analysis": its purpose is to list exactly those sites, one line each.
prove-boundary: | obj
	@$(ENV) gnatprove -P prove.gpr --mode=flow -j0 --output=oneline \
	  > obj/prove_boundary.log 2>&1; \
	  grep -vE "info:|violation of aspect SPARK_Mode|launch \"gnatprove --explain|^Phase|Summary logged" \
	    obj/prove_boundary.log || true

clean:
	rm -rf obj lib bin

help:
	@echo "make examples        build the library, server and client"
	@echo "make smoke           build and run the runtime self-test"
	@echo "make demo            traced walkthrough, then 2000 connections"
	@echo "make abi-check       check the Ada kernel-ABI mirrors against the headers"
	@echo "make prove           SPARK proof of everything analysable (expected clean)"
	@echo "make prove-boundary  list the sites outside SPARK's subset (expected to error)"
