# SUSE's openQA tests
#
# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: NVIDIA helper functions
# Maintainer: Kernel QE <kernel-qa@suse.de>

package nvidia_utils;

use Exporter;
use testapi;
use strict;
use warnings;
use utils;

our @EXPORT = qw(
  install
  validate
);

=head2 install

 install([ variant => 'cuda' ]);

Install the NVIDIA driver and the compute utils, making sure to remove
any conflicting variant first. Also, it tries to add the relevant
repositories to grab the packages from, defined by the job through
NVIDIA_REPO and NVIDIA_CUDA_REPO.

=cut

sub install
{
    my %args = @_;
    my $variant_std = 'nvidia-open-driver-G06-signed-kmp-default';
    my $variant_cuda = 'nvidia-open-driver-G06-signed-cuda-kmp-default';
    my $variant = $args{variant} eq "cuda" ? $variant_cuda : $variant_std;

    zypper_ar(get_required_var('NVIDIA_REPO'), name => 'nvidia', no_gpg_check => 1, priority => 90);
    zypper_ar(get_required_var('NVIDIA_CUDA_REPO'), name => 'cuda', no_gpg_check => 1, priority => 90);

    # Make sure to remove the other variant first
    my $remove_variant = script_run("rpm -q $variant_std") ? $variant_cuda : $variant_std;
    zypper_call("remove --clean-deps ${remove_variant}");

    # Install driver and compute utils which packages `nvidia-smi`
    zypper_call("install -l $variant");
    my $version = script_output("rpm -qa --queryformat '%{VERSION}\n' $variant | cut -d '_' -f1 | sort -u | tail -n 1");
    record_info("NVIDIA Version", $version);
    zypper_call("install -l nvidia-compute-utils-G06 == $version");
}

=head2 validate

 validate();

Do basic testing of the NVIDIA driver: check the GPU name,
make sure the module is loaded and log `nvidia-smi` output.

=cut

sub validate
{
    # Check card name
    if (my $gpu = get_var("NVIDIA_EXPECTED_GPU_REGEX")) {
        validate_script_output("hwinfo --gfxcard", sub { /$gpu/mg });
    }
    # Check loaded modules
    assert_script_run("lsmod | grep nvidia", fail_message => "NVIDIA module not loaded");
    # Check driver works
    my $smi_output = script_output("nvidia-smi");
    record_info("NVIDIA SMI", $smi_output);
}

1;
