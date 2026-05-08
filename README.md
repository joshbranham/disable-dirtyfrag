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
Created /etc/modprobe.d/dirtyfrag.conf
OK: esp4 was not loaded
OK: esp6 was not loaded
OK: rxrpc was not loaded
=== result ===
Node is protected
```

### Testing the vulnerability

**Only test on systems you are authorized to access.**

The test pod uses a pre-built image (`quay.io/jbranham/disable-dirtyfrag:latest`) containing the compiled exploit. A privileged init container pre-loads the `esp4` kernel module, then the exploit runs as non-root (`uid=1000860000`) to demonstrate that an unprivileged container can escalate to root.

The init container is necessary because SELinux blocks kernel module autoloading from non-privileged (`container_t` domain) containers. Without `esp4` already loaded, the exploit fails at `add_xfrm_sa` regardless of whether the node is actually vulnerable. Pre-loading the module isolates the test from SELinux module-request policy so the result reflects whether the mitigation is in place.

```sh
oc apply -f test-dirtyfrag.yaml && oc wait -n disable-dirtyfrag pod/dirtyfrag-test --for=condition=Ready --timeout=120s && oc attach -n disable-dirtyfrag -it dirtyfrag-test
```

**Before mitigation:** you should see `uid=1000860000`, then the exploit escalates to `uid=0(root)`.

**After mitigation:** the init container will fail to load `esp4` (blocked by `/etc/modprobe.d/dirtyfrag.conf`), and the exploit will fail with `dirtyfrag: failed (rc=1)`.

Clean up the test pod:

```sh
oc delete -f test-dirtyfrag.yaml
```

#### Alternative: pre-load the module manually

Instead of using the init container, you can pre-load `esp4` on a specific node and then deploy a non-privileged test pod:

```sh
oc debug node/<node-name> -- chroot /host modprobe esp4
```

#### Quick validation without the exploit binary

You can check exploit subsystem and mitigation status on any node using Python via `oc debug`:

```sh
oc debug node/<node-name> -- chroot /host python3 -c "
import socket

AF_RXRPC = 33
SOL_UDP = 17
UDP_ENCAP = 100
UDP_ENCAP_ESPINUDP = 2

def try_socket(label, fn):
    try:
        s = fn()
        print(f'  ALLOWED  {label}')
        s.close()
    except OSError as e:
        print(f'  BLOCKED  {label} -- {e}')

def udp_encap(family):
    s = socket.socket(family, socket.SOCK_DGRAM, 0)
    s.setsockopt(SOL_UDP, UDP_ENCAP, UDP_ENCAP_ESPINUDP.to_bytes(4, 'little'))
    return s

print('=== DirtyFrag Subsystem Test ===')
print()

print('--- Exploit subsystems ---')
try_socket('AF_RXRPC socket',  lambda: socket.socket(AF_RXRPC, socket.SOCK_DGRAM, socket.AF_INET))
try_socket('UDP_ENCAP (IPv4)', lambda: udp_encap(socket.AF_INET))
try_socket('UDP_ENCAP (IPv6)', lambda: udp_encap(socket.AF_INET6))

print()
print('--- Kernel modules ---')
with open('/proc/modules') as f:
    mods = f.read()
for mod, desc in [
    ('esp4',  'ESP IPv4 (xfrm-ESP exploit path)'),
    ('esp6',  'ESP IPv6 (xfrm-ESP exploit path)'),
    ('rxrpc', 'AF_RXRPC (rxrpc/rxkad exploit path)'),
]:
    status = 'LOADED' if (mod + ' ') in mods else 'absent'
    print(f'  {status:8s}  {mod:6s} -- {desc}')

print()
print('--- Sanity checks (should be ALLOWED) ---')
try_socket('AF_INET TCP',  lambda: socket.socket(socket.AF_INET, socket.SOCK_STREAM, 0))
try_socket('AF_INET UDP',  lambda: socket.socket(socket.AF_INET, socket.SOCK_DGRAM, 0))
try_socket('AF_INET6 TCP', lambda: socket.socket(socket.AF_INET6, socket.SOCK_STREAM, 0))
"
```

When the modprobe mitigation is active, all modules will show `absent` and `UDP_ENCAP` will be `ALLOWED` (but harmless since `esp4`/`esp6` can't load). If a BPF LSM blocker is active instead, `UDP_ENCAP` will show `BLOCKED` with `EPERM`.

#### Rebuilding the test image

```sh
podman build -t quay.io/jbranham/disable-dirtyfrag:latest .
podman push quay.io/jbranham/disable-dirtyfrag:latest
```

### Cleanup

```sh
oc delete -f disable-dirtyfrag.yaml
```

Note: this removes the DaemonSet but leaves `/etc/modprobe.d/dirtyfrag.conf` in place on each node, so the modules will remain blocked from loading.
