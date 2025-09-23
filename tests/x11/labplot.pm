# SUSE's openQA tests
#
# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: LabPlot
# Summary: Plasma LabPlot startup test
# Maintainer: Felix Niederwanger <felix.niederwanger@suse.de>

use base 'x11test';
use testapi;

sub run {
    ensure_installed('labplot');

    x11_start_program('labplot');

    ## TODO: Add needle for program and close program.
}

1;
