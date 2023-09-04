import std / [logging, posix, tables]

type
  SigProc* = proc() {.gcsafe.}
  SigSet* = TableRef[cint, SigProc]

var
  chan: Channel[cint]
  thr: Thread[SigSet]
  loggers = cast[ptr seq[Logger]](allocShared0(sizeof(seq[Logger])))

proc newSigSet*(): SigSet =
  newTable[cint, SigProc]()

proc add*(sigSet: SigSet, sig: cint, p: SigProc) =
  sigSet[sig] = p

proc monitorSignals(sigSet: SigSet) {.thread.} =
  for logger in loggers[]: addHandler(logger)
  while true:
    let sig = chan.recv()
    if sig == 0: break
    if sigSet.hasKey(sig):
      sigSet[sig]()

proc registerLogger*(logger: Logger) =
  loggers[].add(logger)

proc init*(sigSet: SigSet) =
  if thr.running: raise newException(Defect, "init called after init")
  chan.open()
  createThread(thr, monitorSignals, sigSet)
  for sig, _ in sigset:
    onsignal(sig):
      chan.send(sig)

proc finish*() =
  chan.send(0)
  thr.joinThread()
  chan.close()
