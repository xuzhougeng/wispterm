# Contributing to Phantty

Thanks for your interest in contributing! This document explains how to report
issues and submit changes.

## Reporting issues

Before opening an issue, please:

1. **Search [existing issues](https://github.com/xuzhougeng/phantty/issues)** to
   avoid duplicates.
2. **Pick the right category** when you click *New issue*:
   - 🐛 **Bug Report** — something isn't working as expected.
   - ✨ **Enhancement / Feature Request** — a new feature or an improvement.
3. **Use the template fields.** Good bug reports include clear reproduction
   steps, the expected behavior, your OS, and the Phantty version.

For open-ended questions or ideas, please use
[Discussions](https://github.com/xuzhougeng/phantty/discussions) rather than
opening an issue.

## Submitting changes

1. Fork the repository and create a branch from `main`
   (e.g. `feat/my-feature` or `fix/some-bug`).
2. Build and test locally:

   ```powershell
   zig build                         # Debug build for development
   zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
   zig build test                    # Run the test suite
   ```

3. Keep changes focused — one logical change per pull request.
4. Match the surrounding code style (naming, formatting, comment density).
5. Open a pull request against `main` and describe **what** changed and **why**.
   Link any related issue (e.g. `Closes #123`).

For architecture, packaging, and release details, see
[docs/development.md](docs/development.md).

## Code of conduct

Be respectful and constructive. We want Phantty to be a welcoming project for
everyone.
