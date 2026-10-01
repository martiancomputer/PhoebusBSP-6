# Agent guide: PhoebusBSP-6

This repository is the Linux 6.18 LTS board-support port for the RTL9607C/Cv2. It is one of three repositories: this BSP contains kernel-version-specific adaptations; `sdk/` is the Phoebus-SDK Git submodule containing shared vendor source and userspace; PhoebusBSP-7 is the separate mainline port. Do not assume a change to one BSP is automatically present in the other.

## Where things live

- `build.sh` reconstructs a disposable kernel tree and packages `images/uImage`.
- `configs/rtl9607c.config` is the tracked kernel configuration.
- `overlay/` contains the 6.18-specific platform, network, wireless, and API adaptations copied over the reconstructed tree.
- `patches/` and `docs/` contain port patches and technical reference material. Check that a document is public-safe before tracking it.
- `sdk/` is a pinned submodule, not a copy of the SDK. Shared vendor, rootfs, service, network policy, and tooling changes belong in the SDK repository first; update the BSP gitlink only after the SDK commit is available remotely.
- `build/`, `toolchain/`, and `images/` are generated or downloaded. Never commit them. A successful compile is not a hardware test.

Use `git submodule update --init` before building and `./build.sh` for the normal build. Read the current code and build script rather than treating historical status text as authoritative. Preserve untracked user files; do not stage them by default.

## Privacy and publication rules

Before writing or committing, distinguish public source/configuration from local notes, logs, dumps, captures, build outputs, credentials, and machine-specific setup. The latter stay local and should be ignored. Do not add a broad ignore rule for normal documentation such as `README.md` or `PROJECT.md`.

Never commit passwords, tokens, keys, Wi-Fi credentials, cookies, authentication headers, `.env` files, private dumps, or credential-bearing configuration. Do not commit personal usernames, email addresses, hostnames, account IDs, absolute home/workspace paths, device serials, or identifying MAC/IP values. Use neutral placeholders such as `$HOME`, `<user>`, `<host>`, `<device>`, and `<account-id>` in examples. Subnet or protocol addresses required by functioning code are not automatically private: preserve exact values when technically necessary and reviewed, rather than blindly removing them.

Before every commit, review `git diff --cached` and `git diff --cached --check`; scan staged *additions* and commit metadata for the categories above. Sanitize questionable content before committing. Before every push, inspect every outgoing commit and its diff, including submodule pins; confirm the pinned SDK commit exists on its remote and inspect it for private data. If sensitive data is already in history, do not claim a working-tree edit removes it: stop the push and coordinate a history rewrite and credential rotation as appropriate. Never force-push without explicit authorization and a verified target/ref.

Keep runtime secrets in ignored local configuration or a secret manager; ask the user before publishing any value whose necessity or privacy is unclear. Do not copy raw logs or local paths into public docs, commit messages, or issue text.
