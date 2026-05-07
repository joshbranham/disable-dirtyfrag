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

The test pod uses a pre-built image (`quay.io/jbranham/disable-dirtyfrag:latest`) containing the compiled exploit and runs as non-root:

```sh
oc apply -f test-dirtyfrag.yaml && oc wait -n disable-dirtyfrag pod/dirtyfrag-test --for=condition=Ready --timeout=120s && oc attach -n disable-dirtyfrag -it dirtyfrag-test
```

Before the exploit you should see `uid=1000860000`. If the system is vulnerable, the exploit will escalate to `uid=0(root)`. Apply the mitigation, then run the test again — the exploit should fail because the required kernel modules can no longer be loaded.

To rebuild the image:

```sh
podman build -t quay.io/jbranham/disable-dirtyfrag:latest .
podman push quay.io/jbranham/disable-dirtyfrag:latest
```

Clean up the test pod:

```sh
oc delete -f test-dirtyfrag.yaml
```

### Cleanup

```sh
oc delete -f disable-dirtyfrag.yaml
```

Note: this removes the DaemonSet but leaves `/etc/modprobe.d/dirtyfrag.conf` in place on each node, so the modules will remain blocked from loading.
