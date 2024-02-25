## Synopsis:
##
## .. code-block:: Nim
##   import std / [os, posix]
##   import selfpipe
##
##   var stop: bool
##
##   proc halt() =
##     stop = true
##
##   var sigSet = newSigSet()
##   sigSet.add(SIGINT, halt)
##   if init(sigSet) != 0:
##     quit("failed to initialize selfpipe", posix.errno)
##   try:
##     while not stop:
##       sleep(1000)
##       sigSet.checkSignals()
##   finally:
##     finish()

import std / [posix, strutils, tables]

const bsize: cint = 2 # selfpipe read buffer size

type
  SigProc* = proc() {.gcsafe.}
    ## Handler for signal.
  SigSet* = TableRef[cint, SigProc]
    ## Set of signals for the selfpipe to handle and the `SigProc` that trigger
    ## on respective signal.

var pipefds = cast[ptr array[2, cint]](allocShared0(sizeof(array[2, cint])))

var pollfd: TPollfd

proc checkSignals*(sigSet: SigSet) =
  ## Check if signals have been received and execute corresponding `SigProc`.
  var buf: array[bsize, char]
  while poll(addr pollfd, 1, 0) > 0:
    if pollfd.revents == POLLIN:
      if read(pipefds[][0], addr buf, bsize) > 0:
        var s: string
        for x in buf:
          if x == '\x00':
            break
          s.add x
        let sig = cint(parseInt(s))
        if sigset[].hasKey(sig):
          sigset[][sig]()

proc monitorSignals*(sigSet: SigSet) {.thread.} =
  ## Check if signals have been received and execute corresponding `SigProc`.
  ## Does not return until pipe is closed. For use as dedicated thread.
  var buf: array[bsize, char]
  while read(pipefds[][0], addr buf, bsize) > 0:
    var s: string
    for x in buf:
      if x == '\x00':
        break
      s.add x
    let sig = cint(parseInt(s))
    if sigSet.hasKey(sig):
      sigSet[sig]()

proc newSigSet*(): SigSet =
  ## Create a new `SigSet`.
  newTable[cint, SigProc]()

proc add*(sigSet: SigSet, sig: cint, p: SigProc) =
  ## Add `sig` mapped to `p` to `sigSet`.
  sigSet[sig] = p

proc sendSignal*(sig: cint) =
  ## Send signal internally. Does not trigger the signal handler.
  if pipefds[][0] == 0:
    raise newException(Defect, "sendSignal called before init")
  discard write(pipefds[][1], cstring($sig), cint(len($sig)))

proc init*(sigSet: sink SigSet): cint =
  ## Initialize the selfpipe using `sigSet`.
  ##
  ## Returns 0 on success, else `errno` from the operation that failed (pipe or
  ## fcntl).
  if pipefds[][0] != 0:
    raise newException(Defect, "init called after init")
  if pipe(pipefds[]) == -1:
    return posix.errno
  if fcntl(pipefds[][0], F_SETFD, O_NONBLOCK) == -1 or
      fcntl(pipefds[][1], F_SETFD, O_NONBLOCK) == -1:
    return posix.errno
  pollfd = TPollfd(fd: pipefds[][0], events: POLLIN, revents: 0)
  for sig, _ in sigset:
    onsignal(sig):
      discard write(pipefds[][1], cstring($sig), cint(len($sig)))

proc finish*() =
  ## Close selfpipe resources.
  discard close(pipefds[0])
  discard close(pipefds[1])
