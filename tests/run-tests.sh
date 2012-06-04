#!/bin/sh

# Run the regression tests in this directory.
#
# Usage: run-tests.sh [OPTIONS] [files]
#
# Valid options are as follows:
#
#  --break-on-failure            Break into the debugger when a test fails
#                                unexpectedly
#  --break-on-expected-failure   Break into the debugger when any test fails
#  --report-skipped-tests        Include tests :skipped-on target SBCL in
#                                the test report.
#  --random-seed <number>        Use the specified hexadecimal integer to seed
#                                the random number generator before running
#                                each test. See below for when to use this.
#
# If no test files are specified, runs all tests.
#
# Note on --random-seed:
#   Normally, this option is not specified. The script then determines
#   a random number when started (different each time) and uses that to
#   seed the random number generator before running each test. This way
#   tests using random numbers cover more ground. At the end of the test
#   run the number is printed out. Rerunning the script with
#   --random-seed and this number specified allows one to reproduce
#   failures or unexpected successes if they depend on the specific
#   random values. Reproduction on a different machine requires that
#   platform and wordsize are identical and the SBCL version does not
#   differ so much that there has been a change to the random number
#   generator inbetween.

# This software is part of the SBCL system. See the README file for
# more information.
#
# While most of SBCL is derived from the CMU CL system, the test
# files (like this one) were written from scratch after the fork
# from CMU CL.
#
# This software is in the public domain and is provided with
# absolutely no warranty. See the COPYING and CREDITS files for
# more information.

. ./subr.sh

echo /running tests on \'$SBCL_RUNTIME --core $SBCL_CORE $SBCL_ARGS\'

tenfour () {
    if [ $1 = $EXIT_TEST_WIN ]; then
        echo ok
    else if [ $1 = 105 ]; then
        echo no tests run, check script options and arguments
        exit 1
    fi
        echo test failed, expected $EXIT_TEST_WIN return code, got $1
        exit 1
    fi
}
set +u
run_sbcl \
    --eval '(with-compilation-unit () (load "run-tests.lisp"))' \
    --eval '(run-tests::run-all)' $*

tenfour $?

echo '//apparent success (reached end of run-tests.sh normally)'
date
