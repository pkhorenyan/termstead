# LibVNCClient patches

Applied to the pinned LibVNCClient 0.9.15 source by `build-vnc-deps.sh`.

- `security-allowlist.patch`: apply `SetClientAuthSchemes` to RFB 3.3 too.
  Upstream checks this list while negotiating RFB 3.7/3.8, but RFB 3.3's
  server-selected security type bypasses it. Enforce it before authentication
  or ClientInit, so disabling anonymous access also protects older servers.
