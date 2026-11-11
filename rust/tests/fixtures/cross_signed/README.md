# Cross-signed certificate regression

These are public DER certificates served by `huangguoai.ai:443`, captured on
2026-11-11. They contain no private keys or session credentials:

* `leaf.der`: the site's certificate.
* `intermediate.der`: Google Trust Services WE1.
* `cross-signed-root.der`: GTS Root R4, cross-signed by GlobalSign Root CA.

The application bundle trusts the self-signed GTS Root R4. Published Courierust
1.1.2 rejects the full cross-signed chain even though the shorter path can reach
that anchor. This test records the upstream limitation; it is not a production
workaround. Production never alters the received certificate chain.

The fixed verification time is 2026-11-11 UTC. The test also checks the shorter
valid path and rejects missing anchors, expired certificates and damaged
signatures. Live network tests use the actual clock.
