pub type TimeUnit {
  Millisecond
}

@external(erlang, "os", "system_time")
fn system_time(unit: TimeUnit) -> Int

pub fn now_ms() -> Int {
  system_time(Millisecond)
}
