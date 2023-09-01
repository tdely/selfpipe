import std / [logging, posix, strutils, tables]

const bsize: cint = 2 # selfpipe read buffer size

type
  SigProc* = proc() {.gcsafe.}
  SigSet* = TableRef[cint, SigProc]

var
  pipefds = cast[ptr array[2, cint]](allocShared0(sizeof(array[2, cint])))
  thr: Thread[SigSet]
  loggers = cast[ptr seq[Logger]](allocShared0(sizeof(seq[Logger])))

proc newSigSet*(): SigSet =
  newTable[cint, SigProc]()

proc add*(sigSet: SigSet, sig: cint, p: SigProc) =
  sigSet[sig] = p

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
  loggers[].add(logger)

proc init*(sigSet: SigSet): cint =
  if pipefds[][0] != 0: raise newException(Defect, "init called after init")
  if pipe(pipefds[]) == -1:
    return posix.errno
  if fcntl(pipefds[][0], F_SETFD, O_NONBLOCK) == -1 or
      fcntl(pipefds[][1], F_SETFD, O_NONBLOCK) == -1:
    return posix.errno
  createThread(thr, monitorSignals, sigSet)
  for sig, _ in sigset:
    onsignal(sig):
      discard write(pipefds[][1], cstring($sig), cint(len($sig)))

proc finish*() =
  # helgrind reports these close() calls as possible data races
  discard close(pipefds[0])
  discard close(pipefds[1])
  thr.joinThread()
