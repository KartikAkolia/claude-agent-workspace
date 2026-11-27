//! Minecraft Java Edition's Server List Ping: the status request the Multiplayer screen sends.
//! <https://minecraft.wiki/w/Java_Edition_protocol/Server_List_Ping>

use serde_json::Value;
use std::{
    io::{self, ErrorKind, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub version: String,
    /// None when the server leaves the players field out (the client then shows "???").
    pub online: Option<u64>,
    pub max: Option<u64>,
    pub players: Vec<String>,
    pub motd: String,
    /// From connecting to the status reply, so it includes the server building the reply.
    pub latency_ms: u128,
}

/// Any recent protocol number works: a status request doesn't depend on it.
const PROTOCOL: u32 = 767;

pub fn ping(host: &str, port: u16, timeout: Duration) -> Result<Status, String> {
    let start = Instant::now();
    let json = exchange(host, port, start + timeout).map_err(describe)?;
    parse(&json, start.elapsed().as_millis())
}

fn exchange(host: &str, port: u16, deadline: Instant) -> io::Result<Vec<u8>> {
    let addr = (host, port)
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| io::Error::new(ErrorKind::NotFound, "no address"))?;
    let left = deadline
        .saturating_duration_since(Instant::now())
        .max(Duration::from_millis(1));
    let mut stream = TcpStream::connect_timeout(&addr, left)?;
    stream.set_write_timeout(Some(left))?;
    stream.write_all(&request(host, port))?;
    // One deadline for the whole reply, so a server dripping bytes can't hold the probe.
    let mut reader = Deadline { stream, deadline };
    read_varint(&mut reader)?;
    if read_varint(&mut reader)? != 0 {
        return Err(io::Error::new(ErrorKind::InvalidData, "unexpected packet"));
    }
    let len = read_varint(&mut reader)? as usize;
    if len > 1 << 20 {
        return Err(io::Error::new(
            ErrorKind::InvalidData,
            "status reply too large",
        ));
    }
    let mut json = vec![0; len];
    reader.read_exact(&mut json)?;
    Ok(json)
}

struct Deadline {
    stream: TcpStream,
    deadline: Instant,
}

impl Read for Deadline {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let left = self.deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(ErrorKind::TimedOut.into());
        }
        self.stream.set_read_timeout(Some(left))?;
        self.stream.read(buf)
    }
}

fn describe(e: io::Error) -> String {
    match e.kind() {
        ErrorKind::WouldBlock | ErrorKind::TimedOut => "no reply (timed out)".into(),
        ErrorKind::UnexpectedEof => "connection closed early".into(),
        ErrorKind::ConnectionRefused => "refused (still starting?)".into(),
        _ => e.to_string(),
    }
}

/// A handshake asking for the status state, then the empty status request.
pub fn request(host: &str, port: u16) -> Vec<u8> {
    let mut handshake = vec![0x00];
    handshake.extend(varint(PROTOCOL));
    handshake.extend(varint(host.len() as u32));
    handshake.extend(host.as_bytes());
    handshake.extend(port.to_be_bytes());
    handshake.extend(varint(1));
    let mut out = varint(handshake.len() as u32);
    out.extend(handshake);
    out.extend([0x01, 0x00]);
    out
}

fn varint(mut value: u32) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return out;
        }
        out.push(byte | 0x80);
    }
}

fn read_varint(reader: &mut impl Read) -> io::Result<u32> {
    let mut value = 0u32;
    for i in 0..5 {
        let mut byte = [0u8];
        reader.read_exact(&mut byte)?;
        value |= u32::from(byte[0] & 0x7f) << (7 * i);
        if byte[0] & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(io::Error::new(ErrorKind::InvalidData, "bad varint"))
}

pub fn parse(json: &[u8], latency_ms: u128) -> Result<Status, String> {
    let v: Value = serde_json::from_slice(json).map_err(|e| format!("bad status reply: {e}"))?;
    let players = &v["players"];
    // The MOTD may span two lines; one panel row shows the break as a space.
    let motd = strip_codes(&flatten(&v["description"]));
    Ok(Status {
        version: v["version"]["name"].as_str().unwrap_or("?").to_string(),
        online: players["online"].as_u64(),
        max: players["max"].as_u64(),
        players: players["sample"]
            .as_array()
            .map(|s| {
                s.iter()
                    .filter_map(|p| p["name"].as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default(),
        motd: motd.split_whitespace().collect::<Vec<_>>().join(" "),
        latency_ms,
    })
}

/// The MOTD is a string or a chat component with text (or a translation key) and extra parts.
fn flatten(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts.iter().map(flatten).collect(),
        Value::Object(o) => {
            let mut s = o
                .get("text")
                .or_else(|| o.get("translate"))
                .map(flatten)
                .unwrap_or_default();
            if let Some(extra) = o.get("extra") {
                s.push_str(&flatten(extra));
            }
            s
        }
        _ => String::new(),
    }
}

/// Drops § formatting codes (a § and the character after it).
fn strip_codes(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '§' {
            chars.next();
        } else {
            out.push(c);
        }
    }
    out
}

/// A player count, or "?" when the server didn't send one.
pub fn count(n: Option<u64>) -> String {
    n.map_or("?".into(), |n| n.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::TcpListener, thread};

    #[test]
    fn varints_round_trip() {
        for v in [0, 1, 127, 128, 255, 25565, 767, u32::MAX] {
            assert_eq!(read_varint(&mut varint(v).as_slice()).unwrap(), v);
        }
        assert_eq!(varint(300), [0xac, 0x02]);
    }

    #[test]
    fn request_frames_the_handshake() {
        let r = request("a", 25565);
        // length 8: id, protocol (2 bytes), host length, "a", port (2), next state
        assert_eq!(r, [8, 0, 0xff, 0x05, 1, b'a', 0x63, 0xdd, 1, 1, 0]);
    }

    #[test]
    fn parses_status_and_motd_components() {
        let json = r#"{"version":{"name":"26.3","protocol":775},
            "players":{"max":10,"online":2,"sample":[{"name":"KA2314","id":"x"},{"name":"Bo","id":"y"}]},
            "description":{"text":"§aPrivate\n","extra":[{"text":"Server"},{"translate":"!"}]}}"#;
        let s = parse(json.as_bytes(), 7).unwrap();
        assert_eq!(s.version, "26.3");
        assert_eq!((s.online, s.max), (Some(2), Some(10)));
        assert_eq!(s.players, ["KA2314", "Bo"]);
        assert_eq!(s.motd, "Private Server!");
        let bare = parse(br#"{"version":{"name":"x"},"description":""}"#, 0).unwrap();
        assert_eq!(
            (count(bare.online), count(bare.max)),
            ("?".into(), "?".into())
        );
        assert!(parse(b"{", 0).is_err());
    }

    #[test]
    fn a_silent_server_times_out_within_the_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let hold = thread::spawn(move || {
            let (_conn, _) = listener.accept().unwrap();
            thread::sleep(Duration::from_millis(800));
        });
        let start = Instant::now();
        let err = ping("127.0.0.1", port, Duration::from_millis(300)).unwrap_err();
        assert_eq!(err, "no reply (timed out)");
        assert!(start.elapsed() < Duration::from_millis(700));
        hold.join().unwrap();
    }
}
