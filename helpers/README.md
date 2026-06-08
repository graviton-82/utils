On the VPN server, create a wrapper:

sudo nano /usr/local/bin/wg-dashboard-stats

Put:

#!/usr/bin/env bash
set -euo pipefail

/usr/bin/wg show wg0 dump

Then:

sudo chown root:root /usr/local/bin/wg-dashboard-stats
sudo chmod 755 /usr/local/bin/wg-dashboard-stats

Create a sudoers rule:

sudo visudo -f /etc/sudoers.d/wg-dashboard

Add:

vpnadmin ALL=(root) NOPASSWD: /usr/local/bin/wg-dashboard-stats

Then test remotely:

ssh [user]@[ip-address] "sudo -n /usr/local/bin/wg-dashboard-stats"

you can now use the --profile vpn flag
