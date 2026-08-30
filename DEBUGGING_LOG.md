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

---

## 5. `import CSystemBridge` could not find `archive.h`, even with the right flags (Stage 2)

**What broke.** I added `#include <archive.h>` to my C bridge target so
Swift could call into libarchive. Even after installing libarchive with
Homebrew and pointing the compiler straight at its include folder, I kept
getting "archive.h file not found," and the exact place it failed kept
moving around depending on what I tried next.

**What caused it.** This took a few tries to fully understand, and each
try taught me something new about how Swift Package Manager actually
handles C code.

First I added an include path setting directly on my own C target. That
setting works fine when the target compiles its own C files, but it turns
out it is not used when a completely different target, like Telemetry,
tries to `import CSystemBridge` from Swift. Swift has to build a small
model of that C target on its own in that moment, and it does not reuse
the same settings.

Then I tried Swift Package Manager's official "header search path" option
instead. That one refused to even accept the folder path I gave it,
because it only allows paths inside my own project folder, not an outside
folder like the one Homebrew installs into.

The real fix turned out to be a completely different kind of target that
Swift Package Manager calls a system library target. It exists
specifically for wrapping an already installed library that lives outside
my project, and unlike a normal target, its settings do correctly carry
over to any other target that depends on it.

Once I had that working, one more piece was still confusing. libarchive
successfully linked in without me telling the linker where to find it at
all. I expected that to fail. It turned out macOS already ships its own
copy of libarchive that the linker found automatically. I only actually
needed Homebrew for the header files, which macOS does not ship publicly,
not for the library itself. I confirmed this by checking which exact copy
was linked into my program and by logging the real version number while
it was running. It reported Apple's own version, not the newer one
Homebrew had just installed.

**How I fixed it.** I created a small separate target just for wrapping
libarchive, with its own hand written module description pointing
directly at Homebrew's header files. My own C bridge target went back to
only holding code I actually wrote myself, and any Swift file that needs
libarchive now depends on the new wrapper target directly instead of
going through my own bridge target.

**What to remember.** Getting a C library to compile is not the same
problem as getting it to be visible from every place that needs it, and
both of those are separate again from figuring out which actual copy of
the library ends up running. All three are worth checking on their own,
especially the last one, since a build that succeeds does not always tell
me which library it actually chose to use.

---

## 6. I noticed a real problem, wrote it down, and then did not actually fix it (Stage 2)

**What broke.** Nothing crashed here. This is a different kind of mistake.
While confirming entry 5 above, I found out my program was quietly running
against macOS's own older copy of libarchive, version 3.7.4, instead of
the newer one I had just installed through Homebrew, version 3.8.9. I
wrote all of that down clearly in a code comment at the time. Then I moved
on to the next thing without actually changing anything about it.

**What caused it.** I judged, in the moment, that this was probably safe,
since the handful of functions I am using have worked the same way across
many versions of libarchive. That judgment call was reasonable enough. But
writing an honest note about a problem is not the same thing as solving
it, and I let those two things blur together. It was only because I got
asked directly, "so there is no issue either way, right?", that I actually
went back and looked at it again properly instead of assuming my earlier
note meant it was handled.

**How I fixed it.** I added an explicit instruction telling the linker
exactly where Homebrew's copy of libarchive lives, on both of the two
places that actually link the final program together. I confirmed the fix
worked for real by checking which exact file got linked in with `otool -L`,
and by asking the running program to say its own version number out loud
again. It now correctly reports 3.8.9, matching the same version its
header files describe, instead of the older 3.7.4 it was silently using
before.

**What to remember.** Writing down a problem honestly is a good habit, but
it can quietly feel like closing the loop on it even when nothing has
actually been fixed yet. A comment that says "this could be a problem" is
not the same as a comment that says "this was a problem, and here is what
I changed to fix it." It is worth going back through my own notes every
so often and asking, for each one, whether it is actually describing
something I fixed, or just something I once noticed.

---

## 7. Two small but real type mismatches while calling libarchive from Swift (Stage 2)

**What broke.** Two separate, smaller problems showed up while writing
the real unpacking code and its test fixtures.

First, I tried to use libarchive's own constants for "this entry is a
regular file" and "this entry is a directory," called `AE_IFREG` and
`AE_IFDIR` in its header file. Swift's compiler said it had never heard of
either one, even though they are clearly written in the header I was
importing.

Second, once I worked around that and wrote my own version of those
constants by hand, I tried to hand one of them to a real libarchive
function while building a test fixture, and the compiler flatly refused,
saying it expected a different, larger number type than the one I gave it.

**What caused it.** For the first one, libarchive defines those constants
using a C cast, something like `((special_type)0100000)`, not as a plain
number. Swift's importer is only able to bring in plain number constants
automatically. A constant with a cast wrapped around it does not come
through at all, silently, so there was nothing wrong with my code, the
constant just was never available to use in the first place.

For the second one, once I picked my own type for my hand written
constant, I picked one that felt reasonable but did not actually match
what that specific libarchive function expects internally. C libraries
are often inconsistent like this internally, using slightly different
sized number types for what looks like the same kind of value in
different places.

**How I fixed it.** For the missing constants, I wrote my own copies by
hand, using the exact same plain numbers straight from libarchive's header
file, with a comment explaining why the originals never showed up. For the
type mismatch, I simply used the exact type the compiler told me it
wanted, instead of guessing.

**What to remember.** When calling into a C library from Swift, it is
worth remembering that not everything in a C header automatically becomes
usable in Swift, and the types on each individual function can be more
specific and less forgiving than they first appear. In both cases here,
the Swift compiler's own error message told me exactly what was wrong and
exactly what to do instead. Reading that message carefully was faster than
trying to guess the right fix from memory.
