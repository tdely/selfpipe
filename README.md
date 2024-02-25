selfpipe
========

Signal handlers are tricky and limited in what functions they can perform
safely; you can not safely use non-reentrant functions or access global
variables from within a signal handler. A solution to this problem is to use
D. J. Bernsteins [selfpipe trick](https://cr.yp.to/docs/selfpipe.html).

This library implements a simple interface for using selfpipes in your projects.
Set the signals you want to catch and the `proc` that each of the signals should
trigger with `addSignal`, call `init()` to set up the non-blocking pipe and
start listening for the signals, then call `checkSignals()` where you want to
handle the signals.

```nim
import std / [os, posix]
import selfpipe

var stop: bool

proc halt() =
  stop = true

addSignal(SIGINT, halt)
if init() != 0:
  quit("failed to initialize selfpipe", posix.errno)
try:
  while not stop:
    sleep(1000)
    checkSignals()
finally:
  finish()
```
