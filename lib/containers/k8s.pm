# SUSE's openQA tests
#
# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Basic functionality for testing kubernetes. Includes k3s tools
# Maintainer: qa-c team <qa-c@suse.de>


package containers::k8s;

use base Exporter;
use Exporter;
use strict;
use warnings;
use testapi;
use utils qw(zypper_call script_retry file_content_replace validate_script_output_retry random_string);
use Utils::Systemd qw(systemctl);
use containers::utils 'registry_url';
use version_utils qw(is_sle is_microos is_public_cloud is_transactional is_sle_micro is_leap is_leap_micro is_tumbleweed);
use registration qw(add_suseconnect_product get_addon_fullname);
use transactional qw(trup_call check_reboot_changes);

our @EXPORT = qw(install_k3s uninstall_k3s install_kubectl install_helm apply_manifest wait_for_k8s_job_complete find_pods validate_pod_log);

sub check_k3s {
    record_info('k3s', "k3s version " . script_output("k3s --version") . " installed");
    record_info('kubectl version', script_output('k3s kubectl version'));
    assert_script_run('uname -a');
    assert_script_run('test -e /etc/rancher/k3s/k3s.yaml');
    if (script_run('k3s check-config | tee /tmp/k3s-config.txt') != 0) {
        if (script_run('test $(grep -cE "CONFIG_CGROUP_(CPUACCT|DEVICE|FREEZER).*missing \(fail\)" /tmp/k3s-config.txt) -eq 3') == 0) {
            record_soft_failure("gh#k3s-io/k3s#11676", "k3s check-config fails on pure cgroups v2 systems without legacy controllers");
        } else {
            upload_logs('/tmp/k3s-config.txt');
            die "k3s check-config failed";
        }
    }
    validate_script_output('k3s kubectl config get-clusters', qr/default/);
    validate_script_output('k3s kubectl config get-users', qr/default/);
    validate_script_output('k3s kubectl config get-contexts --no-headers=true -o name', qr/default/);
    assert_script_run('k3s kubectl config view --raw');
    validate_script_output_retry("k3s kubectl get nodes", qr/ Ready.*control-plane,master /, retry => 6, delay => 15, timeout => 90);
    validate_script_output_retry("k3s kubectl get namespaces", qr/default.*Active/, timeout => 120, delay => 60, retry => 3);

    # the default service account should be ready by now
    script_retry("k3s kubectl get serviceaccount default -o name", retry => 10, delay => 60, timeout => 300);
    # expect that k3s api to be ready and is accessible
    record_info("k3s api resources", script_output("k3s kubectl api-resources"));
    assert_script_run("k3s kubectl auth can-i 'create' 'pods'", timeout => 300);
    assert_script_run("k3s kubectl auth can-i 'create' 'deployments'", timeout => 300);
}

sub start_k3s {
    systemctl('start k3s', timeout => 180);
    systemctl('is-active k3s');
}

sub set_custom_registry {
    return unless get_var('REGISTRY');

    script_run("mkdir -p /etc/rancher/k3s");
    my $registry = registry_url();
    assert_script_run "curl " . data_url('containers/registries.yaml') . " -o /etc/rancher/k3s/registries.yaml";
    file_content_replace("/etc/rancher/k3s/registries.yaml", REGISTRY => $registry);
}

sub configure_k3s {
    set_custom_registry;
    script_run("rm -rf ~/.kube");
    script_run('mkdir -p ~/.kube/');
    assert_script_run('ln -s /etc/rancher/k3s/k3s.yaml ~/.kube/config');
}

=head2 install_k3s
Deploy k3s using k3s-install script that is either pulled from osado or upstream.
=cut

sub install_k3s {
    # k3s might be already installed by default
    return if (script_run('which k3s') == 0);

    # Dependencies
    zypper_call('in apparmor-parser') if is_sle('<15-SP4', get_var('HOST_VERSION', get_required_var('VERSION')));

    # Assemble additional settings for the k3s installation
    my @k3s_args = ();
    push(@k3s_args, '--disable=metrics-server');
    push(@k3s_args, '--disable-helm-controller') if (get_var('K3S_DISABLE_HELM_CONTROLLER'));
    push(@k3s_args, '--disable=traefik') if (get_var('K3S_DISABLE_TRAEFIK'));
    push(@k3s_args, '--disable=coredns') if (get_var('K3S_DISABLE_COREDNS'));

    # Apply additional k3s installation options
    # Note: The install script starts a k3s-server by default, unless INSTALL_K3S_SKIP_START is set to true
    # For more information see https://rancher.com/docs/k3s/latest/en/installation/install-options/#options-for-installation-with-script
    my %k3s_envs = (
        INSTALL_K3S_SYMLINK => get_var('K3S_SYMLINK'),
        INSTALL_K3S_BIN_DIR => get_var('K3S_BIN_DIR'),
        INSTALL_K3S_CHANNEL => get_var('K3S_CHANNEL'),
        INSTALL_K3S_VERSION => get_var('K3S_VERSION'),
        INSTALL_K3S_SKIP_START => get_var('K3S_SKIP_START', 'true'),    # do not start by default, so we can configure registries ecc. before
        K3S_NODE_NAME => 'k3s-node'
    );
    while (my ($key, $value) = each %k3s_envs) {
        if ($value) {
            assert_script_run("export $key=$value");
        }
        delete $k3s_envs{$key};
    }

    # Install either from osado or upstream
    my $k3s_install_script = get_var("K3S_INSTALL_SCRIPT", "local");
    if ($k3s_install_script eq '' || $k3s_install_script eq 'local' || $k3s_install_script eq 'osado') {
        assert_script_run 'curl -o install_k3s ' . data_url('containers/data/install_k3s');
    } elsif ($k3s_install_script eq 'upstream') {
        assert_script_run("curl -sfL --retry 3 --retry-delay 60 --retry-max-time 180 https://get.k3s.io -o install_k3s.sh");
    } else {
        die "Unsupported setting for K3S_INSTALL_SCRIPT";
    }

    assert_script_run("k3s-install " . join(" ", @k3s_args));
    configure_k3s;
    start_k3s;
    check_k3s;
}

=head2 uninstall_k3s
Uninstalls k3s
=cut

sub uninstall_k3s {
    assert_script_run("rm -f ~/.kube/config");
    assert_script_run("/usr/local/bin/k3s-uninstall.sh");
}

=head2 install_kubectl
Installs kubectl from the respositories
=cut

sub install_kubectl {
    return if (script_run("which kubectl") == 0);

    # kubectl is in the container module
    add_suseconnect_product(get_addon_fullname('contm')) if (is_sle("<16"));
    my $k8s_version = shift;
    my $k8s_pkg = defined($k8s_version) ? "kubernetes$k8s_version-client" : get_var('K8S_CLIENT', 'kubernetes-client-provider');
    zypper_call("in -C $k8s_pkg");
    record_info('kubectl version', script_output('kubectl version --client'));
}

=head2 install_helm
Installs helm from our upstream or repositories
=cut

sub install_helm {
    return if (script_run("which helm") == 0);

    if (get_var('HELM_INSTALL_UPSTREAM')) {
        assert_script_run("curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3");
        assert_script_run("chmod 700 get_helm.sh");
        assert_script_run("./get_helm.sh");
    } elsif (is_transactional) {
        trup_call("pkg install helm");
        check_reboot_changes;
    } else {
        zypper_call("in helm");
    }
    record_info('helm', script_output("helm version"));
}

=head2 apply_manifest
Apply a kubernetes manifest
=cut

sub apply_manifest {
    my ($manifest) = @_;

    my $path = sprintf('/tmp/%s.yml', random_string(32));

    script_output("echo -e '$manifest' > $path");
    upload_logs($path, failok => 1);

    assert_script_run("kubectl apply -f $path");
}

=head2 find_pods
Find pods using kubectl queries
=cut

sub wait_for_k8s_job_complete {
    my ($job) = @_;
    my $cmd = "kubectl wait --for=condition=complete --timeout=300s job/$job";
    script_retry($cmd, retry => 5, timeout => 360, die => 1);
}

=head2 wait_for_k8s_job_complete
Wait until the job is complete
=cut

sub find_pods {
    my ($query) = @_;
    return script_output("kubectl get pods --no-headers -l $query -o custom-columns=':metadata.name'");
}

=head2 validate_pod_logs
Validates that the logs contains a text
=cut

sub validate_pod_log {
    my ($pod, $text) = @_;
    validate_script_output("kubectl logs $pod 2>&1", qr/$text/, timeout => 180);
}

1;
