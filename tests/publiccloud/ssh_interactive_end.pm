# SUSE's openQA tests
#
# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: This test will leave the SSH interactive session, kill the SSH tunnel and destroy the public cloud instance
#
# Maintainer: Pavel Dostal <pdostal@suse.cz>

use Mojo::Base 'publiccloud::basetest';
use publiccloud::ssh_interactive 'select_host_console';
use publiccloud::utils;
use testapi;
use utils;

sub run {
    my ($self, $args) = @_;
    $self->{provider} = $args->{my_provider};    # required for cleanup
    select_host_console(force => 1);
    $args->{my_provider}->cleanup();
}

sub test_flags {
    return {fatal => 1, publiccloud_multi_module => 1};
}

1;