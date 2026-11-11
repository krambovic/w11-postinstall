# Security

Report vulnerabilities privately through GitHub private vulnerability reporting if enabled; do not attach sensitive logs to a public issue. No private reporting channel is assumed to be configured by this file.

Plans and catalogs are local data, not a sandbox for untrusted authors. SHA-256 detects accidental changes but does not authenticate the publisher. Review source, packages and installers before granting administrator rights. Only run code from a trusted checkout.

State journals are local to the current user and protected with filesystem ACLs. Registry backup can contain personal state. Redact SID, paths, names and other sensitive values before sharing a report. Administrators/SYSTEM remain trusted; the tool does not protect against a compromised administrator.

Preview has no VM certification. Defender removal is unsupported and cannot be enabled by acceptance flags. No project telemetry is collected; real package installations contact package repositories and publishers.
