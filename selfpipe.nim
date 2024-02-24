import std / [posix, strutils, tables]

const bsize: cint = 2 # selfpipe read buffer size

type
  SigProc* = proc() {.gcsafe.}
    ## Handler for signal.
  SigSet* = TableRef[cint, SigProc]
    ## Set of signals for the selfpipe to handle and the `SigProc` that trigger
    ## on respective signal.

var pipefds = cast[ptr array[2, cint]](allocShared0(sizeof(array[2, cint])))

when compileOption("threads") and defined(selfpipe_thread):
  import std/logging
  var
    thr: Thread[SigSet]
    loggers = cast[ptr seq[Logger]](allocShared0(sizeof(seq[Logger])))

  proc monitorSignals(sigSet: SigSet) {.thread.} =
    for logger in loggers[]: addHandler(logger)
    while true:
      var buf: array[bsize, char]
      let r = read(pipefds[][0], addr buf, bsize)
      if r > 0:
        var s: string
        for x in buf:
          if x == '\x00': break
          s &= x
        let sig = cint(parseInt(s))
        if sigSet.hasKey(sig):
          sigSet[sig]()
      elif r == 0: break

  proc registerLogger*(logger: Logger) =
    ## Register logger to be used in the signal monitoring thread.
    loggers[].add(logger)
else:
  var pollfd: TPollfd

  proc checkSignal*(sigSet: SigSet) =
    ## Check if signal has been received and execute corresponding `SigProc`.
    var buf: array[bsize, char]
    if poll(addr pollfd, 1, 0) > 0:
      if pollfd.revents == POLLIN:
        let r = read(pipefds[][0], addr buf, bsize)
        if r > 0:
          var s: string
          for x in buf:
            if x == '\x00': break
            s &= x
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
  if pipefds[][0] == 0: raise newException(Defect, "sendSignal called before init")
  discard write(pipefds[][1], cstring($sig), cint(len($sig)))

proc init*(sigSet: sink SigSet): cint =
  ## Initialize the selfpipe using `sigSet`.
  ##
  ## Returns 0 on success, else `errno` from the operation that failed (pipe or
  ## fcntl).
  if pipefds[][0] != 0: raise newException(Defect, "init called after init")
  if pipe(pipefds[]) == -1:
    return posix.errno
  if fcntl(pipefds[][0], F_SETFD, O_NONBLOCK) == -1 or
      fcntl(pipefds[][1], F_SETFD, O_NONBLOCK) == -1:
    return posix.errno
  when compileOption("threads") and defined(selfpipe_thread):
    createThread(thr, monitorSignals, sigSet)
  else:
    pollfd = TPollfd(fd: pipefds[][0], events: POLLIN, revents: 0)
  for sig, _ in sigset:
    onsignal(sig):
      discard write(pipefds[][1], cstring($sig), cint(len($sig)))

proc finish*() =
  ## Close selfpipe resources.
  # helgrind reports these close() calls as possible data races
  discard close(pipefds[0])
  discard close(pipefds[1])
  when compileOption("threads") and defined(selfpipe_thread):
    thr.joinThread()
