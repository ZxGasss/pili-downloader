# Security Policy

## Supported version

Security fixes target the latest published 2.1.x release.

## Reporting a vulnerability

Please do not open a public Issue for a credential leak, command injection,
path traversal, unsafe file operation, or download-integrity problem. Use
GitHub's private vulnerability reporting for this repository and include:

- affected version and macOS version;
- a minimal reproduction using non-sensitive test data;
- expected and observed behavior;
- whether local files, credentials, or third-party services are affected.

Do not include Bilibili cookies, Keychain values, TMDB tokens, personal media
paths, or complete private logs in a report.

## Security boundaries

- The app does not bypass DRM, paid access, regional controls, or account
  permissions.
- Passwords are not stored by the app; authorized sessions and optional TMDB
  credentials are stored in macOS Keychain.
- Temporary downloader cookie files are created in a restricted directory and
  removed when the task ends.
- Logs are local and are not uploaded automatically.
