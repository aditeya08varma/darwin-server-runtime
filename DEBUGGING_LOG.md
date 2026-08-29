# Debugging log

This file is a record of real problems I ran into while building this
project, and how each one was actually found and fixed. I am keeping it
separate from the README on purpose. The README describes the finished
design. This file is about the messy part of getting there, which is
useful both as my own reference later and as proof of real debugging work,
not just a list of finished features.

Each entry follows the same shape. What broke. What actually caused it.
How I fixed it. What to remember from it.

---

## 1. `swift test` failed with "no such module 'XCTest'" (Stage 0)

**What broke.** `swift build` worked fine. But `swift test` refused to
compile any test file at all. It failed with the error "no such module
'XCTest'".

**What caused it.** My machine only had the Command Line Tools installed.
It did not have full Xcode. I checked with `xcode-select -p` and it
pointed at `/Library/Developer/CommandLineTools`. On macOS, the real
`XCTest.framework` only ships inside Xcode.app itself. It is not part of
the standalone Command Line Tools package. I confirmed this by searching
the whole filesystem for XCTest and only finding an unrelated framework
called XCTestSupport.

**How I fixed it.** I installed Xcode from the App Store. Then I ran these
two commands:
```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```
After that, `swift test` worked immediately. I did not have to change any
code at all.

**What to remember.** `swift build` and `swift test` do not need the same
things installed on my machine. A successful build does not prove my
tests can even compile. It is worth trying `swift test` early on a new
machine, since GitHub's CI runners already have full Xcode installed and
would never have shown me this problem.

---

## 2. `log show` failed with "too many arguments" (Stage 1)

**What broke.** I tried to read the daemon's log messages by running
`log show --predicate '...' --last 5m` in the terminal. It failed
instantly with a strange error: "too many arguments". The command looked
correct to me.

**What caused it.** In zsh, `log` is actually a built in shell command
used for logging shell scripts. It has nothing to do with Apple's real
logging tool. My terminal was quietly running the wrong `log` command and
getting confused by arguments it did not understand.

**How I fixed it.** I called the real tool directly by its full path
instead: `/usr/bin/log show ...`.

**What to remember.** If a well known command gives an error that does not
match what it is supposed to do, it is worth checking whether something
else with the same name is quietly getting used instead. Running
`type <command name>` answers that question right away.

---

## 3. A quick standalone script could not use my own code (Stage 1)

**What broke.** I wanted a fast way to preview what `IPCMessage` looks
like as JSON, so I tried running a small standalone script with
`swift -I .build/debug/Modules -L .build/debug -lRuntimeCore preview.swift`.
It failed while starting up, unable to find the compiled pieces of my
`RuntimeCore` code.

**What caused it.** The build output that Swift Package Manager creates in
`.build/debug` is not meant to be linked against from an outside script
like that. It is built to work as part of the package's own build process,
not as a general purpose library other programs can just point at.

**How I fixed it.** I gave up on the standalone script idea. Instead, I
temporarily added the same preview code straight into
`DarwinDaemon/main.swift`, which is already a normal part of the project.
I ran the real `darwin-runtimed` program to see the output, then removed
the temporary code afterward.

**What to remember.** If I want to quickly check how code inside my own
project behaves, it is usually easier and more reliable to run it through
one of the project's own programs than to try linking against the build
output from the outside.

---

## 4. `darwin-run ping` hung forever with no output at all (Stage 1)

**What broke.** I ran `darwin-run ping` while the daemon was not running,
expecting a clear error message. Instead, nothing happened. No output, no
error, no crash. The program just sat there.

**What caused it.** `NWConnection`, the networking type I use to connect
to the daemon, can enter a state called `.waiting` when it cannot connect
right away. This is different from a hard failure. By default, Apple's
networking code treats `.waiting` as "keep trying quietly in the
background, in case things get better later." That behavior makes sense
for something like a phone app dealing with spotty wifi. It does not make
sense for a command line tool, which should tell the user right away if
something is wrong. My code only handled three states on purpose:
connected, failed, and cancelled. Since `.waiting` was not one of them, it
fell into a general "do nothing yet" case, and the program was left
waiting on an answer that was never going to come.

**How I fixed it.** I added a case that treats `.waiting` the same way as
a hard failure. As soon as the connection reports it cannot connect, I
cancel it and show the user an error right away instead of waiting
silently.

**What to remember.** When wrapping an old style callback based API into
modern `async`/`await` code, it is important to think through every
possible state it can report, not just the obvious success and failure
ones. A state I forgot about does not always cause a crash. Sometimes it
just quietly swallows the one signal my code was waiting for, and the
program hangs with no clue why.
