# IP monitor v.1.3.0

Run using ip_monitor_control.ps1

The file ip_summary.csv contains the following columns:

* IP - a specific remote IPv4 address that the process was observed communicating with
* Hits - how many times this IP appeared in the sample during the script runtime (this is not the number of TCP sessions, but the number of observations)
* Polls - how many times the process was detected as running during polling
* Share - Hits / Polls
* FirstSeen - when the IP first appeared
* LastSeen - the last observation timestamp
* SeenMinutes - how many minutes passed between FirstSeen and LastSeen (not total connection time, but the activity window)
* HitsPerMinute - Hits / SeenMinutes



Share - This is the key metric for identifying "core" ranges and filtering out random CDN spikes. Values close to 1.0 mean that the IP is present almost all the time (stable, possibly a primary server). Values close to zero, on the contrary, indicate rare, occasional appearance of the IP address.



FirstSeen and LastSeen - useful for understanding how long an address has been in use and for identifying one-time connections.



HitsPerMinute - this is essentially the "appearance density". If an IP maintains a stable connection, HitsPerMinute will be high, and if it flashed once, it will be low.



Keep in mind that CDNs (Cloudflare, Fastly, Google) may show high Share values, but after restarting the client, the pool may change. Run the script in different sessions to improve the sampling!


### ChangeLog:

1.3.0 (20:02:2026) - all settings are now available in a convenient menu directly inside the _control script!

1.2.0 (19:02:2026) - settings moved to a separate config file

1.1.0 (19:02:2026) - "ips_raw.log" and "unique_<process>.txt" are now created in the "raw" subfolder

1.0.0 (19:02:2026) - first stable version
