To avoid adding the user to the sudo group and/or using passwordless sudo for commands requiring root access use the following steps.

On the VPN server, create a helper script with sudo access. 

create file with:
```bash
sudo nano /usr/local/bin/wg-dashboard-stats  
```

Put:
```bash
#!/usr/bin/env bash  
set -euo pipefail  

/usr/bin/wg show wg0 dump
```
Then:
```bash
sudo chown root:root /usr/local/bin/wg-dashboard-stats  
sudo chmod 755 /usr/local/bin/wg-dashboard-stats  
```
Create a sudoers rule:

```bash
sudo visudo -f /etc/sudoers.d/wg-dashboard  
```
Add:
```bash
vpnadmin ALL=(root) NOPASSWD: /usr/local/bin/wg-dashboard-stats  
```
Then test remotely:
```bash
ssh [user]@[ip-address] "sudo -n /usr/local/bin/wg-dashboard-stats"  
```
you can now use the --profile vpn flag
