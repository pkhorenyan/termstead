# LibVNCClient patches

Applied to the pinned LibVNCClient 0.9.15 source by `build-vnc-deps.sh`.

- `security-allowlist.patch`: apply `SetClientAuthSchemes` to RFB 3.3 too.
  Upstream checks this list while negotiating RFB 3.7/3.8, but RFB 3.3's
  server-selected security type bypasses it. Enforce it before authentication
  or ClientInit, so disabling anonymous access also protects older servers.
- `empty-cursor.patch`: notify `GotCursorShape` for zero-sized cursor shapes.
  RFB uses these to hide the cursor, but upstream returns without notifying
  the viewer, leaving its previous native cursor visible.
- `verified-tls.patch`: expose the OpenSSL peer chain before any VNC
  authentication bytes are sent. The app verifies it with macOS trust or asks
  the user; rejection terminates the handshake. Apply the authentication
  allowlist to every VeNCrypt subtype too, so anonymous TLS or plaintext
  passwords cannot bypass Require TLS. Send SNI and release the SSL context's
  original reference after a successful handshake. Require TLS 1.2 or later,
  reject unsupported VeNCrypt versions and stop writes on TLS close rather
  than spinning forever on SSL_write returning zero.
- `desktop-size.patch`: preserve the advertised screen id/flags, initialize
  padding in resize requests, accept valid screen id zero, and do not resize
  the local framebuffer when the server rejects a request.
- `write-tls-timeout.patch`: apply a deadline to the TLS handshake and to
  writes. Wait for the socket to become readable or writable as requested by
  OpenSSL, and close the connection if writing fails.
