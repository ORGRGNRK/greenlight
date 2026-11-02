# greenlight

Let an AI change your code, but only keep the change if it builds and passes your tests.

```sh
greenlight claude "add a --verbose flag"
```

1. greenlight makes a separate copy of your project from your last commit (a git worktree in a temp folder).
2. The AI edits **that copy**. Your own folder isn't touched while it works.
3. The copy must **build** and **pass your tests**. If it doesn't, the change is thrown away and nothing changes.
4. If it passes, the change is committed and lands on your current branch.

If you edited the same files while it was working, your edits are never overwritten. The tested change is
parked on a branch for you instead.

One bash script. No server, no account, no API key of its own. Works with git, on macOS and Linux.

## Install

```sh
curl -fsSLo ~/.local/bin/greenlight https://raw.githubusercontent.com/ORGRGNRK/greenlight/main/greenlight
chmod +x ~/.local/bin/greenlight
```

or clone the repo and put `greenlight` on your PATH.

You also need an AI coding CLI: [Claude Code](https://claude.com/claude-code) (`claude`), OpenAI's `codex`, or any
other tool through `--cmd`.

## Use

```sh
greenlight claude "fix the failing date parser test"
greenlight codex  "rename Foo to Bar everywhere"
greenlight --cmd 'my-ai-tool --yes' "add input validation"    # instructions arrive on stdin and in $GREENLIGHT_PROMPT
greenlight --keep-branch claude "try a faster sort"            # don't merge; leave it on a branch to look at first
greenlight --plan                                              # show which build/test steps it will use
echo "a long instruction..." | greenlight claude -             # read the instruction from stdin
```

## Tell it how to build and test

Put a `.greenlight` file in your project:

```
BUILD=npm run build
TEST=npm test
PROTECT=test/ .github/
INSTALL=npm run deploy-local
```

| Key | |
|---|---|
| `TEST` | **required.** No test step = greenlight refuses to run. A change it can't prove is a change it won't make. |
| `BUILD` | optional, runs before the tests |
| `PROTECT` | optional, space-separated paths the AI may not change. Use it for your tests, so the AI can't "pass" by weakening them. |
| `INSTALL` | optional, runs in your folder after the change lands |

The file is read as plain `KEY=value` lines. It is never run as a script.

Without the file, greenlight guesses from `Package.swift`, `package.json`, `Cargo.toml`, `go.mod`, or Python tests (pytest).

## What it guarantees, and what it doesn't

- ✅ Nothing lands unless your build and tests pass on the changed code.
- ✅ Your working folder is never stashed, reset or overwritten.
- ✅ One run at a time per repo. A run killed halfway is cleaned up the next time.
- ✅ Every run is logged to `~/.local/state/greenlight/<run-id>.log`.
- ⚠️ It's only as good as your tests. If they don't check something, greenlight can't either. Use `PROTECT` for your test folder.
- ⚠️ The AI runs with its own permissions in the copy (for `claude`: file edits only). greenlight doesn't sandbox it.
  Read what your AI tool is allowed to do.

Exit codes: `0` landed · `1` failed, nothing changed · `2` usage · `3` another run is going · `4` kept on a branch.

## Tests

```sh
bash test/run.sh
```

16 cases with a fake AI. Each one makes a throwaway repo and checks a good change, failing tests, a failing build,
the AI tampering with protected tests, your unsaved edits, locks, cleanup, and so on. greenlight uses itself:
its own `.greenlight` runs these tests and protects `test/`.

## License

[GNU AGPL v3](LICENSE) or later. This code was written with AI assistance.
