# LAN hub following

Run the shared lightweight runner:
`python3 verification/kit/lan-invite/check.py`.

The HMAC vectors come from Lody's `signLanHubMove` / `signLanHubLocation`.
Checks are offline and do not contact a hub or member. The production follower
uses a bounded TLS 1.2 PSK `hub` service transport only; file, terminal and
simulator transports are outside this round.
