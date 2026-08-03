/// The local machine's hostname, used as the default bridge name. `origin`
/// tagging needs some identity even when `bridge.name` is not configured.
@external(erlang, "reeds_hostname_ffi", "hostname")
pub fn hostname() -> String
