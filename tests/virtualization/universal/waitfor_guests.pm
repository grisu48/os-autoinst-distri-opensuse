# XEN regression tests
#
# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: libvirt-client
# Summary: Wait for guests so they finish the installation
# Maintainer: Pavel Dostál <pdostal@suse.cz>, Felix Niederwanger <felix.niederwanger@suse.de>

use base 'consoletest';
use virt_autotest::common;
use virt_autotest::utils;
use strict;
use warnings;
use testapi;
use utils;
use version_utils 'is_sle';

sub run {
    my $self = shift;
    select_console('root-console');
    my @guests = keys %virt_autotest::common::guests;
    # Fill the current pairs of hostname & address into /etc/hosts file
    assert_script_run 'virsh list --all';
    add_guest_to_hosts $_, $virt_autotest::common::guests{$_}->{ip} foreach (@guests);
    assert_script_run "cat /etc/hosts";

    # Wait for guests to announce that installation is complete
    script_retry("test -d /tmp/guests_ip", retry => 15, delay => 120);
    foreach my $guest (@guests) {
        script_retry("test -f /tmp/guests_ip/$guest", retry => 20, delay => 120);
        record_info("$guest installed", "Guest installation completed");
    }
    record_info("All guests installed", "Guest installation completed");
    if (is_sle('>15') && get_var("KVM")) {
        # Adding the PCI bridges requires the guests to be shutdown
        record_info("shutdown guests", "Shutting down all guests");
        shutdown_guests();

        # Add a PCIe root port and a PCIe to PCI bridge for Q35 machine
        if (is_sle('<15-SP4')) {
            assert_script_run("virt-xml $_ --add-device --controller type=pci,index=11,model=pcie-to-pci-bridge") foreach (@guests);
        } else {
            assert_script_run("virt-xml $_ --add-device --controller type=pci,model=pcie-to-pci-bridge") foreach (@guests);
        }
        record_info("Starting guests", "Starting all guests");
        start_guests();
        ensure_online $_, skip_ssh => 1, ping_delay => 45 foreach (@guests);
    }
    assert_script_run('virsh list --all');
    wait_still_screen 1;
}

sub post_fail_hook {
    my ($self) = @_;
    collect_virt_system_logs();
    $self->SUPER::post_fail_hook;
}

1;