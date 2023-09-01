import std / [locks, logging, posix, strutils, tables]

const bsize: cint = 2 # selfpipe read buffer size

type
  Handler = proc(): void {.gcsafe.}
  RegTbl = TableRef[cint, Handler]

var
  pipefds = cast[ptr array[2, cint]](allocShared0(sizeof(array[2, cint])))
  thr: Thread[void]
  rLock: Lock
  registered {.guard: [rLock].} = cast[ptr RegTbl](allocShared0(sizeof(RegTbl)))
  loggers = cast[ptr seq[Logger]](allocShared0(sizeof(seq[Logger])))

rLock.initLock()

proc monitorSignals() {.thread.} =
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
      withLock(rLock):
        if registered[].hasKey(sig):
          registered[][sig]()
    elif r == 0: break

proc registerSignal*(sig: cint, p: proc(): void {.gcsafe.}) =
  assert thr.running, "init must be called before registerSignal"
  if not registered[].hasKey(sig):
    withLock(rLock):
      registered[][sig] = p
      onSignal(sig):
        discard write(pipefds[][1], cstring($sig), cint(len($sig)))

proc registerLogger*(logger: Logger) =
  assert not thr.running, "init called before registerLogger"
  loggers[].add(logger)

proc init*(): cint =
  withLock(rLock):
    registered[] = newTable[cint, Handler]()
  if pipefds[][0] != 0: raise newException(Defect, "init called after init")
  if pipe(pipefds[]) == -1:
    return posix.errno
  if fcntl(pipefds[][0], F_SETFD, O_NONBLOCK) == -1 or
      fcntl(pipefds[][1], F_SETFD, O_NONBLOCK) == -1:
    return posix.errno
  createThread(thr, monitorSignals)

proc finish*() =
  # helgrind reports these closes as possible data races
  discard close(pipefds[0])
  discard close(pipefds[1])
  thr.joinThread()
