# Cross-signed certificate regression

These are public DER certificates served by `huangguoai.ai:443`, captured on
2026-11-11. They contain no private keys or session credentials:

* `leaf.der`: the site's certificate.
* `intermediate.der`: Google Trust Services WE1.
* `cross-signed-root.der`: GTS Root R4, cross-signed by GlobalSign Root CA.

The full chain is verified by Rustls against webpki trust anchors at a fixed
2026-11-11 UTC capture time. The regression rejects wrong hostnames, expired
certificates, missing intermediates and damaged signatures. Production verifies
the complete received chain using the real clock; it never truncates the chain
or trusts a leaf certificate directly.
