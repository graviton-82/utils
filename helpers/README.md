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
[ssh-user] ALL=(root) NOPASSWD: /usr/local/bin/wg-dashboard-stats  
```
Then test remotely:
```bash
ssh [user]@[ip-address] "sudo -n /usr/local/bin/wg-dashboard-stats"  
```
you can now use the --profile vpn flag

```bash
##### Future OS Detection Helpers #####

get_remote_os() {
    if is_local_target "$remote_target"; then
        uname -s 2>/dev/null || echo "Unknown"
        return
    fi

    # Linux / BSD / macOS
    if run_remote 'uname -s' >/dev/null 2>&1; then
        run_remote 'uname -s'
        return
    fi

    # Windows via OpenSSH
    if run_remote 'powershell -NoProfile -Command "$env:OS"' >/dev/null 2>&1; then
        echo "Windows"
        return
    fi

    echo "Unknown"
}

is_windows_target() {
    [[ "$(get_remote_os)" == "Windows" ]]
}

is_linux_target() {
    local os
    os="$(get_remote_os)"

    [[ "$os" == "Linux" || \
       "$os" == "Darwin" || \
       "$os" == "FreeBSD" ]]
}
```

