## Watchdog Utilities

This repository will also include lightweight watchdog tools for recovering failed or stalled applications.

The first planned watchdog target is OBS on Windows. The initial version will monitor recording file growth during scheduled recording windows and log when recording appears stalled.

Future checks may include:

- OBS process status
- OBS WebSocket health
- recording file growth
- audio activity
- automatic restart
- Windows notification
