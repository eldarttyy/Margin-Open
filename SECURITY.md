# Security

Margin asks for Accessibility access and reads raw trackpad touches, so security
reports are taken seriously.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately:

1. Go to the [Security tab](https://github.com/eldarttyy/Margin-Open/security) of this repository.
2. Click **Report a vulnerability** and describe what you found and how to reproduce it.

You'll get a reply within a week. Once a fix is released, you'll be credited in
the release notes unless you'd rather not be.

## Supported versions

Only the latest release gets security fixes.

## What Margin does and doesn't do

- It runs locally. It collects no analytics and sends no usage data.
- Its only network request is the update check, which fetches a small version file from the Margin website.
- Preview builds are ad-hoc signed and not notarized yet. If you'd rather not
  trust a downloaded build, build from source with `scripts/build-app.sh`.
