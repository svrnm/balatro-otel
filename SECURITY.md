# Security

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/svrnm/balatro-otel/security/advisories/new),
not in public issues. This is a hobby project: I will look at reports as soon as I can, but there is no
guaranteed response time.

Things that count: the mod sending data anywhere other than the configured endpoint, or sending data
its [privacy notes](mod/otel-trace/README.md#privacy) do not mention; the tooling exposing services
beyond localhost or leaking credentials (for example a Bronto API key).
