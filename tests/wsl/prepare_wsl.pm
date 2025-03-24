# SUSE's openQA tests
#
# Copyright 2012-2019 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: Configure windows 10 to host WSL image
# Currently we have self signed images as sle12sp5 and leap
# tumbleweed and sle15sp2 or higher contain a chain of certificates
# In case of chain certificates, store only CA certificate
# 1) Download the image and CA cert if any
# 2) Enable developer mode Import certificates
# 3) Import downloaded or embedded certificate
# 4) Enable WSL feature
# 5) Reboot
# 6) Install WSL image
# Maintainer: qa-c <qa-c@suse.de>

use Mojo::Base qw(windowsbasetest);
use Utils::Architectures qw(is_aarch64);
use testapi;
use version_utils qw(is_sle is_opensuse);

sub run {
    my ($self) = @_;

    $self->open_powershell_as_admin;

    # Disable temporarily, to allow the powershell commands to setup the agent before it is being used.
    my $openqa_agent = get_var("OPENQA_AGENT", 0);
    set_var("OPENQA_AGENT", "0") if ($openqa_agent);

    if (get_var('WSL2')) {
        # WSL2 platform must be enabled from the MSstore from now on
        $self->run_in_powershell(
            cmd => "wsl --install --no-distribution",
            code => sub {
                unless (is_aarch64) {
                    assert_screen(["windows-user-account-ctl-hidden", "windows-user-acount-ctl-allow-make-changes"], 900);
                    assert_and_click "windows-user-account-ctl-hidden" if match_has_tag("windows-user-account-ctl-hidden");
                    assert_and_click "windows-user-acount-ctl-yes";
                }
                assert_screen("windows-wsl-cli-install-finished", timeout => 900);
            }
        );
        # Disable HyperV in WSL2
        # On aarch64 with WSL2 this gets stuck somehow or is too slow (>2h?).
        $self->run_in_powershell(
            cmd => 'Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Hypervisor -NoRestart',
            timeout => 60
        ) unless is_aarch64;
    } else {
        # WSL1 will still be enabled in the legacy mode
        $self->run_in_powershell(
            cmd => 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart',
            timeout => 300
        );
        # Some versions immediately want to install updates on the first wsl.exe run, do that now
        $self->run_in_powershell(
            cmd => 'wsl.exe --update',
            timeout => 300
        ) if get_var('HDD_1') =~ /24H2/;
    }

    $self->reboot_or_shutdown(is_reboot => 1);
    $self->wait_boot_windows;

    # Install and enable the openQA-agent
    if ($openqa_agent) {
        $self->open_powershell_as_admin;
        my $uri = "https://github.com/grisu48/openqa-agent/releases/download/v" . get_required_var("OPENQA_AGENT_VERSION") . "/agent-Windows-amd64";
        my $exe = 'C:\\agent.exe';
        # Exclude agent from Windows Defender and allow in Firewall
        ##$self->run_in_powershell(cmd => "Set-MpPreference -ExclusionPath \"$exe\""); # Currently disabled.
        $self->run_in_powershell(cmd => "New-NetFirewallRule -DisplayName \"Allow openqa-agent\" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8421");
        $self->run_in_powershell(cmd => "Invoke-WebRequest -Uri \"$uri\" -OutFile \"$exe\"", timeout => 300);
        $self->run_in_powershell(cmd => "Start-Job -ScriptBlock { $exe -t nots3cr3t -b \":8421\" }");
        $self->run_in_powershell(cmd => "Get-NetIPAddress > ip.txt");
        $self->run_in_powershell(cmd => "Select-String -Path ip.txt -Pattern \"IPAddress\"");
        set_var("OPENQA_AGENT", "1");
        $self->run_in_powershell(cmd => "echo 1");
    }
}

1;
