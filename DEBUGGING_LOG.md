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

---

## 8. I designed spawn() to start the process itself, which left no room to capture its output (Stage 3)

**What broke.** Nothing crashed, and no test even failed. While writing
the very first test for POSIXIsolationEngine, I went to capture a
process's real output and realized there was no way to do it with the
function I had just written. My spawn() function both configured the
process and immediately launched it. I planned to write a test that would
attach a pipe to the process afterward and read its output, but by the
time spawn() returned, the process had already started running with no
pipe attached to catch anything it printed. There was no window left to
attach one.

**What caused it.** Foundation's `Process` type requires you to attach
its stdout and stderr pipes before calling its own `run()` method, not
after. I had written spawn() to call `run()` internally, as the very last
step, which felt natural at the time since it seemed like spawning should
mean "make it run." I had not yet thought through who is actually
responsible for wiring up a process's output, which turned out to be a
separate concern I had not built yet.

**How I fixed it.** I removed the internal `run()` call entirely.
spawn() now only validates the path and configures the Process object,
then hands it back still unlaunched. Whoever actually starts it, a test
today, and a proper job supervisor in the next component, gets a chance
to attach pipes first and decide when to actually launch it.

**What to remember.** This one was not a bug I had to chase down; it was
a shape problem I noticed the moment I tried to actually use my own
function. Trying to write the very first real test for a new piece of
code, right after writing it, is often what surfaces a bad interface
decision like this quickly, before anything else gets built on top of it
and makes the fix more expensive later.

---

## 9. Memory limits cannot actually be set on macOS at all (Stage 3)

**What broke.** Nothing broke yet, because I checked before writing the
code instead of after. I was about to implement `--memory-limit` the same
way I planned to implement `--cpu-limit`, using the shell's own `ulimit`
command, and I decided to test it by hand on my own machine first rather
than just assume it would work the same way.

**What caused it.** It turns out macOS simply will not let a normal
program lower its own memory-related limits at all, no matter how you ask
it. I checked this three separate ways, on purpose, so I could not talk
myself into believing it was just one tool being fussy: asking the shell
directly with `ulimit -v`, asking it a different way with `ulimit -m`,
and finally bypassing the shell completely and asking the operating
system directly through a small Python script. All three were refused,
every time, with no memory limit ever actually being set. The CPU time
limit, by contrast, worked correctly every single time I tried it, and I
could prove it worked by watching a runaway program actually get killed
by the operating system once its time ran out.

**How I fixed it.** I did not try to force a fix that does not exist. I
implemented the CPU limit for real, since it genuinely works. For the
memory limit, I made the honest choice: the program still runs the
requested job normally, but instead of silently pretending a memory limit
was applied when it was not, it writes a clear warning explaining that
this specific limit could not be enforced on this machine.

**What to remember.** This is the second time in this project that
something written in an earlier note ("memory limits are best effort")
turned out to undersell the real problem once I actually tested it by
hand. "Best effort" suggested it does something, just not perfectly. The
real answer was closer to "does nothing at all right now." Testing an
assumption directly, the same way I tested the earlier one about which
copy of libarchive was really running, is what caught the gap between
what I had written down and what was actually true.

---

## 10. My real sandbox profile kept rejecting things that looked completely fine (Stage 3)

**What broke.** I wrote the actual Seatbelt sandboxing code and gave it
its first real test: run a tiny script inside a locked-down folder. It
failed immediately with "Operation not permitted," even though I had
already worked out, by hand, in the terminal, a version of this exact
profile that worked correctly.

**What caused it.** This turned out to be a genuinely sneaky problem, and
it took real digging to find. On macOS, a folder like `/tmp` is not
actually a real folder at all. It is a shortcut that quietly points to a
different real folder, `/private/tmp`. Most of the time this distinction
never matters, because the system quietly follows the shortcut for you
without telling you.

My own program uses a well known, standard tool to clean up file paths
before using them. I assumed that tool would follow shortcuts like this
one all the way through to the real underlying folder, the same way the
operating system itself does. It turns out that tool deliberately does
not do that, specifically for a small handful of well known folders like
`/tmp`. It leaves the shortcut exactly as it found it, on purpose, for
compatibility reasons Apple built in a long time ago.

That difference does not matter for most of what I have built so far.
But it mattered enormously here, because the sandbox rule I was writing
gets checked by the operating system itself, using the real, fully
followed-through folder name, not the shortcut name my own program was
still using. My rule and the operating system's own check were quietly
talking about two different looking versions of the exact same folder,
and so nothing matched, and everything was denied.

I confirmed this precisely by writing the exact same folder path two
different ways side by side and comparing the results directly, rather
than continuing to guess. One version, using my program's usual tool,
kept the shortcut form. The other, using a lower level system tool that
talks to the operating system more directly, correctly returned the real
underlying folder name. That side-by-side comparison is what made the
mismatch obvious and undeniable.

**How I fixed it.** I stopped relying on my program's usual, higher level
path-cleanup tool for this specific purpose. Instead, I built a small
dedicated helper that asks the operating system directly for a folder's
true, fully resolved name, and I made sure both the sandbox rule and the
program actually being run agree on that same true name, every time.

**What to remember.** Two tools can both claim to do the same basic job,
"give me the real version of this file path," and still genuinely
disagree with each other in specific, easy-to-miss cases. That gap
usually will not matter. But the moment a path is being checked by
something outside my own program, like the operating system's own
security rules here, the two versions absolutely have to match exactly,
or the whole check silently falls apart. When I am not sure two tools
truly agree, comparing their actual output side by side, directly, is
far more reliable than trusting that they must, because they sound like
they should.

---

## 11. A file I pulled and unpacked myself refused to run, for a reason that had nothing to do with running it (Stage 3)

**What broke.** After weeks of building the unpacking piece and the
running piece separately, I finally connected the two for a real test:
pull a real signed bundle, then actually run the program inside it. The
run failed immediately with "binary not found or not executable," even
though I could see the file sitting right there, in the right place,
with the right name.

**What caused it.** The file itself was completely fine. The problem was
that it had been unpacked with the wrong permissions. Every file I had
extracted from a tarball so far, going all the way back to when I first
built the unpacking code, had been created with the same fixed, ordinary
permissions, no matter what permissions the original file actually had
before it was packed. I had simply never told the unpacking code to look
at, or care about, that detail.

This had been sitting there, silently wrong, since the unpacking code was
first written. It never once caused a problem before now for one simple
reason: every single test I had written for unpacking, including several
fairly thorough ones, only ever checked files containing plain text. None
of them ever needed to actually be run as a program, so a missing
executable permission never had anything to trip over. The very first
time that mattered was the very first time I tried to run something for
real.

**How I fixed it.** I went back to the unpacking code and added the one
missing step: after writing a file's contents to disk, also copy over the
permission bits that were actually recorded for it inside the original
archive, instead of leaving whatever generic default my code had been
using the entire time. I also went back and strengthened my test suite
itself, adding a test that specifically packs a file marked as
executable and confirms it comes back out of the unpacking step still
marked as executable, so a mistake like this cannot quietly reappear
later without a test noticing right away.

**What to remember.** A whole category of real bug can hide indefinitely
behind test data that is simply too simple to expose it. Every one of my
earlier unpacking tests was a completely honest, real test, and every one
of them genuinely passed. They just never happened to ask the one
question that mattered here. Connecting two finished pieces together for
a real, true end-to-end run, not just trusting that each one passed its
own tests in isolation, is what actually surfaced this, and it is a good
reminder to keep doing that kind of full, real test regularly rather than
only testing each piece on its own.

---

## 12. My plan's core assumption about telemetry was backwards (Stage 4)

**What broke.** Before writing any real code for Stage 4, I wrote a tiny
standalone test program to check something the whole telemetry design
depended on: whether my own daemon can read basic stats, like memory
usage, from a program it just started running. The very first, simplest
version of that test failed outright. The daemon could not read anything
about its own child process at all.

**What caused it.** macOS treats this specific ability, one program
peeking at another program's memory and CPU usage, as sensitive by
default, for good reason: it is also exactly the ability a debugger
needs, and also exactly the ability something malicious would want. My
original assumption, carried over from the very first planning
conversation, was that this would work automatically as long as the
daemon was looking at a process it had started itself, no extra
permission needed.

I tested that assumption directly, several different ways, rather than
trust it. My first test used a very simple technique, duplicating my own
already-running program in place, and that version worked once I signed
my own test program with one specific permission flag. That looked like
confirmation my original assumption was right. But when I tried the
much more realistic version, my program starting a genuinely separate,
different program the normal way, the exact same signed permission flag
suddenly stopped working. I tried giving that same permission to the
program doing the watching. Still nothing. I tried a stronger, more
official-sounding debugging permission instead. Still nothing.

It was only when I flipped my thinking around entirely, and instead gave
that permission to the program being watched, rather than the program
doing the watching, that everything started working immediately. The
real rule turns out to be the opposite of what I had assumed the whole
time: it is not enough for the daemon to be allowed to look at things.
The specific program being run has to individually agree to be looked
at.

**How I fixed it.** I have not written the real telemetry sampling code
yet. What I fixed first was my own understanding, before building
anything else on top of it. The real, confirmed design is: before
running any program the daemon wants to measure, the daemon itself first
has to apply this specific permission to that exact program. This is a
meaningfully bigger, more hands-on step than my original assumption of
"this happens automatically for anything I start," and it changes what
Stage 4 actually needs to build.

**What to remember.** The most important assumption in an entire stage
of work is exactly the one most worth testing first, in isolation, with
the smallest possible example, before writing anything real on top of
it. If I had started by writing the full sampling feature first and only
tested it at the very end, I would have discovered this same problem
much later, with far more code already built on top of a wrong idea of
how the underlying permission actually works. Testing the riskiest,
least certain assumption first, even with a five-minute throwaway
script, is worth doing before committing to a design built on top of it.

---

## 13. Marking a script as trustworthy did not actually mark the thing that runs (Stage 4)

**What broke.** Right after fixing entry 12, I built the actual piece
that applies the special permission to a job right before running it,
and tested it end to end. It worked perfectly for a small program I had
compiled myself. It silently did nothing at all for an ordinary shell
script doing the exact same thing.

**What caused it.** A shell script is not really "run" the way a normal
program is. When the system sees the special `#!` line at the top of a
script, it does not treat the script itself as the real program at all.
Instead, it quietly starts up whichever program that line names, usually
a shell, and hands the script to that program to read and follow, more
like a to-do list than a program in its own right. The permission I was
applying was being written onto the to-do list. The operating system,
underneath, was actually running the shell that reads the list, and that
shell is a separate, already existing program supplied by Apple that I
never touched at all.

I confirmed this precisely by running the exact same test twice, changed
in only one way: once against a small compiled program, and once against
an ordinary shell script doing the same job. The compiled program worked
immediately. The script failed every time, in exactly the same way,
confirming this was not a fluke.

**How I fixed it.** I did not try to force this to work for scripts. That
would have meant altering a program Apple ships as part of the operating
system itself, which is not something this project should be doing.
Instead, I wrote down plainly, right in the code and in this log, exactly
which kind of job this feature actually works for: genuinely compiled
programs, not shell scripts. That is a real, honest boundary on what this
part of the project can do, not a bug still waiting to be fixed.

**What to remember.** "It worked" is only ever true for the exact thing I
actually tested it with. My very first successful test used a compiled
program, and it would have been easy to assume the same result would
carry over to any other kind of runnable file without checking. Two
things that both look like "a file you can run from the terminal" can
behave in completely different ways under the hood, and the only way to
know for sure is to try the actual case I care about, not a convenient
stand-in for it.

---

## 14. A test that always passed alone started failing only when run with everything else (Stage 4)

**What broke.** A test I had already written and trusted, the one
checking that a program's memory usage gets measured correctly, suddenly
failed. Nothing about that test's own code had changed. What changed was
that I ran the entire test suite together, all at once, instead of that
one test by itself.

**What caused it.** That test worked by starting a small program,
waiting a fixed, guessed amount of time, and then checking how much
memory it was using. That guess was based on how long the program
usually took when it was the only thing running on the machine. The
moment it had to share the machine with dozens of other tests running at
the same time, some of them fairly demanding themselves, that same fixed
wait was no longer reliably long enough. The program simply had not
finished doing its work yet by the time I went and measured it.

**How I fixed it.** I stopped guessing how long to wait entirely.
Instead, I changed the small test program itself to leave behind a
simple, unmistakable signal, an empty marker file, the exact moment it
had actually finished the specific work the test cared about. The test
now waits for that real signal to appear, checking briefly and
repeatedly, however long that actually takes, rather than assuming a
fixed number of seconds is always enough. I applied the same fix to a
second, similar test right next to it, since it had the exact same
weakness even though it had not happened to fail yet.

**What to remember.** A test passing by itself is not the same thing as
a test being correct. Fixed waits are a common and easy way to make a
test pass most of the time while still hiding a real race underneath,
one that only shows up under exactly the kind of real-world pressure,
many things happening on the machine at once, that is completely normal
outside of a quiet, empty test run. Running the whole suite together
regularly, not just the one test I am currently working on, is what
actually caught this.

---

## 15. My memory number was wrong the entire time, and my own test did not catch it (Stage 4)

**What broke.** After wiring everything together, I finally ran the whole
project the way it is actually meant to be used: pull a real program,
run it, and watch its real memory usage stream out live. I gave it a
program that deliberately grabs and fully uses about fifteen megabytes of
memory, on purpose, specifically so the number reported back would be
obviously meaningful. The number that came back was under one megabyte.
Consistently, every single time, for as long as I let it run.

**What caused it.** The specific piece of information I had been reading
from the operating system this whole time, something with "resident
memory size" written right in its own description, turns out to be a
genuinely unreliable way to answer "how much memory is this program
really using" on a modern Mac. It is an older measurement that does not
account correctly for how the operating system compresses and shares
memory pages behind the scenes today. Apple has a newer, different
number specifically meant to replace it for exactly this purpose, one
that is not the obvious first choice when just reading through the
available fields, but is the one actually recommended, and the one tools
like Activity Monitor genuinely rely on.

To make sure sandboxing was not somehow the cause, I ran the exact same
program two different ways, once sandboxed and once not, and compared
them side by side. Both reported the same wrong, tiny number, which
ruled that out cleanly and pointed at the actual measurement itself
being the problem, not anything downstream of it.

I also had to stop and understand something else along the way, one that
sound reasonable at first: could the numbers just be fine, only measured
too early, before the program had finished setting itself up? A single
sample really can land before a program is fully ready, and I saw that
happen too, once, before the numbers settled. But every sample after that
first one stayed wrong for the old measurement, for minutes at a time,
which ruled out simple timing as the explanation.

**How I fixed it.** I switched to reading the newer, correct field
instead of the old one. I re-ran the exact same real test afterward, not
a new one, the same fifteen-megabyte program, the same live measurement
setup, and this time it correctly reported just under sixteen megabytes,
matching what was actually allocated almost exactly.

**What to remember.** This is the one that concerns me most so far,
because an earlier, narrower test I had already written and trusted did
not catch it. That test also used the old, wrong field, and it also
happened to pass, reporting a plausible-looking number for a smaller
allocation in a simpler setup. A field that is subtly wrong can still
occasionally produce a number that looks reasonable enough to slip past
a loose check, especially one that only confirms a number is "big
enough" rather than checking it against a precisely known, expected
value. Running the real, complete version of a feature end to end, the
way an actual person would eventually use it, and comparing the result
against a number I can independently predict and check by hand, catches
real mistakes that a narrower, more convenient test can still miss
completely.
