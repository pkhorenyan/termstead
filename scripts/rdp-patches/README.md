# Patches to FreeRDP

`scripts/build-rdp-deps.sh` applies every `freerdp-*.patch` here, in name
order, to the pinned FreeRDP release before building it. Keep each one small,
say at its top why it exists, and drop it once FreeRDP fixes the problem
upstream.

- `freerdp-reactivation-updates.patch` — xrdp sends screen updates during
  the finalization of a deactivation-reactivation (every resize through
  Display Control), and FreeRDP 3 ended the session over them about one
  time in two: "State CONNECTION_STATE_ACTIVE (or higher) requested, but
  CONNECTION_STATE_FINALIZATION_CLIENT_SYNC found". After a deactivation,
  updates are accepted from the finalization on; the desktop already has its
  new size by then.
