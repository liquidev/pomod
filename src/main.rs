use std::time::{Duration, Instant};

use notify_rust::Notification;
use signal::trap::Trap;
use signal::Signal;

const POMODORO_TIME: u64 = 25 * 60;
const SHORT_BREAK_TIME: u64 = 5 * 60;
const LONG_BREAK_TIME: u64 = 30 * 60;
const BREAK_CYCLE: u8 = 4;

#[derive(Copy, Clone, Debug)]
enum TimerState {
  None,
  Pomodoro,
  ShortBreak,
  LongBreak,
}

impl TimerState {
  fn time(&self) -> Duration {
    use TimerState::*;

    let seconds = match self {
      None | Pomodoro => POMODORO_TIME,
      ShortBreak => SHORT_BREAK_TIME,
      LongBreak => LONG_BREAK_TIME,
    };

    Duration::new(seconds, 0)
  }

  fn pomicon(&self) -> String {
    use TimerState::*;

    String::from(match self {
      None => "",
      Pomodoro => "",
      ShortBreak => "",
      LongBreak => "",
    })
  }

  fn next(&mut self, break_counter: &mut u8) {
    use TimerState::*;

    match self {
      None => *self = Pomodoro,
      Pomodoro => {
        if *break_counter < BREAK_CYCLE - 1 {
          *self = ShortBreak;
        } else {
          *self = LongBreak;
        }
        *break_counter = (*break_counter + 1) % BREAK_CYCLE;
      }
      ShortBreak | LongBreak => *self = Pomodoro,
    }
  }
}

struct Timer {
  running: bool,
  state: TimerState,
  state_start_time: Option<Instant>,
  remaining_time: Option<Duration>,
  last_poll: Instant,
  break_counter: u8,
}

fn minutes(duration: &Duration) -> u64 {
  duration.as_secs() / 60
}

fn seconds(duration: &Duration) -> u64 {
  duration.as_secs() % 60
}

impl Timer {
  fn new() -> Self {
    Timer {
      running: false,
      state: TimerState::None,
      state_start_time: None,
      remaining_time: Some(TimerState::None.time()),
      last_poll: Instant::now(),
      break_counter: 0,
    }
  }

  fn start(&mut self) {
    if !self.running {
      if self.state_start_time.is_none() {
        self.state_start_time = Some(Instant::now());
        self.begin_next_state();
      }
      self.running = true;
    }
  }

  fn stop(&mut self) {
    if self.running {
      self.running = false;
    }
  }

  fn toggle(&mut self) {
    if !self.running {
      self.start();
    } else {
      self.stop();
    }
  }

  fn begin_next_state(&mut self) {
    self.state.next(&mut self.break_counter);
    self.remaining_time = Some(self.state.time());
  }

  fn poll(&mut self) {
    if self.running {
      if self.remaining_time.is_none() {
        self.begin_next_state();
        Notification::new()
          .summary("pomod: time is up")
          .body(
            format!(
              "next up: {}",
              match self.state {
                TimerState::None => "none? how did this happen?",
                TimerState::Pomodoro => "pomodoro",
                TimerState::ShortBreak => "short break",
                TimerState::LongBreak => "long break",
              }
            )
            .as_str(),
          )
          .show()
          .unwrap();
      } else {
        self.remaining_time = self
          .remaining_time
          .unwrap()
          .checked_sub(Instant::now() - self.last_poll);
      }
    }
    self.last_poll = Instant::now();
  }
}

fn main() {
  let mut timer = Timer::new();
  let signal_trap = Trap::trap(&[Signal::SIGUSR1, Signal::SIGUSR2]);

  loop {
    match signal_trap.wait(Instant::now() + Duration::from_millis(500)) {
      Some(signal) => match signal {
        Signal::SIGUSR1 => timer.toggle(),
        Signal::SIGUSR2 => timer = Timer::new(),
        any_other => panic!("got unknown signal: {:?}", any_other),
      },
      None => (),
    }

    timer.poll();

    let mut state_string = String::new();
    let remaining_time = timer.remaining_time.unwrap_or(Duration::new(0, 0));
    state_string.push_str(&timer.state.pomicon());
    state_string.push_str(
      format!(
        " {:02}:{:02}",
        minutes(&remaining_time),
        seconds(&remaining_time),
      )
      .as_str(),
    );
    println!("{}", state_string);
  }
}
