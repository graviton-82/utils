# WireGuard monitoring helper

The VPN profile uses a root-owned helper that returns only:

```text
peer_count|recent_peer_count|newest_handshake_age_seconds
```

A newest age of `-1` means there are no handshake timestamps. The helper queries
`wg show INTERFACE latest-handshakes`, aggregates in the privileged process, and
never returns raw dumps, private keys, preshared keys, or peer identifiers.

Install the checked-in helper **on the VPN server**, replacing any previous
raw-dump version. These commands require administrative access:

```bash
sudo install -o root -g root -m 0755 helpers/wg-dashboard-stats /usr/local/bin/wg-dashboard-stats
sudo visudo -f /etc/sudoers.d/wg-dashboard
```

Replace `monitor_user` with the SSH account and add:

```sudoers
monitor_user ALL=(root) NOPASSWD: /usr/local/bin/wg-dashboard-stats
```

This rule permits helper arguments. The helper accepts only a validated interface
name and a positive integer handshake window; it invokes fixed absolute command
paths and returns only aggregates. The account can inspect aggregates for other
WireGuard interfaces too. If policy requires one interface only, install a
root-owned wrapper fixing those arguments and use a matching sudoers restriction.

Ensure `/usr/local/bin`, the helper, and its ancestors are root-owned and not
writable by the monitoring account or its groups. The helper expects `/bin/bash`,
`/usr/bin/wg`, and `/usr/bin/awk`; verify these paths on the server. Do not grant
passwordless access to a user-writable copy or to unrestricted `wg`.

Test as the SSH account:

```bash
sudo -n /usr/local/bin/wg-dashboard-stats wg0 600
```

Then run from the monitoring machine:

```bash
./remote_stats.sh vpn-vm --profile vpn --once
RS_WG_INTERFACE=wg1 RS_WG_RECENT=300 ./remote_stats.sh vpn-vm --profile vpn --once
```

Both script and helper must use the aggregate protocol. A helper failure produces
`CRITICAL helper_unavailable`; malformed output produces `UNKNOWN invalid_response`.
An existing interface with no recent handshakes is reported as idle, not failed.
