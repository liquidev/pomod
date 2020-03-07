## pomod is a dead-simple and super-lightweight Pomodoro timer for Polybar.

import std/monotimes
import std/options
import std/posix
import std/strformat
import std/tables
import std/times


# edit to configure

const
  # times are in seconds
  PomodoroTime = 25 * 60
  ShortBreakTime = 5 * 60
  LongBreakTime = 30 * 60
  BreakCycle = 4           # the amount of short breaks before a long break
  # icons
  IconPlanned = ""
  IconPomodoro = ""
  IconShortBreak = ""
  IconLongBreak = ""


# implementation

proc minutes(duration: Duration): int64 =
  ## Get the amount of minutes in the duration.
  duration.inSeconds div 60

proc seconds(duration: Duration): int64 =
  ## Get the amount of seconds in the current minute.
  duration.inSeconds mod 60

type
  TimerState = enum ## the state of a pomodoro timer
    tsNone        ## planned/not started yet
    tsPomodoro = "pomodoro"
    tsShortBreak = "short break"
    tsLongBreak = "long break"
  Timer = object
    running: bool                     ## is the timer running or paused
    state: TimerState                 ## the current state
    stateStartTime: Option[MonoTime]  ## when the state was started
    remainingTime: Duration
    lastPoll: MonoTime                ## last time when poll() was called
    breakCounter: int
    stateChangeProc: proc (newState: TimerState)

proc time(state: TimerState): Duration =
  ## Returns the amount of time a given state should take (in seconds).
  let seconds =
    case state
    of tsNone, tsPomodoro: PomodoroTime
    of tsShortBreak: ShortBreakTime
    of tsLongBreak: LongBreakTime

  result = initDuration(seconds = seconds)

proc pomicon(state: TimerState): string =
  ## Returns the Nerd Font/Pomicons icon associated with the given state.
  result =
    case state
    of tsNone: IconPlanned
    of tsPomodoro: IconPomodoro
    of tsShortBreak: IconShortBreak
    of tsLongBreak: IconLongBreak

proc next(state: var TimerState, breakCounter: var int) =
  ## Sets the next state according to the break counter, then increments the
  ## break counter.
  case state
  of tsNone, tsShortBreak, tsLongBreak: state = tsPomodoro
  of tsPomodoro:
    if breakCounter < BreakCycle - 1:
      state = tsShortBreak
    else:
      state = tsLongBreak
    breakCounter = (breakCounter + 1) mod BreakCycle

proc initTimer(): Timer =
  ## Initializes a new timer.
  result = Timer()
  result.remainingTime = result.state.time
  result.lastPoll = getMonoTime()

proc onStateChange(timer: var Timer, callback: proc (newState: TimerState)) =
  ## Sets the timer's state change callback.
  timer.stateChangeProc = callback

proc nextState(timer: var Timer) =
  ## Skips to the next state and sets the timer's remaining time accordingly.
  timer.state.next(timer.breakCounter)
  timer.remainingTime = timer.state.time

proc start(timer: var Timer) =
  ## Starts the timer.
  if not timer.running:
    if timer.stateStartTime.isNone:
      timer.stateStartTime = some(getMonoTime())
      timer.nextState()
    timer.running = true

proc stop(timer: var Timer) =
  ## Stops the timer.
  timer.running = false

proc toggle(timer: var Timer) =
  ## Toggles the timer.
  if not timer.running: timer.start()
  else: timer.stop()

proc poll(timer: var Timer) =
  ## Polls the timer and updates its state. This must be called monotonically
  ## (slight deviations are allowed).
  if timer.running:
    if timer.remainingTime.inSeconds <= 0:
      # time's up
      timer.nextState()
      if timer.stateChangeProc != nil:
        timer.stateChangeProc(timer.state)
    else:
      timer.remainingTime -= getMonoTime() - timer.lastPoll
  timer.lastPoll = getMonoTime()


# CLI

when isMainModule:

  import std/os

  import dbus
  import rapid/audio/device
  import rapid/audio/samplers/wave

  # common

  proc notification(appName, summary, body: string,
                    hints: Table[string, auto], timeout = 0) =
    ## Sends a notification via dbus.

    # stolen from disruptek who stole it from solitudesf
    # simplified because I don't need everything.
    let bus = getBus(DBUS_BUS_SESSION)
    var message = makeCall("org.freedesktop.Notifications",
                           ObjectPath"/org/freedesktop/Notifications",
                           "org.freedesktop.Notifications",
                           "Notify")
    message.append(appName)
    message.append(0'u32)             # replaces
    message.append("")                # app icon
    message.append(summary)
    message.append(body)
    message.append(newSeq[string]())  # actions
    message.append(hints)
    message.append(timeout.int32)
    bus.sendMessage(message)

  proc configDir(): string =
    result = getConfigDir()/"pomod"

  if not dirExists(configDir()):
    stderr.writeLine("config dir does not exist, creating at " & configDir())
    createDir(configDir())

  if not fileExists(configDir()/"sound.ogg"):
    stderr.writeLine("default sound does not exist, creating")
    const soundOgg = slurp("sound.ogg")
    writeFile(configDir()/"sound.ogg", soundOgg)

  var
    audioDevice = newRAudioDevice()
    sound = newRWave(configDir()/"sound.ogg")
  audioDevice.attach(sound)
  audioDevice.start()

  # the timer

  proc reset(timer: var Timer) =
    timer = initTimer()
    timer.onStateChange do (newState: TimerState):
      # send a notification to the user's desktop
      notification(appName = "pomod", summary = "pomod: time's up",
                   body = "next up: " & $newState, hints = {
                     "urgency": newVariant(2'u8)
                   }.toTable, timeout = 5000)
      # also, play a nice (user-definable) sound
      sound.stop()
      sound.play()


  var timer: Timer
  timer.reset()

  # set up the signal trap, so that when we call ``kill -USR1 pomod`` the
  # program doesn't stop
  discard sighold(SIGUSR1)
  discard sighold(SIGUSR2)

  while true:
    block catchSignals:
      # pomod is controlled using signals USR1 and USR2.
      # USR1 toggles the timer, and USR2 resets it.
      var
        signals: SigSet
        info: SigInfo
        timespec = Timespec(tv_nsec: 250 * 1_000_000)
      discard sigemptyset(signals)
      discard sigaddset(signals, SIGUSR1)
      discard sigaddset(signals, SIGUSR2)
      let signal = sigtimedwait(signals, info, timespec)
      if signal == SIGUSR1: timer.toggle()
      elif signal == SIGUSR2: timer.reset()

    timer.poll()

    block printOutput:
      let
        icon = timer.state.pomicon
        minutes = timer.remainingTime.minutes
        seconds = timer.remainingTime.seconds
      stdout.writeLine(fmt"{icon} {minutes:02}:{seconds:02}")
