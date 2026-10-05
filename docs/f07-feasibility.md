# F07 feasibility

Native passive discovery is feasible: Joycode can read the OpenCode registration,
validate its local-only endpoint and permissions, and probe `GET /api/info` through an
injected transport. The implemented scope is F07-R: passive, read-only registration
discovery. `Service.ensure` is intentionally unsafe for app launch because it can start,
stop, replace, or terminate a service and perform PTY handoff; it is not used.

Decision: do not implement app-managed process startup now. It remains explicitly deferred;
revisit it in R01 only if needed and only with explicit approval of lifetime and ownership,
rather than treating F07 as startup ownership.
No live registration or service was read for this slice; live evidence remains pending.
