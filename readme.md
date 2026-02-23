# IP monitor v.1.4.0

Run using IP-monitor.bat

Summary log CSV files contains the following columns:

* IP - a specific remote IPv4 address that the process was observed communicating with.
* Hits - how many times this IP appeared in the sample during the script runtime (this is not the number of TCP sessions, but the number of observations).
* Polls - how many times the process was detected as running during polling.
* Share - Hits / Polls. This is the key metric for identifying "core" ranges and filtering out random CDN spikes. Values close to 1.0 mean that the IP is present almost all the time (stable, possibly a primary server). Values close to zero, on the contrary, indicate rare, occasional appearance of the IP address.
* FirstSeen - when the IP first appeared. Useful for understanding how long an address has been in use.
* LastSeen - the last observation timestamp. Useful for identifying one-time connections.
* SeenMinutes - how many minutes passed between FirstSeen and LastSeen (not total connection time, but the activity window).
* HitsPerMinute - Hits / SeenMinutes. This is essentially the "appearance density". If an IP maintains a stable connection, HitsPerMinute will be high, and if it flashed once, it will be low.


Keep in mind that CDNs (Cloudflare, Fastly, Google) may show high Share values, but after restarting the client, the pool may change. Run IP-monitor in different sessions to improve the sampling!
