# Self-hosting SnapSiphon storage with picos3 + Tailscale

The easy button for a fully self-hosted backup target: [picos3](https://github.com/jclement/picos3)
is a tiny single-bucket S3-compatible server, and with `--tailscale-tls` it
serves HTTPS using your Tailscale node certificate — so your phone backs up
over your tailnet, end to end, without exposing anything to the internet.

Why it pairs well with SnapSiphon:

- **Real MD5 ETags** → the app's *Verify all backups* does full checksum
  verification, zero downloads.
- **No Object Lock / versioning** → *Purge deleted backups* frees space
  immediately after the grace period (no lock retention to wait out). Use
  picos3's `--retain` if you want server-side soft-delete retention instead.
- **Path-style addressing** and SigV4 header auth — exactly what the app speaks.

## Copy-paste compose file

```yaml
services:
  tailscale:
    image: tailscale/tailscale:latest
    hostname: picos3                    # → https://picos3.<your-tailnet>.ts.net
    environment:
      - TS_AUTHKEY=tskey-auth-XXXXX     # from the Tailscale admin console
      - TS_STATE_DIR=/var/lib/tailscale
    volumes:
      - tailscale-state:/var/lib/tailscale
      - tailscale-sock:/var/run/tailscale
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    restart: unless-stopped

  picos3:
    image: ghcr.io/jclement/picos3:latest
    network_mode: service:tailscale
    command: --tailscale-tls
    environment:
      - PICOS3_LISTEN=:443              # standard port → no :port in the endpoint
      - PICOS3_BUCKET=photos
      - PICOS3_ACCESS_KEY=change-me
      - PICOS3_SECRET_KEY=change-me-too
    volumes:
      - picos3-data:/data
      - tailscale-sock:/var/run/tailscale
    restart: unless-stopped

volumes:
  picos3-data:
  tailscale-state:
  tailscale-sock:
```

(The authoritative Tailscale example lives in picos3's own
[`examples/tailscale/`](https://github.com/jclement/picos3/tree/main/examples) —
check it if this drifts.)

## SnapSiphon settings

| Field | Value |
|---|---|
| Endpoint host | `picos3.<your-tailnet>.ts.net` |
| Region | `us-east-1` (anything — picos3 accepts any region) |
| Bucket | `photos` (must match `PICOS3_BUCKET`) |
| Path-style addressing | **on** |
| Access key / secret | your `PICOS3_ACCESS_KEY` / `PICOS3_SECRET_KEY` |

Then **Save & Test** — it should go green immediately from any device on your
tailnet.

Notes:

- **HTTPS is required** — SnapSiphon never speaks plain HTTP. `--tailscale-tls`
  handles this; for non-Tailscale deployments use `--acme-host` or
  `--tls-cert`/`--tls-key`.
- If you keep a non-443 `PICOS3_LISTEN`, put the port in the endpoint
  (`host.ts.net:9000`) — the app signs it correctly.
- **Reachability**: backups only run while the phone can reach your tailnet
  (enable the Tailscale iOS app's VPN On Demand). When the node is offline the
  app fails fast with a clear "endpoint unreachable" message and retries next
  run — it won't churn the queue.
- Consider a read-only key (`PICOS3_RO_ACCESS_KEY`/`PICOS3_RO_SECRET_KEY`) for
  the restore script, keeping the write key only on the phone.
